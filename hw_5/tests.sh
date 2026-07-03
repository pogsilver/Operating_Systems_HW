#!/bin/bash
# tests.sh - Test suite for the concurrent FIFO queue (queue.c)
#
# Usage:  bash tests.sh          bash tests.sh -v  (verbose probe output)
#
# Optional: sudo apt-get install -y valgrind  (enables Phase 7 leak check)
#
# All probes run under timeout; any deadlock becomes a FAIL rather than a hang.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
VERBOSE=${1:-""}

TDIR=$(mktemp -d /tmp/queue_test_XXXXXX)

QUEUE_SRC="$REPO_DIR/queue.c"
QUEUE_OBJ="$TDIR/queue.o"

# Exact grading flags from queue.pdf.
GRADE_FLAGS=(-O3 -D_POSIX_C_SOURCE=200809 -Wall -std=c11 -pthread)

PROBE_BASIC="$TDIR/probe_basic"
PROBE_BLOCK="$TDIR/probe_block"
PROBE_FIFO="$TDIR/probe_fifo"
PROBE_VISITED="$TDIR/probe_visited"
PROBE_STRESS="$TDIR/probe_stress"

cleanup_all() {
    rm -rf "$TDIR"
    kill "$(jobs -p)" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap 'cleanup_all' EXIT

pass() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }
note() { echo "NOTE: $1"; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name"
        echo "    expected : $(printf '%s' "$expected" | head -c 120)"
        echo "    actual   : $(printf '%s' "$actual"   | head -c 120)"
    fi
}

# Probe binary must print "PASS" to stdout; anything else is a failure.
check_probe() {
    local name="$1" probe="$2" test_case="$3" tmo="${4:-10}"
    local result
    result=$(timeout "$tmo" "$probe" "$test_case" 2>/dev/null)
    [ -n "$VERBOSE" ] && echo "    probe[$test_case]: $result"
    if [ "$result" = "PASS" ]; then
        pass "$name"
    else
        fail "$name"
        echo "    probe output : $(printf '%s' "$result" | head -c 200)"
    fi
}

cat > "$TDIR/probe_common.h" << 'CSRC'
#ifndef PROBE_COMMON_H
#define PROBE_COMMON_H

#include <stddef.h>
#include <threads.h>
#include <time.h>

void   initQueue(void);
void   destroyQueue(void);
void   enqueue(void *);
void  *dequeue(void);
size_t visited(void);

static inline void sleep_ms(int ms)
{
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    thrd_sleep(&ts, NULL);
}

static inline double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

#endif
CSRC

cat > "$TDIR/probe_basic.c" << 'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "probe_common.h"

static int single_roundtrip(void)
{
    initQueue();
    int a = 1;
    enqueue(&a);
    void *r = dequeue();
    int ok = (r == &a);
    destroyQueue();
    return ok;
}

static int fifo_order(void)
{
    enum { N = 64 };
    static int v[N];
    initQueue();
    for (int i = 0; i < N; i++) { v[i] = i; enqueue(&v[i]); }
    int ok = 1;
    for (int i = 0; i < N; i++)
        if (dequeue() != &v[i]) ok = 0;
    destroyQueue();
    return ok;
}

static int null_item(void)
{
    initQueue();
    enqueue(NULL);
    void *r = dequeue();
    int ok = (r == NULL) && (visited() == 1);
    destroyQueue();
    return ok;
}

static int heap_stack_ptrs(void)
{
    initQueue();
    int stackv = 7;
    int *heapv = malloc(sizeof(int));
    *heapv = 9;
    enqueue(&stackv);
    enqueue(heapv);
    void *r1 = dequeue();
    void *r2 = dequeue();
    int ok = (r1 == &stackv) && (r2 == heapv);
    free(heapv);
    destroyQueue();
    return ok;
}

static int interleaved(void)
{
    static int v[3];
    for (int i = 0; i < 3; i++) v[i] = i;
    initQueue();
    int ok = 1;
    enqueue(&v[0]);
    enqueue(&v[1]);
    if (dequeue() != &v[0]) ok = 0;
    enqueue(&v[2]);
    if (dequeue() != &v[1]) ok = 0;
    if (dequeue() != &v[2]) ok = 0;
    destroyQueue();
    return ok;
}

/* visited() must be 0 after init, still 0 after enqueues alone, +1 per dequeue. */
static int visited_semantics(void)
{
    static int v[5];
    initQueue();
    int ok = 1;
    if (visited() != 0) ok = 0;
    for (int i = 0; i < 5; i++) { v[i] = i; enqueue(&v[i]); }
    if (visited() != 0) ok = 0;
    for (int i = 0; i < 5; i++) {
        dequeue();
        if (visited() != (size_t)(i + 1)) ok = 0;
    }
    destroyQueue();
    return ok;
}

static int reinit_cycles(void)
{
    int ok = 1;
    for (int c = 0; c < 3; c++) {
        initQueue();
        int x = 42;
        enqueue(&x);
        if (dequeue() != &x) ok = 0;
        if (visited() != 1)  ok = 0;
        destroyQueue();
    }
    return ok;
}

int main(int argc, char **argv)
{
    int ok = -1;
    if (argc != 2) { fprintf(stderr, "usage: %s <test>\n", argv[0]); return 1; }

    if      (!strcmp(argv[1], "single_roundtrip")) ok = single_roundtrip();
    else if (!strcmp(argv[1], "fifo_order"))       ok = fifo_order();
    else if (!strcmp(argv[1], "null_item"))        ok = null_item();
    else if (!strcmp(argv[1], "heap_stack_ptrs"))  ok = heap_stack_ptrs();
    else if (!strcmp(argv[1], "interleaved"))      ok = interleaved();
    else if (!strcmp(argv[1], "visited_semantics"))ok = visited_semantics();
    else if (!strcmp(argv[1], "reinit_cycles"))    ok = reinit_cycles();
    else { fprintf(stderr, "unknown test: %s\n", argv[1]); return 1; }

    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
CSRC

cat > "$TDIR/probe_block.c" << 'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "probe_common.h"

static _Atomic int g_ret;
static void       *g_got;

static int one_consumer(void *arg)
{
    (void)arg;
    g_got = dequeue();
    atomic_store(&g_ret, 1);
    return 0;
}

static int blocks_on_empty(void)
{
    initQueue();
    atomic_store(&g_ret, 0);
    g_got = (void *)0;
    thrd_t t;
    thrd_create(&t, one_consumer, NULL);
    sleep_ms(300);
    int blocked = (atomic_load(&g_ret) == 0);   /* must still be waiting */
    int item = 123;
    enqueue(&item);
    thrd_join(t, NULL);
    int ok = blocked && (g_got == &item) && (atomic_load(&g_ret) == 1);
    destroyQueue();
    return ok;
}

static int no_block_when_available(void)
{
    initQueue();
    int item = 7;
    enqueue(&item);
    atomic_store(&g_ret, 0);
    g_got = (void *)0;
    thrd_t t;
    thrd_create(&t, one_consumer, NULL);
    sleep_ms(100);
    int fast = (atomic_load(&g_ret) == 1) && (g_got == &item);
    thrd_join(t, NULL);
    destroyQueue();
    return fast;
}

#define KB 8
static void *kb_got[KB];

static int kb_consumer(void *arg)
{
    kb_got[(int)(size_t)arg] = dequeue();
    return 0;
}

static int k_released_once(void)
{
    initQueue();
    static int tags[KB];
    thrd_t th[KB];
    for (int i = 0; i < KB; i++) { kb_got[i] = 0; tags[i] = i; }
    for (int i = 0; i < KB; i++) {
        thrd_create(&th[i], kb_consumer, (void *)(size_t)i);
        sleep_ms(10);
    }
    for (int i = 0; i < KB; i++) enqueue(&tags[i]);
    for (int i = 0; i < KB; i++) thrd_join(th[i], NULL);

    int seen[KB];
    for (int i = 0; i < KB; i++) seen[i] = 0;
    int ok = 1;
    for (int i = 0; i < KB; i++) {
        int *p = (int *)kb_got[i];
        if (!p) { ok = 0; continue; }
        int val = *p;
        if (val < 0 || val >= KB) { ok = 0; continue; }
        seen[val]++;
    }
    for (int i = 0; i < KB; i++) if (seen[i] != 1) ok = 0;
    if (visited() != KB) ok = 0;
    destroyQueue();
    return ok;
}

int main(int argc, char **argv)
{
    int ok = -1;
    if (argc != 2) { fprintf(stderr, "usage: %s <test>\n", argv[0]); return 1; }

    if      (!strcmp(argv[1], "blocks_on_empty"))        ok = blocks_on_empty();
    else if (!strcmp(argv[1], "no_block_when_available"))ok = no_block_when_available();
    else if (!strcmp(argv[1], "k_released_once"))        ok = k_released_once();
    else { fprintf(stderr, "unknown test: %s\n", argv[1]); return 1; }

    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
CSRC

cat > "$TDIR/probe_fifo.c" << 'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "probe_common.h"

#define MAXK 32
static int so_got[MAXK];
static int so_tags[MAXK];

static int so_sleeper(void *arg)
{
    int idx = (int)(size_t)arg;
    so_got[idx] = *(int *)dequeue();
    return 0;
}

/* Start k consumers staggered by sleep_ms so they sleep in known order,
 * then enqueue k tagged items. Sleeper i must receive tag i. */
static int run_sleeper_order(int k)
{
    initQueue();
    thrd_t th[MAXK];
    for (int i = 0; i < k; i++) { so_tags[i] = i; so_got[i] = -1; }
    for (int i = 0; i < k; i++) {
        thrd_create(&th[i], so_sleeper, (void *)(size_t)i);
        sleep_ms(10);
    }
    for (int i = 0; i < k; i++) enqueue(&so_tags[i]);
    for (int i = 0; i < k; i++) thrd_join(th[i], NULL);

    int ok = 1;
    for (int i = 0; i < k; i++) if (so_got[i] != i) ok = 0;
    if (visited() != (size_t)k) ok = 0;
    destroyQueue();
    return ok;
}

static int sleeper_order(void) { return run_sleeper_order(8); }

static int fairness_rounds(void)
{
    int ks[4] = { 2, 4, 8, 16 };
    for (int r = 0; r < 3; r++)
        for (int j = 0; j < 4; j++)
            if (!run_sleeper_order(ks[j])) return 0;
    return 1;
}

static void *ns_got_a, *ns_got_b;
static int ns_consumer_a(void *arg) { (void)arg; ns_got_a = dequeue(); return 0; }
static int ns_consumer_b(void *arg) { (void)arg; ns_got_b = dequeue(); return 0; }

/* A sleeps before B; enqueue X then Y. A must get X, B must get Y. */
static int no_steal(void)
{
    initQueue();
    int X = 100, Y = 200;
    thrd_t ta, tb;
    ns_got_a = ns_got_b = (void *)0;
    thrd_create(&ta, ns_consumer_a, NULL);
    sleep_ms(50);
    thrd_create(&tb, ns_consumer_b, NULL);
    sleep_ms(50);
    enqueue(&X);
    sleep_ms(50);
    enqueue(&Y);
    thrd_join(ta, NULL);
    thrd_join(tb, NULL);
    int ok = (ns_got_a == &X) && (ns_got_b == &Y);
    destroyQueue();
    return ok;
}

/* KR sleepers sleep in order. Serve only M of them, then add LR late
 * consumers before serving the rest. Late consumers must not steal items
 * reserved for the still-waiting older sleepers. */
#define KR 6
#define LR 2
#define TR (KR + LR)
static int res_got[TR];
static int res_consumer(void *arg)
{
    int idx = (int)(size_t)arg;
    res_got[idx] = *(int *)dequeue();
    return 0;
}
static int reservation_multi(void)
{
    initQueue();
    static int tags[TR];
    for (int i = 0; i < TR; i++) { tags[i] = i; res_got[i] = -1; }
    thrd_t th[TR];
    int m = 3;

    for (int i = 0; i < KR; i++) {
        thrd_create(&th[i], res_consumer, (void *)(size_t)i);
        sleep_ms(15);
    }
    for (int i = 0; i < m; i++) enqueue(&tags[i]);
    sleep_ms(60);

    for (int i = KR; i < TR; i++) {
        thrd_create(&th[i], res_consumer, (void *)(size_t)i);
        sleep_ms(15);
    }
    for (int i = m; i < KR; i++) enqueue(&tags[i]);
    sleep_ms(60);
    for (int i = KR; i < TR; i++) enqueue(&tags[i]);

    for (int i = 0; i < TR; i++) thrd_join(th[i], NULL);
    int ok = 1;
    for (int i = 0; i < TR; i++) if (res_got[i] != i) ok = 0;
    destroyQueue();
    return ok;
}

static _Atomic int nsa_ret;
static void       *nsa_got;
static int nsa_consumer(void *arg)
{
    (void)arg;
    nsa_got = dequeue();
    atomic_store(&nsa_ret, 1);
    return 0;
}

/* An item is already queued before the consumer starts; it must not block. */
static int no_sleep_when_available(void)
{
    initQueue();
    int x = 5;
    enqueue(&x);
    atomic_store(&nsa_ret, 0);
    nsa_got = (void *)0;
    thrd_t t;
    thrd_create(&t, nsa_consumer, NULL);
    sleep_ms(100);
    int ok = (atomic_load(&nsa_ret) == 1) && (nsa_got == &x);
    thrd_join(t, NULL);
    destroyQueue();
    return ok;
}

int main(int argc, char **argv)
{
    int ok = -1;
    if (argc != 2) { fprintf(stderr, "usage: %s <test>\n", argv[0]); return 1; }

    if      (!strcmp(argv[1], "sleeper_order"))           ok = sleeper_order();
    else if (!strcmp(argv[1], "no_steal"))                ok = no_steal();
    else if (!strcmp(argv[1], "reservation_multi"))       ok = reservation_multi();
    else if (!strcmp(argv[1], "no_sleep_when_available")) ok = no_sleep_when_available();
    else if (!strcmp(argv[1], "fairness_rounds"))         ok = fairness_rounds();
    else { fprintf(stderr, "unknown test: %s\n", argv[1]); return 1; }

    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
CSRC

cat > "$TDIR/probe_visited.c" << 'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "probe_common.h"

#define VP           4
#define VC           4
#define VITEMS_PER_P 2000
#define VTOTAL       (VP * VITEMS_PER_P)
#define VPER_C       (VTOTAL / VC)
#define VMON         3   /* threads calling visited() concurrently */

static int          v_items[VP][VITEMS_PER_P];
static _Atomic int  v_running;
static _Atomic long v_max_ns;

static int v_prod(void *arg)
{
    int pid = (int)(size_t)arg;
    for (int i = 0; i < VITEMS_PER_P; i++)
        enqueue(&v_items[pid][i]);
    return 0;
}

static int v_cons(void *arg)
{
    (void)arg;
    for (int i = 0; i < VPER_C; i++)
        (void)dequeue();
    return 0;
}

/* Track worst-case latency of visited() calls during the storm. */
static int v_monitor(void *arg)
{
    (void)arg;
    while (atomic_load(&v_running)) {
        double t0 = now_ms();
        volatile size_t x = visited();
        (void)x;
        long cur  = (long)((now_ms() - t0) * 1e6);
        long prev = atomic_load(&v_max_ns);
        while (cur > prev &&
               !atomic_compare_exchange_weak(&v_max_ns, &prev, cur)) { }
    }
    return 0;
}

static void v_fill(void)
{
    int val = 0;
    for (int p = 0; p < VP; p++)
        for (int i = 0; i < VITEMS_PER_P; i++)
            v_items[p][i] = val++;
}

static int exact_quiescence(void)
{
    initQueue();
    v_fill();
    thrd_t pr[VP], co[VC];
    for (int i = 0; i < VP; i++) thrd_create(&pr[i], v_prod, (void *)(size_t)i);
    for (int i = 0; i < VC; i++) thrd_create(&co[i], v_cons, NULL);
    for (int i = 0; i < VP; i++) thrd_join(pr[i], NULL);
    for (int i = 0; i < VC; i++) thrd_join(co[i], NULL);
    int ok = (visited() == (size_t)VTOTAL);
    destroyQueue();
    return ok;
}

static int nonblocking_concurrent(void)
{
    initQueue();
    v_fill();
    atomic_store(&v_running, 1);
    atomic_store(&v_max_ns, 0);

    thrd_t pr[VP], co[VC], mon[VMON];
    for (int i = 0; i < VMON; i++) thrd_create(&mon[i], v_monitor, NULL);
    for (int i = 0; i < VP; i++)   thrd_create(&pr[i], v_prod, (void *)(size_t)i);
    for (int i = 0; i < VC; i++)   thrd_create(&co[i], v_cons, NULL);

    for (int i = 0; i < VP; i++) thrd_join(pr[i], NULL);
    for (int i = 0; i < VC; i++) thrd_join(co[i], NULL);
    atomic_store(&v_running, 0);
    for (int i = 0; i < VMON; i++) thrd_join(mon[i], NULL);

    int exact = (visited() == (size_t)VTOTAL);
    /* A lock-free read takes microseconds; 1 s catches any visited() that
     * actually blocks on queue state rather than just reading an atomic. */
    int fast = (atomic_load(&v_max_ns) < 1000L * 1000L * 1000L);
    destroyQueue();
    return exact && fast;
}

int main(int argc, char **argv)
{
    int ok = -1;
    if (argc != 2) { fprintf(stderr, "usage: %s <test>\n", argv[0]); return 1; }

    if      (!strcmp(argv[1], "exact_quiescence"))      ok = exact_quiescence();
    else if (!strcmp(argv[1], "nonblocking_concurrent"))ok = nonblocking_concurrent();
    else { fprintf(stderr, "unknown test: %s\n", argv[1]); return 1; }

    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
CSRC

cat > "$TDIR/probe_stress.c" << 'CSRC'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "probe_common.h"

#define S_MAXITEMS 20000
static int         s_items[S_MAXITEMS];
static _Atomic int s_seen[S_MAXITEMS];
static int         oo_got[S_MAXITEMS];

static int g_ipp;
static int g_perc;
static int g_oo_n;

static int prod_fn(void *arg)
{
    int p = (int)(size_t)arg;
    for (int i = 0; i < g_ipp; i++)
        enqueue(&s_items[p * g_ipp + i]);
    return 0;
}

static int cons_fn(void *arg)
{
    (void)arg;
    for (int i = 0; i < g_perc; i++)
        atomic_fetch_add(&s_seen[*(int *)dequeue()], 1);
    return 0;
}

/* Each consumer dequeues a fixed, divisible share so no consumer ever
 * blocks indefinitely (deadlock-free by construction). */
static int run_mxn(int mp, int nc, int ipp, int consumers_first)
{
    int tot = mp * ipp;
    if (mp > 64 || nc > 64 || tot > S_MAXITEMS || tot % nc != 0)
        return 0;
    g_ipp  = ipp;
    g_perc = tot / nc;

    initQueue();
    for (int v = 0; v < tot; v++) { s_items[v] = v; atomic_store(&s_seen[v], 0); }

    thrd_t pr[64], co[64];
    if (consumers_first) {
        for (int i = 0; i < nc; i++) thrd_create(&co[i], cons_fn, NULL);
        sleep_ms(100);   /* let all consumers block before any item arrives */
        for (int i = 0; i < mp; i++) thrd_create(&pr[i], prod_fn, (void *)(size_t)i);
    } else {
        for (int i = 0; i < mp; i++) thrd_create(&pr[i], prod_fn, (void *)(size_t)i);
        for (int i = 0; i < nc; i++) thrd_create(&co[i], cons_fn, NULL);
    }
    for (int i = 0; i < mp; i++) thrd_join(pr[i], NULL);
    for (int i = 0; i < nc; i++) thrd_join(co[i], NULL);

    int ok = 1;
    for (int v = 0; v < tot; v++)
        if (atomic_load(&s_seen[v]) != 1) ok = 0;
    if (visited() != (size_t)tot) ok = 0;
    destroyQueue();
    return ok;
}

static int oo_cons(void *arg)
{
    (void)arg;
    for (int i = 0; i < g_oo_n; i++)
        oo_got[i] = *(int *)dequeue();
    return 0;
}

static int one_to_one_fifo(void)
{
    int n = 5000;
    g_oo_n = n;
    initQueue();
    for (int v = 0; v < n; v++) s_items[v] = v;
    thrd_t c;
    thrd_create(&c, oo_cons, NULL);
    for (int v = 0; v < n; v++) enqueue(&s_items[v]);
    thrd_join(c, NULL);
    int ok = 1;
    for (int i = 0; i < n; i++) if (oo_got[i] != i) ok = 0;
    if (visited() != (size_t)n) ok = 0;
    destroyQueue();
    return ok;
}

static int lifecycle(void)
{
    for (int c = 0; c < 5; c++)
        if (!run_mxn(4, 4, 500, 0)) return 0;
    return 1;
}

int main(int argc, char **argv)
{
    int ok = -1;
    if (argc != 2) { fprintf(stderr, "usage: %s <test>\n", argv[0]); return 1; }

    if      (!strcmp(argv[1], "mxn"))             ok = run_mxn(8, 8, 1000, 0);
    else if (!strcmp(argv[1], "one_to_one_fifo")) ok = one_to_one_fifo();
    else if (!strcmp(argv[1], "one_to_many"))     ok = run_mxn(1, 16, 8000, 0);
    else if (!strcmp(argv[1], "many_to_one"))     ok = run_mxn(16, 1, 500, 0);
    else if (!strcmp(argv[1], "consumers_first")) ok = run_mxn(8, 8, 1000, 1);
    else if (!strcmp(argv[1], "lifecycle"))       ok = lifecycle();
    else { fprintf(stderr, "unknown test: %s\n", argv[1]); return 1; }

    puts(ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
CSRC

echo "=== Phase 1: Build and static compliance ==="

if [ -f "$QUEUE_SRC" ]; then
    pass "1.1 queue.c exists"
else
    fail "1.1 queue.c exists"
    echo "Results: $PASS/$((PASS + FAIL)) passed, $FAIL failed"
    exit 1
fi

qc_err=$(gcc "${GRADE_FLAGS[@]}" -c "$QUEUE_SRC" -o "$QUEUE_OBJ" 2>&1)
qc_rc=$?
if [ "$qc_rc" -eq 0 ]; then
    pass "1.2 queue.c compiles with exact grading command"
else
    fail "1.2 queue.c compiles with exact grading command"
    echo "$qc_err"
    echo "Results: $PASS/$((PASS + FAIL)) passed, $FAIL failed"
    exit 1
fi
if [ -z "$qc_err" ]; then
    pass "1.3 queue.c: no compiler warnings"
else
    fail "1.3 queue.c: compiler warnings"
    echo "    $qc_err"
fi

if grep -q '#include[[:space:]]*<threads.h>' "$QUEUE_SRC"; then
    pass "1.4 queue.c includes <threads.h>"
else
    fail "1.4 queue.c must include <threads.h>"
fi

if grep -qE '\bpthread_[a-z]' "$QUEUE_SRC"; then
    fail "1.5 queue.c uses forbidden pthread_ API"
    echo "    $(grep -nE '\bpthread_[a-z]' "$QUEUE_SRC" | head -c 200)"
else
    pass "1.5 queue.c does not use pthread_ API"
fi

# Extract visited() body and scan it for any locking call (PDF: "may not take a lock at all").
visited_body=$(awk '/size_t[[:space:]]+visited[[:space:]]*\(/{f=1} f{print} f&&/^\}/{exit}' "$QUEUE_SRC")
if printf '%s' "$visited_body" | grep -qE 'mtx_lock|mtx_trylock|mtx_timedlock'; then
    fail "1.6 visited() takes a lock (forbidden by spec)"
    printf '%s\n' "$visited_body" | grep -nE 'mtx_lock|mtx_trylock|mtx_timedlock' | head -c 200
else
    pass "1.6 visited() takes no lock (static check)"
fi

build_ok=1
for name in probe_basic probe_block probe_fifo probe_visited probe_stress; do
    out=$(gcc "${GRADE_FLAGS[@]}" -I"$TDIR" "$TDIR/${name}.c" "$QUEUE_OBJ" \
              -o "$TDIR/${name}" 2>&1)
    if [ $? -ne 0 ]; then
        build_ok=0
        echo "Probe build failed: ${name}"
        echo "$out"
    fi
done
if [ "$build_ok" -eq 1 ]; then
    pass "1.7 all 5 API symbols link (probes built against queue.o)"
else
    fail "1.7 probe build/link against queue.o failed"
    echo "Results: $PASS/$((PASS + FAIL)) passed, $FAIL failed"
    exit 1
fi

# Documentation reminders — never fail; comment quality is a grading concern.
if grep -qiE 'AI[[:space:]]*chat|https?://(chat|chatgpt|claude|copilot)' "$QUEUE_SRC"; then
    note "1.8 AI-chat comment found (required by PDF when AI tools are used)"
else
    note "1.8 no AI-chat comment — required by PDF only if AI tools were used"
fi
if grep -qE '/\*|//' "$QUEUE_SRC"; then
    note "1.8 explanatory comments present (PDF asks to document non-trivial parts)"
else
    note "1.8 no comments — PDF asks to document non-trivial logic"
fi

echo ""
echo "=== Phase 2: Single-threaded core semantics ==="

check_probe "2.1 single enqueue/dequeue pointer identity" "$PROBE_BASIC" "single_roundtrip"
check_probe "2.2 FIFO order of N distinct pointers"       "$PROBE_BASIC" "fifo_order"
check_probe "2.3 NULL is a legal item"                    "$PROBE_BASIC" "null_item"
check_probe "2.4 heap and stack pointers round-trip"      "$PROBE_BASIC" "heap_stack_ptrs"
check_probe "2.5 interleaved enqueue/dequeue keeps FIFO"  "$PROBE_BASIC" "interleaved"
check_probe "2.6 visited() counts only enqueued+dequeued" "$PROBE_BASIC" "visited_semantics"
check_probe "2.7 destroy/init reuse cycles (fresh state)" "$PROBE_BASIC" "reinit_cycles"

echo ""
echo "=== Phase 3: Blocking behavior of dequeue ==="

check_probe "3.1 dequeue blocks on empty, released by enqueue"   "$PROBE_BLOCK" "blocks_on_empty"
check_probe "3.2 dequeue does not block when item available"     "$PROBE_BLOCK" "no_block_when_available"
check_probe "3.3 k sleepers released once, each a distinct item" "$PROBE_BLOCK" "k_released_once"

echo ""
echo "=== Phase 4: FIFO wakeup fairness ==="

check_probe "4.1 k sleepers get items in sleep order (FIFO)" "$PROBE_FIFO" "sleeper_order"
check_probe "4.2 no steal: oldest sleeper served first"      "$PROBE_FIFO" "no_steal"
check_probe "4.3 multi-sleeper reservation: no late steal"   "$PROBE_FIFO" "reservation_multi" 15
check_probe "4.4 no sleep when an item is available"         "$PROBE_FIFO" "no_sleep_when_available"
check_probe "4.5 fairness holds across rounds and sizes"     "$PROBE_FIFO" "fairness_rounds" 30

echo ""
echo "=== Phase 5: visited() semantics under concurrency ==="

check_probe "5.1 visited() exact at quiescence"               "$PROBE_VISITED" "exact_quiescence" 20
check_probe "5.2 visited() non-blocking + concurrent + exact" "$PROBE_VISITED" "nonblocking_concurrent" 20

echo ""
echo "=== Phase 6: Multi-threaded correctness and stress ==="

check_probe "6.1 8x8 storm: every item exactly once, visited==total" "$PROBE_STRESS" "mxn" 30
check_probe "6.2 1x1 strict global FIFO order"                       "$PROBE_STRESS" "one_to_one_fifo" 30
check_probe "6.3 1 producer x many consumers: exactly once"          "$PROBE_STRESS" "one_to_many" 30
check_probe "6.4 many producers x 1 consumer: exactly once"          "$PROBE_STRESS" "many_to_one" 30
check_probe "6.5 consumers-start-first hand-off: exactly once"       "$PROBE_STRESS" "consumers_first" 30
check_probe "6.6 lifecycle: repeated init/storm/drain/destroy"       "$PROBE_STRESS" "lifecycle" 60

echo ""
echo "=== Phase 7: Optional cleanup/tooling checks ==="

if command -v valgrind >/dev/null 2>&1; then
    vg_out=$(valgrind --error-exitcode=1 --leak-check=full --errors-for-leak-kinds=all \
                 "$PROBE_BASIC" reinit_cycles 2>&1)
    vg_rc=$?
    if [ "$vg_rc" -eq 0 ] && printf '%s' "$vg_out" | grep -q "PASS"; then
        pass "7.1 valgrind: no leaks/errors on init/enqueue/dequeue/destroy"
    else
        fail "7.1 valgrind reported leaks or errors"
        echo "$vg_out" | grep -iE 'lost|invalid|error' | head -c 400
    fi
else
    note "7.1 valgrind not installed — install with: sudo apt-get install -y valgrind"
fi

echo ""

total=$((PASS + FAIL))
echo "============================================"
echo "Results: $PASS/$total passed, $FAIL failed"
echo "============================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
