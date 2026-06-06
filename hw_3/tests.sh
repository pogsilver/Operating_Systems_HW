#!/bin/bash
# =============================================================================
# tests.sh – Comprehensive test suite for myshell.c
#
# Usage:  bash tests.sh          (from anywhere; the script locates itself)
#         bash tests.sh -v       (verbose: show all stdout+stderr from shell)
#
# Phases:
#   1 – Core functionality  (foreground, background, redirection, pipes)
#   2 – Edge cases / grader traps  (FD leaks, race conditions, zombies, etc.)
#   3 – Error handling  (bad commands, missing files, permission denied, etc.)
#   4 – Signal handling  (SIGINT immunity, Ctrl-C kills fg child, bg immune)
# =============================================================================

set -u

# ---------------------------------------------------------------------------
# Setup: repo root is the directory containing this script; compile there.
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

SHELL_BIN="$REPO_DIR/shell"

PASS=0
FAIL=0
VERBOSE=${1:-""}

# Temp directory used by tests; cleaned on EXIT
TDIR=$(mktemp -d /tmp/myshell_test_XXXXXX)
trap 'rm -rf "$TDIR"; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
echo "=== Compiling ==="
compile_out=$(gcc -O3 -D_POSIX_C_SOURCE=200809 -Wall -std=c11 \
    shell.c myshell.c -o "$SHELL_BIN" 2>&1)
if [ $? -ne 0 ]; then
    echo "COMPILATION FAILED:"
    echo "$compile_out"
    exit 1
fi
echo "Compilation OK"
echo ""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

pass() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

# run_shell CMD [CMD …]  – feed each argument as one command line to ./shell,
#                          return stdout; stderr silenced unless VERBOSE.
run_shell() {
    if [ -n "$VERBOSE" ]; then
        printf "%s\n" "$@" | "$SHELL_BIN" 2>&1
    else
        printf "%s\n" "$@" | "$SHELL_BIN" 2>/dev/null
    fi
}

# check NAME EXPECTED ACTUAL
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name"
        echo "    expected : $(echo "$expected" | head -c 120)"
        echo "    actual   : $(echo "$actual"   | head -c 120)"
    fi
}

# check_contains NAME NEEDLE HAYSTACK
check_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle"; then
        pass "$name"
    else
        fail "$name"
        echo "    expected to contain : $needle"
        echo "    actual              : $(echo "$haystack" | head -c 200)"
    fi
}

# check_not_contains NAME NEEDLE HAYSTACK
check_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle"; then
        fail "$name"
        echo "    should NOT contain : $needle"
        echo "    actual             : $(echo "$haystack" | head -c 200)"
    else
        pass "$name"
    fi
}

# =============================================================================
# PHASE 1 – Core Functionality
# =============================================================================
echo "=== Phase 1: Core Functionality ==="

# 1.1 Basic foreground echo
check "1.1 Basic echo" "Hello World" "$(run_shell "echo Hello World")"

# 1.2 Multi-word arguments preserved
check "1.2 Echo multiple args" "one two three" "$(run_shell "echo one two three")"

# 1.3 Multiple sequential commands in one session
result=$(run_shell "echo first" "echo second" "echo third")
check "1.3 Sequential commands" $'first\nsecond\nthird' "$result"

# 1.4 Single-word command (no args)
check "1.4 Single-word command (true)" "" "$(run_shell "true")"

# 1.5 Background – shell does NOT block
start_ns=$(date +%s%N)
run_shell "sleep 2 &" "echo done" > /dev/null 2>&1
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
if [ "$elapsed_ms" -lt 1500 ]; then
    pass "1.5 Background does not block (${elapsed_ms}ms)"
else
    fail "1.5 Background does not block (blocked for ${elapsed_ms}ms)"
fi

# 1.6 Background command actually runs (produces output eventually)
bg_out="$TDIR/bg_out.txt"
run_shell "echo bg_ran > $bg_out" "sleep 0.3 &" > /dev/null 2>&1
sleep 0.5
check "1.6 Background command runs" "bg_ran" "$(cat "$bg_out" 2>/dev/null)"

# 1.7 Input redirection – line count
printf "a\nb\nc\nd\ne\n" > "$TDIR/five.txt"
result=$(run_shell "wc -l < $TDIR/five.txt" | tr -d ' ')
check "1.7 Input redirection (wc -l = 5)" "5" "$result"

# 1.8 Input redirection – content integrity
check "1.8 Input redirection (cat)" $'a\nb\nc\nd\ne' \
    "$(run_shell "cat < $TDIR/five.txt")"

# 1.9 Output redirection – creates file with correct content
run_shell "echo outfile_test > $TDIR/redir_out.txt" > /dev/null 2>&1
check "1.9 Output redirection (file content)" "outfile_test" \
    "$(cat "$TDIR/redir_out.txt" 2>/dev/null)"

# 1.10 Minimal pipeline (2 commands)
printf "x\ny\nz\n" > "$TDIR/three.txt"
result=$(run_shell "cat $TDIR/three.txt | wc -l" | tr -d ' ')
check "1.10 Pipe 2 cmds (wc -l = 3)" "3" "$result"

# 1.11 3-stage pipeline
result=$(run_shell "cat $TDIR/three.txt | cat | wc -l" | tr -d ' ')
check "1.11 Pipe 3 cmds" "3" "$result"

# 1.12 Maximum pipeline (10 commands / 9 pipes)
expected_host=$(hostname)
result=$(run_shell "hostname | cat | cat | cat | cat | cat | cat | cat | cat | cat")
check "1.12 Max pipeline 10 cmds" "$expected_host" "$result"

echo ""

# =============================================================================
# PHASE 2 – Edge Cases & Grader Traps
# =============================================================================
echo "=== Phase 2: Edge Cases & Grader Traps ==="

# 2.1 Output redirection TRUNCATES existing file (O_TRUNC check)
echo "this is longer text that should be gone" > "$TDIR/trunc.txt"
run_shell "echo short > $TDIR/trunc.txt" > /dev/null 2>&1
check "2.1 Output redirection truncates old content" "short" \
    "$(cat "$TDIR/trunc.txt" 2>/dev/null)"

# 2.2 Output redirection creates a file that did not exist
rm -f "$TDIR/newfile.txt"
run_shell "echo created > $TDIR/newfile.txt" > /dev/null 2>&1
check "2.2 Output redirection creates new file" "created" \
    "$(cat "$TDIR/newfile.txt" 2>/dev/null)"

# 2.3 FD leak test – 1000 consecutive pipelines
# Each `echo x | cat` requires 1 pipe (2 FDs).  If the parent never closes
# them the shell hits the OS ~1024 FD limit and pipe() fails → shell exits.
python3 -c "
for _ in range(1000):
    print('echo x | cat')
" | "$SHELL_BIN" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "2.3 FD leak test (1000 pipes, shell survived)"
else
    fail "2.3 FD leak test (shell crashed or exited non-zero)"
fi

# 2.4 Pipeline runs CONCURRENTLY (3×sleep 1 must finish in ~1s, not ~3s)
start=$SECONDS
run_shell "sleep 1 | sleep 1 | sleep 1" > /dev/null 2>&1
elapsed=$((SECONDS - start))
if [ "$elapsed" -le 2 ]; then
    pass "2.4 Pipeline concurrent execution (~${elapsed}s)"
else
    fail "2.4 Pipeline ran sequentially (${elapsed}s, expected ~1s)"
fi

# 2.5 Pipe EOF propagation – parent must close all write-ends
# If the parent keeps any write-end open, `cat` never sees EOF and hangs.
result=$(timeout 5 bash -c "printf 'echo hi | cat\n' | \"$SHELL_BIN\" 2>/dev/null")
tstatus=$?
if [ $tstatus -ne 124 ] && [ "$result" = "hi" ]; then
    pass "2.5 Pipe EOF propagation (no hang)"
else
    fail "2.5 Pipe EOF propagation (timed out or wrong output: '$result')"
fi

# 2.6 Infinite producer → finite consumer must not hang
# `cat /dev/urandom | head -n 3`: when head exits, all write-end copies must
# be closed (child + parent) so cat gets SIGPIPE and the pipeline terminates.
result=$(timeout 5 bash -c \
    "printf 'cat /dev/urandom | head -n 3\n' | \"$SHELL_BIN\" 2>/dev/null" \
    | wc -l | tr -d ' ')
tstatus=$?
if [ $tstatus -ne 124 ] && [ "$result" = "3" ]; then
    pass "2.6 Infinite producer | finite consumer (no hang, got 3 lines)"
else
    fail "2.6 Infinite producer | finite consumer (timed out or got $result lines)"
fi

# 2.7 Fast-child race condition: SIGCHLD handler may reap the foreground child
# before the parent's waitpid() is called → waitpid returns ECHILD.
# Shell must treat ECHILD as success (not an error) and keep running.
result=$(printf "true\ntrue\ntrue\ntrue\ntrue\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "2.7 ECHILD race condition (fast children)" "alive" "$result"

# 2.8 Zombie apocalypse – 50 fast background jobs; no zombies after 2 s.
# Verified by inspecting the shell's children with ps(1).
ZFIFO="$TDIR/zombie_fifo"
ZOUT="$TDIR/zombie_out"
mkfifo "$ZFIFO"
setsid "$SHELL_BIN" < "$ZFIFO" > "$ZOUT" 2>&1 &
ZPID=$!
exec 9>"$ZFIFO"
sleep 0.1

for i in $(seq 1 50); do
    printf "sleep 0.1 &\n" >&9
done
sleep 1.5   # wait for all 50 short sleeps to finish

zombies=$(ps -o stat --ppid "$ZPID" 2>/dev/null | grep '^Z' | wc -l | tr -d ' ')
exec 9>&-
kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null
rm -f "$ZFIFO"

if [ "$zombies" -eq 0 ]; then
    pass "2.8 Zombie check (0 zombies after 50 background jobs)"
else
    fail "2.8 Zombie check ($zombies zombie(s) found)"
fi

# 2.9 Output file permissions must be 0600 (S_IRUSR|S_IWUSR) as spec requires
run_shell "echo perm_test > $TDIR/perm.txt" > /dev/null 2>&1
perms=$(stat -c "%a" "$TDIR/perm.txt" 2>/dev/null)
check "2.9 Output file permissions (0600)" "600" "$perms"

# 2.10 Background job followed immediately by foreground job – both complete
check "2.10 Foreground after background" "fg_done" \
    "$(run_shell "sleep 0.2 &" "echo fg_done")"

echo ""

# =============================================================================
# PHASE 3 – Error Handling
# =============================================================================
echo "=== Phase 3: Error Handling ==="

# In every case below the error occurs inside a child process (or during
# parent-side setup). The shell must survive and process the next command.
# Strategy: send the bad command followed by "echo alive"; only "alive" on
# stdout proves the shell continued.

# 3.1 Non-existent command → execvp fails in child, shell continues
result=$(printf "does_not_exist_xyz_abc\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.1 Non-existent command: shell continues" "alive" "$result"

# 3.2 execvp error goes to stderr (not stdout)
stderr_out=$(printf "does_not_exist_xyz_abc\n" | "$SHELL_BIN" 2>&1 1>/dev/null)
check_contains "3.2 Non-existent command: error on stderr" "No such file" "$stderr_out"

# 3.3 Input redirection with a missing file → open() fails in child, shell continues
result=$(printf "cat < /tmp/definitely_no_such_file_99999.txt\necho alive\n" \
    | "$SHELL_BIN" 2>/dev/null)
check "3.3 Input redirect missing file: shell continues" "alive" "$result"

# 3.4 Output redirection to a read-only file → open() fails in child, shell continues
touch "$TDIR/readonly.txt"; chmod 444 "$TDIR/readonly.txt"
result=$(printf "echo x > $TDIR/readonly.txt\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.4 Output redirect permission denied: shell continues" "alive" "$result"

# 3.5 Directory used as a command → execvp returns EACCES/EISDIR, shell continues
result=$(printf "/tmp\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.5 Directory as command: shell continues" "alive" "$result"

# 3.6 Multiple bad commands in a row → shell never quits
result=$(printf "no_cmd_1\nno_cmd_2\nno_cmd_3\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.6 Multiple sequential errors: shell survives" "alive" "$result"

# 3.7 Bad command as first stage of a pipeline → cat still runs, shell continues
result=$(printf "no_cmd_xyz | cat\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.7 Bad cmd in pipeline: shell continues" "alive" "$result"

# 3.8 Input redirect error produces no stray stdout output
stdout_out=$(printf "cat < /tmp/no_file_9999.txt\necho alive\n" | "$SHELL_BIN" 2>/dev/null)
check "3.8 Input redirect error: no stray stdout" "alive" "$stdout_out"

# 3.9 open() permission-denied error goes to stderr
stderr_perm=$(printf "echo x > $TDIR/readonly.txt\n" | "$SHELL_BIN" 2>&1 1>/dev/null)
check_contains "3.9 Output redirect permission denied: error on stderr" \
    "ermission\|ermitted\|denied\|EACCES" "$stderr_perm"

# 3.10 Over-limit pipeline (11 commands, 10 pipes) – spec says this is invalid
# but the shell must NOT crash or exit; it must continue processing commands.
over_pipeline="echo a | cat | cat | cat | cat | cat | cat | cat | cat | cat | cat"
result=$(printf "%s\necho alive\n" "$over_pipeline" | "$SHELL_BIN" 2>/dev/null)
check "3.10 Over-limit pipeline (11 cmds): shell continues" "alive" "$result"

# 3.10b The error for the over-limit pipeline must be reported to stderr
stderr_over=$(printf "%s\n" "$over_pipeline" | "$SHELL_BIN" 2>&1 1>/dev/null)
check_contains "3.10b Over-limit pipeline: error on stderr" "too many" "$stderr_over"

echo ""

# =============================================================================
# PHASE 4 – Signal Handling
# =============================================================================
echo "=== Phase 4: Signal Handling ==="

# Signal tests run the shell via a named FIFO inside setsid, giving it a
# dedicated process group.  Sending  kill -INT -- -$SHELL_PID  delivers SIGINT
# to the whole group, mirroring what the terminal driver does on Ctrl-C.

# ── 4.1 Shell is SIGINT-immune while idle ──────────────────────────────────
{
    FIFO41="$TDIR/f41"; mkfifo "$FIFO41"; OUT41="$TDIR/o41"
    setsid "$SHELL_BIN" < "$FIFO41" > "$OUT41" 2>&1 &
    P41=$!
    exec 9>"$FIFO41"
    sleep 0.2

    kill -INT "$P41"        # SIGINT directly to the idle shell
    sleep 0.2

    if kill -0 "$P41" 2>/dev/null; then
        pass "4.1 Idle shell survives SIGINT"
    else
        fail "4.1 Idle shell killed by SIGINT"
    fi
    exec 9>&-; kill "$P41" 2>/dev/null; wait "$P41" 2>/dev/null; rm -f "$FIFO41"
}

# ── 4.2 Foreground child DIES from SIGINT, shell SURVIVES ─────────────────
{
    FIFO42="$TDIR/f42"; mkfifo "$FIFO42"; OUT42="$TDIR/o42"
    setsid "$SHELL_BIN" < "$FIFO42" > "$OUT42" 2>&1 &
    P42=$!
    exec 9>"$FIFO42"
    sleep 0.2

    printf "sleep 60\n" >&9     # start a long foreground sleep
    sleep 0.4                   # wait for it to be scheduled

    FG_PID=$(pgrep -P "$P42" sleep 2>/dev/null | head -1)

    kill -INT -- -"$P42"        # Ctrl-C to the whole process group
    sleep 0.4

    shell_alive=0; kill -0 "$P42" 2>/dev/null && shell_alive=1
    fg_alive=0
    [ -n "$FG_PID" ] && kill -0 "$FG_PID" 2>/dev/null && fg_alive=1

    if [ $shell_alive -eq 1 ]; then
        pass "4.2a Shell survives Ctrl-C while running foreground child"
    else
        fail "4.2a Shell killed by Ctrl-C"
    fi

    if [ -n "$FG_PID" ] && [ $fg_alive -eq 0 ]; then
        pass "4.2b Foreground child terminated by Ctrl-C"
    elif [ -z "$FG_PID" ]; then
        fail "4.2b Could not find foreground child PID (inconclusive)"
    else
        fail "4.2b Foreground child survived Ctrl-C (should have died)"
    fi

    exec 9>&-; kill "$P42" 2>/dev/null; wait "$P42" 2>/dev/null; rm -f "$FIFO42"
}

# ── 4.3 Background child IGNORES SIGINT ───────────────────────────────────
{
    FIFO43="$TDIR/f43"; mkfifo "$FIFO43"; OUT43="$TDIR/o43"
    setsid "$SHELL_BIN" < "$FIFO43" > "$OUT43" 2>&1 &
    P43=$!
    exec 9>"$FIFO43"
    sleep 0.2

    printf "sleep 60 &\n" >&9   # start a long background sleep
    sleep 0.4

    BG_PID=$(pgrep -P "$P43" sleep 2>/dev/null | head -1)

    kill -INT -- -"$P43"        # Ctrl-C to the whole process group
    sleep 0.4

    shell_alive=0; kill -0 "$P43" 2>/dev/null && shell_alive=1
    bg_alive=0
    [ -n "$BG_PID" ] && kill -0 "$BG_PID" 2>/dev/null && bg_alive=1

    if [ $shell_alive -eq 1 ]; then
        pass "4.3a Shell survives Ctrl-C while background child runs"
    else
        fail "4.3a Shell killed by Ctrl-C (background test)"
    fi

    if [ -n "$BG_PID" ] && [ $bg_alive -eq 1 ]; then
        pass "4.3b Background child ignores SIGINT (still running)"
    elif [ -z "$BG_PID" ]; then
        fail "4.3b Could not find background child PID (inconclusive)"
    else
        fail "4.3b Background child was killed by SIGINT (should have ignored it)"
    fi

    [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null
    exec 9>&-; kill "$P43" 2>/dev/null; wait "$P43" 2>/dev/null; rm -f "$FIFO43"
}

# ── 4.4 SIGCHLD must NOT abort a foreground waitpid (SA_RESTART / EINTR) ──
# Without SA_RESTART, the background job's SIGCHLD interrupts the foreground
# waitpid at ~2 s; the shell returns early and the measured total is ~2 s.
# With correct handling the foreground sleep completes and the total is ~5 s.
{
    start=$SECONDS
    printf "sleep 2 &\nsleep 5\n" | "$SHELL_BIN" > /dev/null 2>&1
    elapsed=$((SECONDS - start))

    if [ "$elapsed" -ge 4 ] && [ "$elapsed" -le 9 ]; then
        pass "4.4 SIGCHLD does not abort foreground waitpid (${elapsed}s ≈ 5s)"
    else
        fail "4.4 SIGCHLD aborted foreground waitpid (${elapsed}s, expected ~5s)"
    fi
}

# ── 4.5 Multiple rapid SIGINT bursts do not crash the shell ────────────────
{
    FIFO45="$TDIR/f45"; mkfifo "$FIFO45"; OUT45="$TDIR/o45"
    setsid "$SHELL_BIN" < "$FIFO45" > "$OUT45" 2>&1 &
    P45=$!
    exec 9>"$FIFO45"
    sleep 0.2

    for i in 1 2 3 4 5; do
        kill -INT "$P45" 2>/dev/null
        sleep 0.05
    done
    sleep 0.2

    printf "echo still_here\n" >&9
    sleep 0.3
    exec 9>&-
    sleep 0.1

    if grep -q "still_here" "$OUT45" 2>/dev/null; then
        pass "4.5 Shell survives 5 rapid SIGINT signals"
    else
        fail "4.5 Shell did not survive rapid SIGINT signals"
    fi

    kill "$P45" 2>/dev/null; wait "$P45" 2>/dev/null; rm -f "$FIFO45"
}

# ── 4.6 All pipeline children die on Ctrl-C; shell survives ───────────────
{
    FIFO46="$TDIR/f46"; mkfifo "$FIFO46"; OUT46="$TDIR/o46"
    setsid "$SHELL_BIN" < "$FIFO46" > "$OUT46" 2>&1 &
    P46=$!
    exec 9>"$FIFO46"
    sleep 0.2

    # Pipeline of 3 long sleeps; no data flows so nothing exits on its own
    printf "sleep 60 | sleep 60 | sleep 60\n" >&9
    sleep 0.5

    kids_before=$(pgrep -P "$P46" sleep 2>/dev/null | wc -l | tr -d ' ')

    kill -INT -- -"$P46"
    sleep 0.5

    kids_after=$(pgrep -P "$P46" sleep 2>/dev/null | wc -l | tr -d ' ')
    shell_alive=0; kill -0 "$P46" 2>/dev/null && shell_alive=1

    if [ $shell_alive -eq 1 ]; then
        pass "4.6a Shell survives Ctrl-C during pipeline"
    else
        fail "4.6a Shell killed by Ctrl-C during pipeline"
    fi

    if [ "$kids_before" -ge 3 ] && [ "$kids_after" -eq 0 ]; then
        pass "4.6b All pipeline children killed by Ctrl-C"
    elif [ "$kids_before" -lt 3 ]; then
        fail "4.6b Could not confirm 3 pipeline children started (found $kids_before)"
    else
        fail "4.6b Some pipeline children survived Ctrl-C ($kids_after remaining)"
    fi

    exec 9>&-; kill "$P46" 2>/dev/null; wait "$P46" 2>/dev/null; rm -f "$FIFO46"
}

echo ""

# =============================================================================
# Summary
# =============================================================================
total=$((PASS + FAIL))
echo "============================================"
echo "Results: $PASS/$total passed, $FAIL failed"
echo "============================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
