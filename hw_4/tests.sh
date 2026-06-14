#!/bin/bash
# =============================================================================
# tests.sh – Comprehensive test suite for the message slot kernel module
#
# Usage:  sudo bash tests.sh        (must be run as root)
#         sudo bash tests.sh -v     (verbose: show probe/command output)
#
# Phases:
#   1 – Build, Module Load, Device Setup
#   2 – Core Sender/Reader CLI Functionality
#   3 – Channel Semantics
#   4 – Multi-Slot Minor Isolation
#   5 – Censorship Semantics
#   6 – Driver Errno and Raw Syscall Errors  (C probes)
#   7 – User Program Input Validation
#   8 – Binary Data and Atomicity            (C probes)
#   9 – Capacity, Stress, and Cleanup        (C probes)
# =============================================================================

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
VERBOSE=${1:-""}

TDIR=$(mktemp -d /tmp/msgslot_test_XXXXXX)

MAJOR=235

# Device files used throughout the suite.
SLOT0=/dev/msgslot_test_0     # general tests  (minor 0)
SLOT1=/dev/msgslot_test_1     # minor isolation (minor 1)
SLOT2=/dev/msgslot_test_2     # minor isolation (minor 2)
SLOT3=/dev/msgslot_test_3     # errno probes    (minor 3)
SLOT100=/dev/msgslot_test_100 # range test      (minor 100)
SLOT255=/dev/msgslot_test_255 # range test      (minor 255)

SENDER="$TDIR/message_sender"
READER="$TDIR/message_reader"

PROBE_ERRNO="$TDIR/probe_errno"
PROBE_FDSTATE="$TDIR/probe_fdstate"
PROBE_BINARY="$TDIR/probe_binary"
PROBE_STRESS="$TDIR/probe_stress"
PROBE_USERPROG="$TDIR/probe_userprog"

MODULE_LOADED=0
declare -a DEVICES_CREATED=()

# ---------------------------------------------------------------------------
# Cleanup – runs on EXIT for any reason.
# ---------------------------------------------------------------------------
cleanup_all() {
    [ "$MODULE_LOADED" -eq 1 ] && rmmod message_slot 2>/dev/null || true
    for dev in "${DEVICES_CREATED[@]+"${DEVICES_CREATED[@]}"}"; do
        rm -f "$dev"
    done
    rm -rf "$TDIR"
    kill "$(jobs -p)" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap 'cleanup_all' EXIT

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This test suite must be run as root (needs insmod/rmmod/mknod)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper functions  (styled after old/tests.sh)
# ---------------------------------------------------------------------------
pass() { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

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

check_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        pass "$name"
    else
        fail "$name"
        echo "    expected to contain : $needle"
        echo "    actual              : $(printf '%s' "$haystack" | head -c 200)"
    fi
}

check_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        fail "$name"
        echo "    should NOT contain : $needle"
        echo "    actual             : $(printf '%s' "$haystack" | head -c 200)"
    else
        pass "$name"
    fi
}

# check_exit NAME EXPECTED_EXIT COMMAND...
check_exit() {
    local name="$1" expected="$2"
    shift 2
    local actual
    if [ -n "$VERBOSE" ]; then
        "$@"; actual=$?
    else
        "$@" > /dev/null 2>&1; actual=$?
    fi
    if [ "$actual" -eq "$expected" ]; then
        pass "$name"
    else
        fail "$name"
        echo "    expected exit: $expected   actual: $actual"
    fi
}

# check_probe NAME PROBE_BIN DEVICE TEST_CASE
# The probe binary must print "PASS" to stdout on success.
check_probe() {
    local name="$1" probe="$2" dev="$3" test_case="$4"
    local result
    result=$(timeout 5 "$probe" "$dev" "$test_case" 2>/dev/null)
    [ -n "$VERBOSE" ] && echo "    probe[$test_case]: $result"
    if [ "$result" = "PASS" ]; then
        pass "$name"
    else
        fail "$name"
        echo "    probe output : $(printf '%s' "$result" | head -c 200)"
    fi
}

# setup_device MINOR PATH – creates the character device node.
setup_device() {
    local minor="$1" path="$2"
    mknod "$path" c $MAJOR "$minor" 2>/dev/null
    chmod 666 "$path"
    DEVICES_CREATED+=("$path")
}

module_load() {
    if insmod "$REPO_DIR/message_slot.ko" 2>/dev/null; then
        MODULE_LOADED=1
        return 0
    fi
    return 1
}

module_unload() {
    if rmmod message_slot 2>/dev/null; then
        MODULE_LOADED=0
        return 0
    fi
    return 1
}

# sanity_check SLOT CHANNEL – quick send+read smoke test; returns 0 on pass.
sanity_check() {
    local slot="$1" ch="$2"
    timeout 5 "$SENDER" "$slot" "$ch" 0 "sanity" > /dev/null 2>&1 || return 1
    local out
    out=$(timeout 5 "$READER" "$slot" "$ch" 2>/dev/null) || return 1
    [ "$out" = "sanity" ]
}

# check_sanity NAME SLOT CHANNEL – sanity check as a scored test case.
check_sanity() {
    local name="$1" slot="$2" ch="$3"
    if sanity_check "$slot" "$ch"; then
        pass "$name"
    else
        fail "$name"
    fi
}

# =============================================================================
# EMIT PROBE HELPER SOURCE FILES
# =============================================================================

# ---------------------------------------------------------------------------
# probe_errno.c – raw syscall error-condition tests
# ---------------------------------------------------------------------------
cat > "$TDIR/probe_errno.c" << 'CSRC'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "message_slot.h"

#define BAD_IOCTL _IOW(MAJOR_NUM, 99, unsigned int)

static void run(const char *dev, const char *t)
{
    int fd, rc;
    ssize_t ret;
    char buf[BUF_LEN];
    char big[BUF_LEN + 1];

    if (strcmp(t, "write_no_channel") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        ret = write(fd, "hello", 5);
        if (ret == -1 && errno == EINVAL) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "read_no_channel") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        ret = read(fd, buf, BUF_LEN);
        if (ret == -1 && errno == EINVAL) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "channel_zero") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        rc = ioctl(fd, MSG_SLOT_CHANNEL, 0);
        if (rc == -1 && errno == EINVAL) puts("PASS");
        else printf("FAIL rc=%d errno=%d(%s)\n", rc, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "bad_ioctl") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        rc = ioctl(fd, BAD_IOCTL, 0);
        if (rc == -1 && errno == EINVAL) puts("PASS");
        else printf("FAIL rc=%d errno=%d(%s)\n", rc, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "write_zero_len") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 1) != 0) { perror("ioctl"); close(fd); return; }
        ret = write(fd, buf, 0);
        if (ret == -1 && errno == EMSGSIZE) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "write_too_long") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 1) != 0) { perror("ioctl"); close(fd); return; }
        memset(big, 'A', BUF_LEN + 1);
        ret = write(fd, big, BUF_LEN + 1);
        if (ret == -1 && errno == EMSGSIZE) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "read_no_msg") == 0) {
        /* Use channel 253 – never written to on the dedicated errno device. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 253) != 0) { perror("ioctl"); close(fd); return; }
        ret = read(fd, buf, BUF_LEN);
        if (ret == -1 && errno == EWOULDBLOCK) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "read_buf_small") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 2) != 0) { perror("ioctl"); close(fd); return; }
        if (write(fd, "hello", 5) != 5) { perror("write"); close(fd); return; }
        ret = read(fd, buf, 3);   /* buffer smaller than stored 5-byte message */
        if (ret == -1 && errno == ENOSPC) puts("PASS");
        else printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "read_intact_after_small") == 0) {
        /* A failed undersized read must not consume or corrupt the message. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 3) != 0) { perror("ioctl"); close(fd); return; }
        if (write(fd, "hello", 5) != 5) { perror("write"); close(fd); return; }
        ret = read(fd, buf, 3);
        if (ret != -1 || errno != ENOSPC) {
            printf("FAIL small-read ret=%zd errno=%d\n", ret, errno);
            close(fd); return;
        }
        memset(buf, 0, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 5 && memcmp(buf, "hello", 5) == 0) puts("PASS");
        else printf("FAIL full-read ret=%zd data=%.10s\n", ret, buf);
        close(fd);

    } else if (strcmp(t, "bad_cen_mode") == 0) {
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        rc = ioctl(fd, MSG_SLOT_SET_CEN, 2);
        if (rc == -1 && errno == EINVAL) puts("PASS");
        else printf("FAIL rc=%d errno=%d(%s)\n", rc, errno, strerror(errno));
        close(fd);

    } else if (strcmp(t, "invalid_write_ptr") == 0) {
        /* NULL write buffer: invalid operation argument must fail with EINVAL. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 4) != 0) { perror("ioctl"); close(fd); return; }
        ret = write(fd, NULL, 5);
        if (ret == -1 && errno == EINVAL) {
            if (write(fd, "alive", 5) == 5) puts("PASS");
            else puts("FAIL module broken after invalid write ptr");
        } else {
            printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        }
        close(fd);

    } else if (strcmp(t, "invalid_read_ptr") == 0) {
        /* NULL read buffer: invalid operation argument must fail with EINVAL. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 5) != 0) { perror("ioctl"); close(fd); return; }
        if (write(fd, "hello", 5) != 5) { perror("write"); close(fd); return; }
        ret = read(fd, NULL, BUF_LEN);
        if (ret == -1 && errno == EINVAL) {
            memset(buf, 0, BUF_LEN);
            ret = read(fd, buf, BUF_LEN);
            if (ret == 5 && memcmp(buf, "hello", 5) == 0) puts("PASS");
            else printf("FAIL message lost after invalid read ptr ret=%zd\n", ret);
        } else {
            printf("FAIL ret=%zd errno=%d(%s)\n", ret, errno, strerror(errno));
        }
        close(fd);

    } else {
        fprintf(stderr, "Unknown test: %s\n", t);
        exit(1);
    }
}

int main(int argc, char *argv[])
{
    if (argc != 3) { fprintf(stderr, "Usage: %s <device> <test>\n", argv[0]); return 1; }
    run(argv[1], argv[2]);
    return 0;
}
CSRC

# ---------------------------------------------------------------------------
# probe_fdstate.c – per-file-descriptor channel and censorship isolation
# ---------------------------------------------------------------------------
cat > "$TDIR/probe_fdstate.c" << 'CSRC'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "message_slot.h"

static void run(const char *dev, const char *t)
{
    int fd1, fd2, i;
    ssize_t ret;
    char buf[BUF_LEN];

    if (strcmp(t, "two_fds_two_channels") == 0) {
        /* Two FDs on the same device, different channels, independent messages. */
        fd1 = open(dev, O_RDWR); fd2 = open(dev, O_RDWR);
        if (fd1 < 0 || fd2 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 10) != 0 ||
            ioctl(fd2, MSG_SLOT_CHANNEL, 20) != 0) { perror("ioctl"); goto d2; }
        if (write(fd1, "fd1msg", 6) != 6 ||
            write(fd2, "fd2msg", 6) != 6) { perror("write"); goto d2; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd1, buf, BUF_LEN);
        if (ret != 6 || memcmp(buf, "fd1msg", 6) != 0) {
            printf("FAIL fd1 read ret=%zd\n", ret); goto d2;
        }
        memset(buf, 0, BUF_LEN);
        ret = read(fd2, buf, BUF_LEN);
        if (ret != 6 || memcmp(buf, "fd2msg", 6) != 0) {
            printf("FAIL fd2 read ret=%zd\n", ret); goto d2;
        }
        puts("PASS");
d2:     close(fd1); close(fd2);

    } else if (strcmp(t, "channel_change_isolation") == 0) {
        /* Changing fd1's channel must not affect fd2's channel. */
        fd1 = open(dev, O_RDWR); fd2 = open(dev, O_RDWR);
        if (fd1 < 0 || fd2 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 30) != 0 ||
            ioctl(fd2, MSG_SLOT_CHANNEL, 30) != 0) { perror("ioctl"); goto d3; }
        if (write(fd2, "ch30msg", 7) != 7) { perror("write"); goto d3; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 31) != 0) { perror("ioctl31"); goto d3; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd2, buf, BUF_LEN);
        if (ret == 7 && memcmp(buf, "ch30msg", 7) == 0) puts("PASS");
        else printf("FAIL fd2 after fd1 channel change ret=%zd\n", ret);
d3:     close(fd1); close(fd2);

    } else if (strcmp(t, "censor_per_fd") == 0) {
        /* fd1 censored, fd2 uncensored; same channel 40. */
        fd1 = open(dev, O_RDWR); fd2 = open(dev, O_RDWR);
        if (fd1 < 0 || fd2 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 40) != 0 ||
            ioctl(fd2, MSG_SLOT_CHANNEL, 40) != 0) { perror("ioctl"); goto d4; }
        if (ioctl(fd1, MSG_SLOT_SET_CEN, 1) != 0) { perror("set_cen"); goto d4; }
        /* fd1 censored write: "ABCDE" → "ABC#E" stored */
        if (write(fd1, "ABCDE", 5) != 5) { perror("write"); goto d4; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd2, buf, BUF_LEN);
        if (ret != 5 || memcmp(buf, "ABC#E", 5) != 0) {
            printf("FAIL censored write read back ret=%zd data=%.5s\n", ret, buf);
            goto d4;
        }
        /* fd2 uncensored write: "ABCDE" → "ABCDE" stored */
        if (write(fd2, "ABCDE", 5) != 5) { perror("write2"); goto d4; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd1, buf, BUF_LEN);
        if (ret == 5 && memcmp(buf, "ABCDE", 5) == 0) puts("PASS");
        else printf("FAIL uncensored write read back ret=%zd data=%.5s\n", ret, buf);
d4:     close(fd1); close(fd2);

    } else if (strcmp(t, "reopen_no_channel") == 0) {
        /* After close/reopen, new FD has no channel; stored message survives. */
        fd1 = open(dev, O_RDWR); if (fd1 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 50) != 0) { perror("ioctl"); close(fd1); return; }
        if (write(fd1, "persist", 7) != 7) { perror("write"); close(fd1); return; }
        close(fd1);
        fd2 = open(dev, O_RDWR); if (fd2 < 0) { perror("reopen"); return; }
        ret = write(fd2, "test", 4);
        if (ret != -1 || errno != EINVAL) {
            printf("FAIL new fd should have no channel ret=%zd errno=%d\n", ret, errno);
            close(fd2); return;
        }
        if (ioctl(fd2, MSG_SLOT_CHANNEL, 50) != 0) { perror("ioctl2"); close(fd2); return; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd2, buf, BUF_LEN);
        if (ret == 7 && memcmp(buf, "persist", 7) == 0) puts("PASS");
        else printf("FAIL persisted msg not found ret=%zd\n", ret);
        close(fd2);

    } else if (strcmp(t, "censor_toggle_no_cross_fd") == 0) {
        /* Toggling censorship on fd1 must not change fd2's censorship state. */
        fd1 = open(dev, O_RDWR); fd2 = open(dev, O_RDWR);
        if (fd1 < 0 || fd2 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 60) != 0 ||
            ioctl(fd2, MSG_SLOT_CHANNEL, 60) != 0) { perror("ioctl"); goto d5; }
        if (ioctl(fd1, MSG_SLOT_SET_CEN, 1) != 0) { perror("set_cen"); goto d5; }
        for (i = 0; i < 10; i++) {
            if (ioctl(fd1, MSG_SLOT_SET_CEN, i % 2) != 0) {
                puts("FAIL toggle failed"); goto d5;
            }
        }
        /* fd2 writes uncensored "ABCD" – should be stored as "ABCD". */
        if (write(fd2, "ABCD", 4) != 4) { perror("write"); goto d5; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd2, buf, BUF_LEN);
        if (ret == 4 && memcmp(buf, "ABCD", 4) == 0) puts("PASS");
        else printf("FAIL fd2 should be uncensored ret=%zd data=%.4s\n", ret, buf);
d5:     close(fd1); close(fd2);

    } else if (strcmp(t, "default_cen_disabled") == 0) {
        /* No MSG_SLOT_SET_CEN call: default must be uncensored. */
        fd1 = open(dev, O_RDWR); if (fd1 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 70) != 0) { perror("ioctl"); close(fd1); return; }
        /* "ABCD": position 3 would become '#' if censorship were on. */
        if (write(fd1, "ABCD", 4) != 4) { perror("write"); close(fd1); return; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd1, buf, BUF_LEN);
        if (ret == 4 && memcmp(buf, "ABCD", 4) == 0) puts("PASS");
        else printf("FAIL default should be uncensored ret=%zd data=%.4s\n", ret, buf);
        close(fd1);

    } else if (strcmp(t, "censor_stored_unchanged") == 0) {
        /* Changing censorship mode after a write must not modify the stored message. */
        fd1 = open(dev, O_RDWR); if (fd1 < 0) { perror("open"); return; }
        if (ioctl(fd1, MSG_SLOT_CHANNEL, 71) != 0) { perror("ioctl"); close(fd1); return; }
        /* Write uncensored "ABCD". */
        if (write(fd1, "ABCD", 4) != 4) { perror("write"); close(fd1); return; }
        /* Enable censorship AFTER the write. */
        if (ioctl(fd1, MSG_SLOT_SET_CEN, 1) != 0) { perror("set_cen"); close(fd1); return; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd1, buf, BUF_LEN);
        if (ret == 4 && memcmp(buf, "ABCD", 4) == 0) puts("PASS");
        else printf("FAIL stored msg changed after cen enable ret=%zd data=%.4s\n", ret, buf);
        close(fd1);

    } else {
        fprintf(stderr, "Unknown test: %s\n", t);
        exit(1);
    }
}

int main(int argc, char *argv[])
{
    if (argc != 3) { fprintf(stderr, "Usage: %s <device> <test>\n", argv[0]); return 1; }
    run(argv[1], argv[2]);
    return 0;
}
CSRC

# ---------------------------------------------------------------------------
# probe_binary.c – binary data, NUL bytes, and atomicity
# ---------------------------------------------------------------------------
cat > "$TDIR/probe_binary.c" << 'CSRC'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "message_slot.h"

static void run(const char *dev, const char *t)
{
    int fd, i;
    ssize_t ret;
    char buf[BUF_LEN];

    fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return; }

    if (strcmp(t, "nul_bytes") == 0) {
        /* "AB\x00CD" – 5 bytes with an embedded NUL. */
        char msg[5] = {'A', 'B', '\0', 'C', 'D'};
        if (ioctl(fd, MSG_SLOT_CHANNEL, 100) != 0) { perror("ioctl"); goto out; }
        if (write(fd, msg, 5) != 5) { perror("write"); goto out; }
        memset(buf, 0xFF, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 5 && memcmp(buf, msg, 5) == 0) puts("PASS");
        else printf("FAIL ret=%zd\n", ret);

    } else if (strcmp(t, "write_returns_full_len") == 0) {
        if (ioctl(fd, MSG_SLOT_CHANNEL, 101) != 0) { perror("ioctl"); goto out; }
        ret = write(fd, "hello", 5);
        if (ret == 5) puts("PASS");
        else printf("FAIL write returned %zd expected 5\n", ret);

    } else if (strcmp(t, "read_returns_full_len") == 0) {
        if (ioctl(fd, MSG_SLOT_CHANNEL, 102) != 0) { perror("ioctl"); goto out; }
        if (write(fd, "helloworld", 10) != 10) { perror("write"); goto out; }
        ret = read(fd, buf, BUF_LEN);
        if (ret == 10) puts("PASS");
        else printf("FAIL read returned %zd expected 10\n", ret);

    } else if (strcmp(t, "no_msg_after_zero_write") == 0) {
        /* Rejected write(len=0) must leave channel 103 with no message. */
        if (ioctl(fd, MSG_SLOT_CHANNEL, 103) != 0) { perror("ioctl"); goto out; }
        ret = write(fd, buf, 0);
        if (ret != -1 || errno != EMSGSIZE) {
            printf("FAIL expected EMSGSIZE got ret=%zd errno=%d\n", ret, errno); goto out;
        }
        ret = read(fd, buf, BUF_LEN);
        if (ret == -1 && errno == EWOULDBLOCK) puts("PASS");
        else printf("FAIL channel should be empty ret=%zd errno=%d\n", ret, errno);

    } else if (strcmp(t, "prev_msg_after_toolong_write") == 0) {
        /* A too-long write must NOT overwrite the previous message. */
        char big[BUF_LEN + 1];
        if (ioctl(fd, MSG_SLOT_CHANNEL, 104) != 0) { perror("ioctl"); goto out; }
        if (write(fd, "hello", 5) != 5) { perror("write"); goto out; }
        memset(big, 'X', BUF_LEN + 1);
        ret = write(fd, big, BUF_LEN + 1);
        if (ret != -1 || errno != EMSGSIZE) {
            printf("FAIL expected EMSGSIZE got ret=%zd errno=%d\n", ret, errno); goto out;
        }
        memset(buf, 0, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 5 && memcmp(buf, "hello", 5) == 0) puts("PASS");
        else printf("FAIL prev msg lost ret=%zd\n", ret);

    } else if (strcmp(t, "censorship_on_binary") == 0) {
        /* 8-byte all-'A' message, censored: positions 3 and 7 become '#'. */
        char msg[8], expected[8];
        memset(msg, 'A', 8); memset(expected, 'A', 8);
        expected[3] = '#'; expected[7] = '#';
        if (ioctl(fd, MSG_SLOT_CHANNEL, 105) != 0) { perror("ioctl"); goto out; }
        if (ioctl(fd, MSG_SLOT_SET_CEN, 1) != 0) { perror("set_cen"); goto out; }
        if (write(fd, msg, 8) != 8) { perror("write"); goto out; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 8 && memcmp(buf, expected, 8) == 0) puts("PASS");
        else {
            printf("FAIL ret=%zd got=", ret);
            for (i = 0; i < (int)ret && i < 8; i++) printf("%02x", (unsigned char)buf[i]);
            printf("\n");
        }

    } else if (strcmp(t, "all_byte_values") == 0) {
        /* 128-byte message cycling through byte values 0x00..0x7F (uncensored). */
        char msg[BUF_LEN];
        for (i = 0; i < BUF_LEN; i++) msg[i] = (char)(i & 0x7F);
        if (ioctl(fd, MSG_SLOT_CHANNEL, 106) != 0) { perror("ioctl"); goto out; }
        if (write(fd, msg, BUF_LEN) != BUF_LEN) { perror("write"); goto out; }
        memset(buf, 0xFF, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == BUF_LEN && memcmp(buf, msg, BUF_LEN) == 0) puts("PASS");
        else printf("FAIL ret=%zd\n", ret);

    } else {
        fprintf(stderr, "Unknown test: %s\n", t);
        close(fd); exit(1);
    }
out:
    close(fd);
}

int main(int argc, char *argv[])
{
    if (argc != 3) { fprintf(stderr, "Usage: %s <device> <test>\n", argv[0]); return 1; }
    run(argv[1], argv[2]);
    return 0;
}
CSRC

# ---------------------------------------------------------------------------
# probe_stress.c – capacity, overwrite cycles, toggle counts, open/close
# ---------------------------------------------------------------------------
cat > "$TDIR/probe_stress.c" << 'CSRC'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "message_slot.h"

static void run(const char *dev, const char *t)
{
    int fd, i, errors;
    ssize_t ret;
    char buf[BUF_LEN];

    if (strcmp(t, "1024_channels") == 0) {
        /* The spec's channel bound is a count bound, not an id bound. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        for (i = 0; i < 1024; i++) {
            char msg[8]; snprintf(msg, sizeof(msg), "m%04d", i);
            if (ioctl(fd, MSG_SLOT_CHANNEL, (unsigned)(10000 + i)) != 0 ||
                write(fd, msg, 5) != 5) {
                printf("FAIL write ch%d\n", 10000 + i); close(fd); return;
            }
        }
        errors = 0;
        for (i = 0; i < 1024; i++) {
            char exp[8]; snprintf(exp, sizeof(exp), "m%04d", i);
            if (ioctl(fd, MSG_SLOT_CHANNEL, (unsigned)(10000 + i)) != 0) { errors++; continue; }
            memset(buf, 0, BUF_LEN);
            ret = read(fd, buf, BUF_LEN);
            if (ret != 5 || memcmp(buf, exp, 5) != 0) errors++;
        }
        if (errors == 0) puts("PASS");
        else printf("FAIL %d errors in 1024-channel read-back\n", errors);
        close(fd);

    } else if (strcmp(t, "100_channels") == 0) {
        /* Write to channels 200..299, then read all back. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        for (i = 200; i < 300; i++) {
            char msg[7]; snprintf(msg, sizeof(msg), "msg%03d", i);
            if (ioctl(fd, MSG_SLOT_CHANNEL, (unsigned)i) != 0 ||
                write(fd, msg, 6) != 6) {
                printf("FAIL write ch%d\n", i); close(fd); return;
            }
        }
        errors = 0;
        for (i = 200; i < 300; i++) {
            char exp[7]; snprintf(exp, sizeof(exp), "msg%03d", i);
            if (ioctl(fd, MSG_SLOT_CHANNEL, (unsigned)i) != 0) { errors++; continue; }
            memset(buf, 0, BUF_LEN);
            ret = read(fd, buf, BUF_LEN);
            if (ret != 6 || memcmp(buf, exp, 6) != 0) errors++;
        }
        if (errors == 0) puts("PASS");
        else printf("FAIL %d errors in 100-channel read-back\n", errors);
        close(fd);

    } else if (strcmp(t, "overwrite_sizes") == 0) {
        /* Overwrite same channel with 128 → 1 → 50 bytes; verify each. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 300) != 0) { perror("ioctl"); close(fd); return; }
        memset(buf, 'A', BUF_LEN);
        if (write(fd, buf, BUF_LEN) != BUF_LEN) { puts("FAIL write 128"); close(fd); return; }
        ret = read(fd, buf, BUF_LEN);
        if (ret != BUF_LEN) { printf("FAIL read 128 got %zd\n", ret); close(fd); return; }
        if (write(fd, "X", 1) != 1) { puts("FAIL write 1"); close(fd); return; }
        ret = read(fd, buf, BUF_LEN);
        if (ret != 1 || buf[0] != 'X') { printf("FAIL read 1 got %zd\n", ret); close(fd); return; }
        memset(buf, 'B', 50);
        if (write(fd, buf, 50) != 50) { puts("FAIL write 50"); close(fd); return; }
        ret = read(fd, buf, BUF_LEN);
        if (ret == 50) puts("PASS");
        else printf("FAIL read 50 got %zd\n", ret);
        close(fd);

    } else if (strcmp(t, "many_cen_toggles") == 0) {
        /* Toggle censorship 200 times; final state (i=199 → 199%2=1) must be censored. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 400) != 0) { perror("ioctl"); close(fd); return; }
        for (i = 0; i < 200; i++) {
            if (ioctl(fd, MSG_SLOT_SET_CEN, i % 2) != 0) {
                printf("FAIL toggle %d\n", i); close(fd); return;
            }
        }
        /* Final state: censored. Write "ABCDE" → stored "ABC#E". */
        if (write(fd, "ABCDE", 5) != 5) { perror("write"); close(fd); return; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 5 && memcmp(buf, "ABC#E", 5) == 0) puts("PASS");
        else printf("FAIL expected ABC#E got len=%zd data=%.5s\n", ret, buf);
        close(fd);

    } else if (strcmp(t, "open_close_cycles") == 0) {
        /* 50 open/close cycles; message on channel 500 must survive. */
        fd = open(dev, O_RDWR); if (fd < 0) { perror("open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 500) != 0) { perror("ioctl"); close(fd); return; }
        if (write(fd, "persistent", 10) != 10) { perror("write"); close(fd); return; }
        close(fd);
        for (i = 0; i < 50; i++) {
            fd = open(dev, O_RDWR);
            if (fd < 0) { printf("FAIL reopen %d\n", i); return; }
            close(fd);
        }
        fd = open(dev, O_RDWR); if (fd < 0) { perror("final open"); return; }
        if (ioctl(fd, MSG_SLOT_CHANNEL, 500) != 0) { perror("ioctl"); close(fd); return; }
        memset(buf, 0, BUF_LEN);
        ret = read(fd, buf, BUF_LEN);
        if (ret == 10 && memcmp(buf, "persistent", 10) == 0) puts("PASS");
        else printf("FAIL ret=%zd\n", ret);
        close(fd);

    } else if (strcmp(t, "multi_slot_multi_channel") == 0) {
        /* dev is SLOT0; also opens SLOT1 and SLOT2 passed via env. */
        const char *slot1 = getenv("SLOT1");
        const char *slot2 = getenv("SLOT2");
        int fd0, fd1s, fd2s;
        if (!slot1 || !slot2) { puts("FAIL env not set"); return; }
        fd0  = open(dev,   O_RDWR);
        fd1s = open(slot1, O_RDWR);
        fd2s = open(slot2, O_RDWR);
        if (fd0 < 0 || fd1s < 0 || fd2s < 0) { perror("open"); return; }
        /* Same channel 7 on three different minors. */
        if (ioctl(fd0,  MSG_SLOT_CHANNEL, 7) != 0 ||
            ioctl(fd1s, MSG_SLOT_CHANNEL, 7) != 0 ||
            ioctl(fd2s, MSG_SLOT_CHANNEL, 7) != 0) { perror("ioctl"); goto dmulti; }
        if (write(fd0,  "slot0", 5) != 5 ||
            write(fd1s, "slot1", 5) != 5 ||
            write(fd2s, "slot2", 5) != 5) { perror("write"); goto dmulti; }
        errors = 0;
        memset(buf, 0, BUF_LEN);
        ret = read(fd0, buf, BUF_LEN);
        if (ret != 5 || memcmp(buf, "slot0", 5) != 0) errors++;
        memset(buf, 0, BUF_LEN);
        ret = read(fd1s, buf, BUF_LEN);
        if (ret != 5 || memcmp(buf, "slot1", 5) != 0) errors++;
        memset(buf, 0, BUF_LEN);
        ret = read(fd2s, buf, BUF_LEN);
        if (ret != 5 || memcmp(buf, "slot2", 5) != 0) errors++;
        if (errors == 0) puts("PASS");
        else printf("FAIL %d slot isolation errors\n", errors);
dmulti: close(fd0); close(fd1s); close(fd2s);

    } else {
        fprintf(stderr, "Unknown test: %s\n", t);
        exit(1);
    }
}

int main(int argc, char *argv[])
{
    if (argc != 3) { fprintf(stderr, "Usage: %s <device> <test>\n", argv[0]); return 1; }
    run(argv[1], argv[2]);
    return 0;
}
CSRC

# ---------------------------------------------------------------------------
# probe_userprog.c – validates user-space program behavior that shell cannot
# represent safely, especially embedded NUL bytes in reader stdout.
# ---------------------------------------------------------------------------
cat > "$TDIR/probe_userprog.c" << 'CSRC'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include "message_slot.h"

static void run_reader_binary_stdout(const char *dev)
{
    const char *reader = getenv("READER_PATH");
    const unsigned int channel = 1234567;
    const unsigned char msg[5] = {'A', 'B', '\0', 'C', 'D'};
    unsigned char out[BUF_LEN + 16];
    char channel_arg[32];
    int fd, pipefd[2], status;
    pid_t pid;
    ssize_t n;
    size_t total = 0;

    if (reader == NULL || reader[0] == '\0') {
        puts("FAIL READER_PATH not set");
        return;
    }

    fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return; }
    if (ioctl(fd, MSG_SLOT_CHANNEL, channel) != 0) { perror("ioctl"); close(fd); return; }
    if (write(fd, msg, sizeof(msg)) != (ssize_t)sizeof(msg)) { perror("write"); close(fd); return; }
    close(fd);

    if (pipe(pipefd) != 0) { perror("pipe"); return; }
    pid = fork();
    if (pid < 0) { perror("fork"); close(pipefd[0]); close(pipefd[1]); return; }

    if (pid == 0) {
        close(pipefd[0]);
        if (dup2(pipefd[1], STDOUT_FILENO) < 0)
            _exit(111);
        close(pipefd[1]);
        snprintf(channel_arg, sizeof(channel_arg), "%u", channel);
        execl(reader, reader, dev, channel_arg, (char *)NULL);
        _exit(112);
    }

    close(pipefd[1]);
    while ((n = read(pipefd[0], out + total, sizeof(out) - total)) > 0) {
        total += (size_t)n;
        if (total == sizeof(out))
            break;
    }
    close(pipefd[0]);

    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); return; }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        printf("FAIL reader exit status=%d\n", status);
        return;
    }
    if (total == sizeof(msg) && memcmp(out, msg, sizeof(msg)) == 0) {
        puts("PASS");
    } else {
        printf("FAIL stdout length=%zu expected=%zu\n", total, sizeof(msg));
    }
}

int main(int argc, char *argv[])
{
    if (argc != 3) { fprintf(stderr, "Usage: %s <device> <test>\n", argv[0]); return 1; }

    if (strcmp(argv[2], "reader_binary_stdout") == 0) {
        run_reader_binary_stdout(argv[1]);
    } else {
        fprintf(stderr, "Unknown test: %s\n", argv[2]);
        return 1;
    }

    return 0;
}
CSRC

# ---------------------------------------------------------------------------
# Compile probe helpers
# ---------------------------------------------------------------------------
echo "=== Compiling probe helpers ==="
for src in probe_errno probe_fdstate probe_binary probe_stress probe_userprog; do
    compile_err=$(gcc -O2 -Wall -std=c11 \
        -I"$REPO_DIR" "$TDIR/${src}.c" -o "$TDIR/${src}" 2>&1)
    if [ $? -ne 0 ]; then
        echo "Internal error: ${src} probe failed to compile:"
        echo "$compile_err"
        exit 1
    fi
done
echo "Probe helpers compiled OK"
echo ""

# =============================================================================
# PRE-TEST: Build kernel module and user programs (hard-stop on failure)
# =============================================================================
echo "=== Building ==="

make_out=$(make -C "$REPO_DIR" 2>&1)
if [ $? -ne 0 ]; then
    echo "KERNEL MODULE BUILD FAILED:"
    echo "$make_out"
    exit 1
fi
echo "Kernel module build OK"

sender_err=$(gcc -O3 -Wall -std=c11 \
    "$REPO_DIR/message_sender.c" -o "$SENDER" 2>&1)
sender_rc=$?
reader_err=$(gcc -O3 -Wall -std=c11 \
    "$REPO_DIR/message_reader.c" -o "$READER" 2>&1)
reader_rc=$?

if [ $sender_rc -ne 0 ] || [ $reader_rc -ne 0 ]; then
    [ $sender_rc -ne 0 ] && echo "SENDER COMPILE FAILED: $sender_err"
    [ $reader_rc -ne 0 ] && echo "READER COMPILE FAILED: $reader_err"
    exit 1
fi
echo "User programs build OK"
echo ""

# =============================================================================
# PHASE 1 – Build, Module Load, Device Setup
# =============================================================================
echo "=== Phase 1: Build, Module Load, Device Setup ==="

# 1.1 Kernel module compiled without errors – verified above; report as PASS.
pass "1.1 Makefile builds message_slot.ko"

# 1.2 / 1.3 Compiler produces no warnings for user programs.
if [ -z "$sender_err" ]; then
    pass "1.2 message_sender.c: no compiler warnings"
else
    fail "1.2 message_sender.c: compiler warnings"
    echo "    $sender_err"
fi
if [ -z "$reader_err" ]; then
    pass "1.3 message_reader.c: no compiler warnings"
else
    fail "1.3 message_reader.c: compiler warnings"
    echo "    $reader_err"
fi

# 1.4 insmod succeeds.
insmod "$REPO_DIR/message_slot.ko" 2>/dev/null
if [ $? -eq 0 ]; then
    MODULE_LOADED=1
    pass "1.4 insmod message_slot.ko"
else
    fail "1.4 insmod message_slot.ko"
    echo "Cannot continue without the module loaded."
    exit 1
fi

# 1.5 mknod with major 235 minor 0.
mknod "$SLOT0" c $MAJOR 0 2>/dev/null && chmod 666 "$SLOT0"
if [ -e "$SLOT0" ]; then
    DEVICES_CREATED+=("$SLOT0")
    pass "1.5 mknod major=$MAJOR minor=0"
else
    fail "1.5 mknod major=$MAJOR minor=0"
fi

# 1.6 The created device node can be opened.
open_out=$(python3 -c "
import os, sys
try:
    fd = os.open('$SLOT0', os.O_RDWR)
    os.close(fd)
    print('OK')
except Exception as e:
    print('FAIL', e)
" 2>/dev/null)
check "1.6 device node opens successfully" "OK" "$open_out"

# 1.7 Multiple minors can be created.
for minor in 1 2 3 100 255; do
    slot_path="/dev/msgslot_test_${minor}"
    mknod "$slot_path" c $MAJOR "$minor" 2>/dev/null && chmod 666 "$slot_path"
    DEVICES_CREATED+=("$slot_path")
done
all_exist=1
for dev in "$SLOT1" "$SLOT2" "$SLOT3" "$SLOT100" "$SLOT255"; do
    [ -e "$dev" ] || all_exist=0
done
if [ "$all_exist" -eq 1 ]; then
    pass "1.7 mknod with multiple minors (1,2,3,100,255)"
else
    fail "1.7 mknod with multiple minors"
fi

# 1.8 All device nodes can be independently opened.
open_all=$(python3 -c "
import os
slots = ['$SLOT0','$SLOT1','$SLOT2','$SLOT3','$SLOT100','$SLOT255']
fds = []
ok = True
for s in slots:
    try:
        fds.append(os.open(s, os.O_RDWR))
    except Exception as e:
        print('FAIL', s, e); ok = False
for fd in fds:
    os.close(fd)
if ok: print('OK')
" 2>/dev/null)
check "1.8 all device nodes open independently" "OK" "$open_all"

# 1.9 rmmod must fail while a message slot file descriptor is open.
# This functionally verifies .owner = THIS_MODULE in struct file_operations.
hold_log="$TDIR/hold_open.log"
python3 -c "
import os, time
fd = os.open('$SLOT0', os.O_RDWR)
print('OPEN', flush=True)
time.sleep(30)
os.close(fd)
" > "$hold_log" 2>&1 &
holder_pid=$!
for _ in $(seq 1 50); do
    [ -s "$hold_log" ] && break
    sleep 0.1
done
rmmod message_slot 2>/dev/null
rmmod_open_rc=$?
if [ "$rmmod_open_rc" -ne 0 ]; then
    pass "1.9 rmmod fails while device FD is open"
else
    MODULE_LOADED=0
    fail "1.9 rmmod unexpectedly succeeded while FD was open"
fi
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
if [ "$MODULE_LOADED" -eq 0 ]; then
    module_load || { echo "Cannot continue after 1.9 reload failure."; exit 1; }
fi

# 1.10 rmmod succeeds after all descriptors are closed.
module_unload
if [ $? -eq 0 ]; then
    pass "1.10 rmmod succeeds"
else
    fail "1.10 rmmod failed"
fi

# 1.11 Second load/unload cycle (catches stale global state / double-free bugs).
module_load
if [ $? -eq 0 ]; then
    module_unload
    if [ $? -eq 0 ]; then
        pass "1.11 second load/unload cycle succeeds"
    else
        fail "1.11 second unload failed"
    fi
else
    fail "1.11 second load failed"
fi

# Reload the module for all subsequent phases.
module_load
echo ""

# =============================================================================
# PHASE 2 – Core Sender/Reader CLI Functionality
# =============================================================================
echo "=== Phase 2: Core Sender/Reader CLI Functionality ==="

# 2.1 sender exits 0 on success.
check_exit "2.1 sender exits 0 on success" 0 \
    timeout 5 "$SENDER" "$SLOT0" 1 0 "hello"

# 2.2 reader exits 0 when message exists.
check_exit "2.2 reader exits 0 on success" 0 \
    timeout 5 "$READER" "$SLOT0" 1

# 2.3 send/read round-trip: message matches exactly.
check "2.3 send/read round-trip (uncensored)" "hello" \
    "$(timeout 5 "$READER" "$SLOT0" 1 2>/dev/null)"

# 2.4 reader stdout contains only the message – no labels, prompts, or extras.
reader_out=$(timeout 5 "$READER" "$SLOT0" 1 2>/dev/null)
check "2.4 reader stdout is only the message" "hello" "$reader_out"

# 2.5 Censored write: every 4th byte (0-based index 3) replaced with '#'.
check_exit "2.5a sender censored exits 0" 0 \
    timeout 5 "$SENDER" "$SLOT0" 2 1 "ABCDE"
check "2.5b censored ABCDE → ABC#E" "ABC#E" \
    "$(timeout 5 "$READER" "$SLOT0" 2 2>/dev/null)"

# 2.6 Second write overwrites the first.
timeout 5 "$SENDER" "$SLOT0" 3 0 "first"  > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT0" 3 0 "second" > /dev/null 2>&1
check "2.6 second write overwrites first" "second" \
    "$(timeout 5 "$READER" "$SLOT0" 3 2>/dev/null)"

# 2.7 Repeated reads return the same message.
timeout 5 "$SENDER" "$SLOT0" 4 0 "same" > /dev/null 2>&1
check "2.7a first read returns message" "same" \
    "$(timeout 5 "$READER" "$SLOT0" 4 2>/dev/null)"
check "2.7b second read returns same message" "same" \
    "$(timeout 5 "$READER" "$SLOT0" 4 2>/dev/null)"

# 2.8 1-char message (minimum valid length).
timeout 5 "$SENDER" "$SLOT0" 5 0 "A" > /dev/null 2>&1
check "2.8 1-char message round-trip" "A" \
    "$(timeout 5 "$READER" "$SLOT0" 5 2>/dev/null)"

# 2.9 4-char message (uncensored – position 3 would be '#' if censored).
timeout 5 "$SENDER" "$SLOT0" 6 0 "ABCD" > /dev/null 2>&1
check "2.9 4-char uncensored message (no '#')" "ABCD" \
    "$(timeout 5 "$READER" "$SLOT0" 6 2>/dev/null)"

# 2.10 5-char message.
timeout 5 "$SENDER" "$SLOT0" 7 0 "ABCDE" > /dev/null 2>&1
check "2.10 5-char message round-trip" "ABCDE" \
    "$(timeout 5 "$READER" "$SLOT0" 7 2>/dev/null)"

# 2.11 127-char message (BUF_LEN - 1).
msg127=$(python3 -c "print('A'*127, end='')")
timeout 5 "$SENDER" "$SLOT0" 8 0 "$msg127" > /dev/null 2>&1
out127=$(timeout 5 "$READER" "$SLOT0" 8 2>/dev/null)
check "2.11 127-char message length" "127" "${#out127}"

# 2.12 128-char message (BUF_LEN, maximum).
msg128=$(python3 -c "print('B'*128, end='')")
check_exit "2.12a sender 128-char exits 0 (maximum allowed)" 0 \
    timeout 5 "$SENDER" "$SLOT0" 9 0 "$msg128"
out128=$(timeout 5 "$READER" "$SLOT0" 9 2>/dev/null)
check "2.12b 128-char message length" "128" "${#out128}"

# 2.13 Sender uses strlen (no NUL terminator stored).
timeout 5 "$SENDER" "$SLOT0" 10 0 "hi" > /dev/null 2>&1
hi_out=$(timeout 5 "$READER" "$SLOT0" 10 2>/dev/null)
check "2.13 NUL not stored (strlen used – length must be 2)" "2" "${#hi_out}"

# 2.14 Reader writes message to stdout using write() (binary-safe, not printf).
# Verified implicitly by 2.3-2.13; additional stderr check.
stderr_out=$(timeout 5 "$READER" "$SLOT0" 1 2>&1 1>/dev/null)
check_not_contains "2.14 reader success produces no stderr" "error\|Error\|fail\|Fail" \
    "$stderr_out"

echo ""

# =============================================================================
# PHASE 3 – Channel Semantics
# =============================================================================
echo "=== Phase 3: Channel Semantics ==="

# 3.1 Different channels on the same device store independent messages.
timeout 5 "$SENDER" "$SLOT0" 21 0 "channelA" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT0" 22 0 "channelB" > /dev/null 2>&1
check "3.1a channel A message intact" "channelA" \
    "$(timeout 5 "$READER" "$SLOT0" 21 2>/dev/null)"
check "3.1b channel B message intact" "channelB" \
    "$(timeout 5 "$READER" "$SLOT0" 22 2>/dev/null)"

# 3.2 Reading a channel that was never written returns EWOULDBLOCK → reader exits 1.
check_exit "3.2 read unwritten channel exits 1 (EWOULDBLOCK)" 1 \
    timeout 5 "$READER" "$SLOT0" 999

# 3.3 Overwriting channel A does not affect channel B.
timeout 5 "$SENDER" "$SLOT0" 23 0 "origA" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT0" 24 0 "origB" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT0" 23 0 "newA"  > /dev/null 2>&1
check "3.3a overwritten A reads new value" "newA" \
    "$(timeout 5 "$READER" "$SLOT0" 23 2>/dev/null)"
check "3.3b B unchanged after A overwrite" "origB" \
    "$(timeout 5 "$READER" "$SLOT0" 24 2>/dev/null)"

# 3.4 Large non-contiguous channel IDs are accepted.
timeout 5 "$SENDER" "$SLOT0" 42 0 "ch42" > /dev/null 2>&1
check "3.4a channel 42 round-trip" "ch42" \
    "$(timeout 5 "$READER" "$SLOT0" 42 2>/dev/null)"
timeout 5 "$SENDER" "$SLOT0" 999999 0 "bigch" > /dev/null 2>&1
check "3.4b channel 999999 round-trip" "bigch" \
    "$(timeout 5 "$READER" "$SLOT0" 999999 2>/dev/null)"

# 3.5 Channel ID 0 is rejected with EINVAL → sender exits 1.
check_exit "3.5a sender channel 0 exits 1" 1 \
    timeout 5 "$SENDER" "$SLOT0" 0 0 "hello"
check_exit "3.5b reader channel 0 exits 1" 1 \
    timeout 5 "$READER" "$SLOT0" 0

# 3.6 Two FDs on same device with different channels are independent.
check_probe "3.6 two FDs two channels independent" \
    "$PROBE_FDSTATE" "$SLOT0" "two_fds_two_channels"

# 3.7 Changing a channel on one FD does not affect another FD.
check_probe "3.7 channel change isolated to FD" \
    "$PROBE_FDSTATE" "$SLOT0" "channel_change_isolation"

# 3.8 After close/reopen, new FD has no channel; stored message persists.
check_probe "3.8 close/reopen: no channel on new FD, message persists" \
    "$PROBE_FDSTATE" "$SLOT0" "reopen_no_channel"

# Regression: module still functional after phase.
check_sanity "3.9 module operational after phase 3" "$SLOT0" 25

echo ""

# =============================================================================
# PHASE 4 – Multi-Slot Minor Isolation
# =============================================================================
echo "=== Phase 4: Multi-Slot Minor Isolation ==="

# 4.1 Same channel ID on two different minors stores independent messages.
timeout 5 "$SENDER" "$SLOT0" 51 0 "minor0ch51" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT1" 51 0 "minor1ch51" > /dev/null 2>&1
check "4.1a minor 0 channel 51 has its own message" "minor0ch51" \
    "$(timeout 5 "$READER" "$SLOT0" 51 2>/dev/null)"
check "4.1b minor 1 channel 51 has its own message" "minor1ch51" \
    "$(timeout 5 "$READER" "$SLOT1" 51 2>/dev/null)"

# 4.2 Writing to minor 0 channel 7 does not affect minor 1 channel 7.
timeout 5 "$SENDER" "$SLOT0" 7 0 "s0c7" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT1" 7 0 "s1c7" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT0" 7 0 "s0c7_new" > /dev/null 2>&1
check "4.2 write to minor 0 ch 7 does not affect minor 1 ch 7" "s1c7" \
    "$(timeout 5 "$READER" "$SLOT1" 7 2>/dev/null)"

# 4.3 Fresh minor/channel combination returns EWOULDBLOCK.
check_exit "4.3 read fresh slot/channel exits 1 (EWOULDBLOCK)" 1 \
    timeout 5 "$READER" "$SLOT2" 1

# 4.4 Repeated open/close on a minor preserves its channel data.
timeout 5 "$SENDER" "$SLOT1" 52 0 "keepme" > /dev/null 2>&1
for i in $(seq 1 10); do
    python3 -c "import os; fd=os.open('$SLOT1',os.O_RDWR); os.close(fd)" 2>/dev/null
done
check "4.4 open/close cycles preserve channel data on minor 1" "keepme" \
    "$(timeout 5 "$READER" "$SLOT1" 52 2>/dev/null)"

# 4.5 Independence across several minors (0, 1, 2, 100, 255).
timeout 5 "$SENDER" "$SLOT0"   53 0 "d0"  > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT1"   53 0 "d1"  > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT2"   53 0 "d2"  > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT100" 53 0 "d100" > /dev/null 2>&1
timeout 5 "$SENDER" "$SLOT255" 53 0 "d255" > /dev/null 2>&1
check "4.5a minor 0   ch53" "d0"   "$(timeout 5 "$READER" "$SLOT0"   53 2>/dev/null)"
check "4.5b minor 1   ch53" "d1"   "$(timeout 5 "$READER" "$SLOT1"   53 2>/dev/null)"
check "4.5c minor 2   ch53" "d2"   "$(timeout 5 "$READER" "$SLOT2"   53 2>/dev/null)"
check "4.5d minor 100 ch53" "d100" "$(timeout 5 "$READER" "$SLOT100" 53 2>/dev/null)"
check "4.5e minor 255 ch53" "d255" "$(timeout 5 "$READER" "$SLOT255" 53 2>/dev/null)"

# 4.6 Multi-slot / multi-channel isolation via stress probe.
export SLOT1 SLOT2
check_probe "4.6 three-minor channel 7 isolation" \
    "$PROBE_STRESS" "$SLOT0" "multi_slot_multi_channel"

echo ""

# =============================================================================
# PHASE 5 – Censorship Semantics
# =============================================================================
echo "=== Phase 5: Censorship Semantics ==="

# 5.1 Default state (no MSG_SLOT_SET_CEN call) is uncensored.
check_probe "5.1 default censorship mode is disabled" \
    "$PROBE_FDSTATE" "$SLOT0" "default_cen_disabled"

# 5.2 Explicit censorship mode 0 disables censorship.
timeout 5 "$SENDER" "$SLOT0" 82 0 "ABCD" > /dev/null 2>&1
check "5.2 explicit cen=0 stores uncensored message" "ABCD" \
    "$(timeout 5 "$READER" "$SLOT0" 82 2>/dev/null)"

# 5.3 Censorship mode 1 enables censorship.
timeout 5 "$SENDER" "$SLOT0" 83 1 "ABCD" > /dev/null 2>&1
check "5.3 cen=1 replaces byte at index 3 with '#'" "ABC#" \
    "$(timeout 5 "$READER" "$SLOT0" 83 2>/dev/null)"

# 5.4 Censorship is per file descriptor, not per channel.
check_probe "5.4 censorship state is per file descriptor" \
    "$PROBE_FDSTATE" "$SLOT0" "censor_per_fd"

# 5.5 Censorship affects writes only; read returns stored bytes as-is.
# Reader FD censorship mode does not alter what is read back.
# (Covered by 5.3: reader has default cen=0 yet reads the censored stored value.)
timeout 5 "$SENDER" "$SLOT0" 84 1 "ABCDE" > /dev/null 2>&1
result_84=$(timeout 5 "$READER" "$SLOT0" 84 2>/dev/null)
check "5.5 read returns stored censored bytes (read cen state irrelevant)" \
    "ABC#E" "$result_84"

# 5.6 Toggling censorship on one FD does not affect another FD's state.
check_probe "5.6 censorship toggle isolated to FD" \
    "$PROBE_FDSTATE" "$SLOT0" "censor_toggle_no_cross_fd"

# 5.7 Changing censorship after a write does not retroactively modify the stored message.
check_probe "5.7 stored message unchanged after censorship mode change" \
    "$PROBE_FDSTATE" "$SLOT0" "censor_stored_unchanged"

# 5.8 Length 1, 2, 3: no index reaches position 3 → message stored unchanged.
timeout 5 "$SENDER" "$SLOT0" 85 1 "A"   > /dev/null 2>&1
check "5.8a cen len=1 unchanged" "A" \
    "$(timeout 5 "$READER" "$SLOT0" 85 2>/dev/null)"
timeout 5 "$SENDER" "$SLOT0" 86 1 "AB"  > /dev/null 2>&1
check "5.8b cen len=2 unchanged" "AB" \
    "$(timeout 5 "$READER" "$SLOT0" 86 2>/dev/null)"
timeout 5 "$SENDER" "$SLOT0" 87 1 "ABC" > /dev/null 2>&1
check "5.8c cen len=3 unchanged" "ABC" \
    "$(timeout 5 "$READER" "$SLOT0" 87 2>/dev/null)"

# 5.9 Length 4: index 3 becomes '#'.
timeout 5 "$SENDER" "$SLOT0" 88 1 "ABCD" > /dev/null 2>&1
check "5.9 cen len=4: index 3 → '#'" "ABC#" \
    "$(timeout 5 "$READER" "$SLOT0" 88 2>/dev/null)"

# 5.10 Length 8: indices 3 and 7 become '#'.
timeout 5 "$SENDER" "$SLOT0" 89 1 "ABCDEFGH" > /dev/null 2>&1
check "5.10 cen len=8: indices 3 and 7 → '#'" "ABC#EFG#" \
    "$(timeout 5 "$READER" "$SLOT0" 89 2>/dev/null)"

# 5.11 Length 128: every 4th byte (positions 3,7,11,...,127) replaced → "AAA#" * 32.
msg128_cen=$(python3 -c "print('A'*128, end='')")
expected_cen=$(python3 -c "print('AAA#'*32, end='')")
timeout 5 "$SENDER" "$SLOT0" 90 1 "$msg128_cen" > /dev/null 2>&1
cen128_out=$(timeout 5 "$READER" "$SLOT0" 90 2>/dev/null)
check "5.11a cen len=128 length preserved" "128" "${#cen128_out}"
check "5.11b cen len=128 content correct (AAA# repeated)" "$expected_cen" "$cen128_out"

# 5.12 Invalid censorship value (2) is rejected with EINVAL → sender exits 1.
check_exit "5.12 invalid cen mode=2 exits 1" 1 \
    timeout 5 "$SENDER" "$SLOT0" 91 2 "ABCDE"

# Regression: module still functional after censorship tests.
check_sanity "5.13 module operational after phase 5" "$SLOT0" 92

echo ""

# =============================================================================
# PHASE 6 – Driver Errno and Raw Syscall Errors
# =============================================================================
echo "=== Phase 6: Driver Errno and Raw Syscall Errors ==="

# All errno probe tests run on the dedicated SLOT3 (minor 3) to avoid
# contaminating channels used in other phases.

# 6.1 write() without channel set → EINVAL.
check_probe "6.1 write before channel set → EINVAL" \
    "$PROBE_ERRNO" "$SLOT3" "write_no_channel"

# 6.2 read() without channel set → EINVAL.
check_probe "6.2 read before channel set → EINVAL" \
    "$PROBE_ERRNO" "$SLOT3" "read_no_channel"

# 6.3 MSG_SLOT_CHANNEL with id=0 → EINVAL.
check_probe "6.3 ioctl MSG_SLOT_CHANNEL id=0 → EINVAL" \
    "$PROBE_ERRNO" "$SLOT3" "channel_zero"

# 6.4 Unknown ioctl command → EINVAL.
check_probe "6.4 unknown ioctl command → EINVAL" \
    "$PROBE_ERRNO" "$SLOT3" "bad_ioctl"

# 6.5 write() with length 0 → EMSGSIZE.
check_probe "6.5 write len=0 → EMSGSIZE" \
    "$PROBE_ERRNO" "$SLOT3" "write_zero_len"

# 6.6 write() with length 129 (BUF_LEN+1) → EMSGSIZE.
check_probe "6.6 write len=129 → EMSGSIZE" \
    "$PROBE_ERRNO" "$SLOT3" "write_too_long"

# 6.7 read() from a channel with no message → EWOULDBLOCK.
check_probe "6.7 read from empty channel → EWOULDBLOCK" \
    "$PROBE_ERRNO" "$SLOT3" "read_no_msg"

# 6.8 read() with buffer smaller than stored message → ENOSPC.
check_probe "6.8 read with small buffer → ENOSPC" \
    "$PROBE_ERRNO" "$SLOT3" "read_buf_small"

# 6.9 A failed undersized read must not consume or corrupt the message.
check_probe "6.9 message intact after ENOSPC read failure" \
    "$PROBE_ERRNO" "$SLOT3" "read_intact_after_small"

# 6.10 MSG_SLOT_SET_CEN with value 2 → EINVAL.
check_probe "6.10 MSG_SLOT_SET_CEN value=2 → EINVAL" \
    "$PROBE_ERRNO" "$SLOT3" "bad_cen_mode"

# 6.11 NULL write buffer → EINVAL; module remains usable.
check_probe "6.11 NULL write buffer → EINVAL, module still works" \
    "$PROBE_ERRNO" "$SLOT3" "invalid_write_ptr"

# 6.12 NULL read buffer → EINVAL; stored message remains intact.
check_probe "6.12 NULL read buffer → EINVAL, message intact" \
    "$PROBE_ERRNO" "$SLOT3" "invalid_read_ptr"

# Regression: module still operational after all error injections.
check_sanity "6.13 module operational after phase 6" "$SLOT0" 93

echo ""

# =============================================================================
# PHASE 7 – User Program Input Validation
# =============================================================================
echo "=== Phase 7: User Program Input Validation ==="

# 7.1 sender with no arguments → exit 1.
check_exit "7.1 sender no args → exit 1" 1 \
    timeout 5 "$SENDER"

# 7.2 sender with 1 arg (device only) → exit 1.
check_exit "7.2 sender 1 arg → exit 1" 1 \
    timeout 5 "$SENDER" "$SLOT0"

# 7.3 sender with 3 args (missing message) → exit 1.
check_exit "7.3 sender 3 args (missing message) → exit 1" 1 \
    timeout 5 "$SENDER" "$SLOT0" 1 0

# 7.4 sender with 6 args (extra argument) → exit 1.
check_exit "7.4 sender 6 args (extra) → exit 1" 1 \
    timeout 5 "$SENDER" "$SLOT0" 1 0 "hello" "extra"

# 7.5 reader with no arguments → exit 1.
check_exit "7.5 reader no args → exit 1" 1 \
    timeout 5 "$READER"

# 7.6 reader with 1 arg (device only) → exit 1.
check_exit "7.6 reader 1 arg → exit 1" 1 \
    timeout 5 "$READER" "$SLOT0"

# 7.7 reader with 4 args (extra argument) → exit 1.
check_exit "7.7 reader 4 args (extra) → exit 1" 1 \
    timeout 5 "$READER" "$SLOT0" 1 "extra"

# 7.8 sender with channel 0 → ioctl fails → exit 1.
check_exit "7.8 sender channel=0 → exit 1" 1 \
    timeout 5 "$SENDER" "$SLOT0" 0 0 "hello"

# 7.9 sender with non-existent device → open fails → exit 1.
check_exit "7.9 sender non-existent device → exit 1" 1 \
    timeout 5 "$SENDER" "/dev/does_not_exist_99999" 1 0 "hello"

# 7.10 reader with non-existent device → open fails → exit 1.
check_exit "7.10 reader non-existent device → exit 1" 1 \
    timeout 5 "$READER" "/dev/does_not_exist_99999" 1

# 7.11 sender with empty message "" → write(len=0) → EMSGSIZE → exit 1.
check_exit "7.11 sender empty message → exit 1 (write len=0 → EMSGSIZE)" 1 \
    timeout 5 "$SENDER" "$SLOT0" 11 0 ""

# 7.12 sender with a 128-byte (maximum) message → exit 0.
msg128_v=$(python3 -c "print('C'*128, end='')")
check_exit "7.12 sender 128-byte message → exit 0 (BUF_LEN = max)" 0 \
    timeout 5 "$SENDER" "$SLOT0" 12 0 "$msg128_v"

# 7.13 sender with a 129-byte message → write fails → exit 1.
msg129_v=$(python3 -c "print('C'*129, end='')")
check_exit "7.13 sender 129-byte message → exit 1 (BUF_LEN+1 → EMSGSIZE)" 1 \
    timeout 5 "$SENDER" "$SLOT0" 13 0 "$msg129_v"

# 7.14 reader from an empty (never written) channel → exit 1.
check_exit "7.14 reader empty channel → exit 1 (EWOULDBLOCK)" 1 \
    timeout 5 "$READER" "$SLOT0" 998

# 7.15 sender prints error message to stderr on failure.
stderr_msg=$(timeout 5 "$SENDER" "/dev/does_not_exist_99999" 1 0 "msg" 2>&1 1>/dev/null)
check_contains "7.15 sender prints error to stderr on failure" \
    "open\|No such\|failed\|error\|Error" "$stderr_msg"

echo ""

# =============================================================================
# PHASE 8 – Binary Data and Atomicity
# =============================================================================
echo "=== Phase 8: Binary Data and Atomicity ==="

# 8.1 Message with embedded NUL bytes is stored and retrieved byte-for-byte.
check_probe "8.1 message with embedded NUL bytes" \
    "$PROBE_BINARY" "$SLOT0" "nul_bytes"

# 8.2 Successful write() returns exactly the number of bytes written.
check_probe "8.2 write returns full message length" \
    "$PROBE_BINARY" "$SLOT0" "write_returns_full_len"

# 8.3 Successful read() returns exactly the stored message length.
check_probe "8.3 read returns full stored message length" \
    "$PROBE_BINARY" "$SLOT0" "read_returns_full_len"

# 8.4 Rejected write(len=0) does not create a channel message.
check_probe "8.4 rejected zero-length write: channel remains empty" \
    "$PROBE_BINARY" "$SLOT0" "no_msg_after_zero_write"

# 8.5 Rejected write(len=129) does not overwrite the previous valid message.
check_probe "8.5 rejected over-length write: previous message preserved" \
    "$PROBE_BINARY" "$SLOT0" "prev_msg_after_toolong_write"

# 8.6 Censorship is applied correctly to binary data (byte positions, not chars).
check_probe "8.6 censorship on binary data: positions 3 and 7 replaced" \
    "$PROBE_BINARY" "$SLOT0" "censorship_on_binary"

# 8.7 All 128 distinct byte values survive a write/read round-trip uncensored.
check_probe "8.7 all byte values (0x00–0x7F) survive round-trip" \
    "$PROBE_BINARY" "$SLOT0" "all_byte_values"

# 8.8 message_reader must write exact binary bytes to stdout, not printf("%s").
export READER_PATH="$READER"
check_probe "8.8 message_reader stdout preserves embedded NUL bytes" \
    "$PROBE_USERPROG" "$SLOT0" "reader_binary_stdout"
unset READER_PATH

echo ""

# =============================================================================
# PHASE 9 – Capacity, Stress, and Cleanup
# =============================================================================
echo "=== Phase 9: Capacity, Stress, and Cleanup ==="

# 9.1 100 distinct channels on one slot, all independent.
check_probe "9.1 100 channels: all messages independent" \
    "$PROBE_STRESS" "$SLOT0" "100_channels"

# 9.2 More than 220 distinct channel ids on one slot are supported.
check_probe "9.2 1024 channels: channel count bound is not a small fixed array" \
    "$PROBE_STRESS" "$SLOT0" "1024_channels"

# 9.3 Three minors with the same channel (7) hold independent messages.
#     (Extends 4.6 with explicit multi-slot probe.)
check_probe "9.3 multi-minor multi-channel memory independence" \
    "$PROBE_STRESS" "$SLOT0" "multi_slot_multi_channel"

# 9.4 Same channel overwritten with different sizes (128 → 1 → 50 bytes).
check_probe "9.4 overwrite with shrinking/growing sizes" \
    "$PROBE_STRESS" "$SLOT0" "overwrite_sizes"

# 9.5 200 censorship toggles do not corrupt state; final state is correct.
check_probe "9.5 200 censorship toggles: final state consistent" \
    "$PROBE_STRESS" "$SLOT0" "many_cen_toggles"

# 9.6 50 open/close cycles do not corrupt channel data.
check_probe "9.6 50 open/close cycles: channel data persists" \
    "$PROBE_STRESS" "$SLOT0" "open_close_cycles"

# 9.7 rmmod succeeds after stress tests (all FDs are closed by probe processes).
module_unload
if [ $? -eq 0 ]; then
    pass "9.7 rmmod succeeds after stress (no crash, no refusal)"
else
    fail "9.7 rmmod failed after stress tests"
fi

# 9.8 Reload after stress: module starts clean; basic send/read works.
module_load
if [ $? -ne 0 ]; then
    fail "9.8 reload after stress failed"
else
    # Re-create device nodes (mknod again now that module is freshly loaded).
    for minor in 0 1 2 3 100 255; do
        slot_path="/dev/msgslot_test_${minor}"
        [ -e "$slot_path" ] || { mknod "$slot_path" c $MAJOR "$minor" 2>/dev/null && chmod 666 "$slot_path"; }
    done
    if sanity_check "$SLOT0" 1; then
        pass "9.8 reload after stress: basic send/read works"
    else
        fail "9.8 reload after stress: basic send/read failed"
    fi
fi

# 9.9 Fresh reload has no stale channel state from before.
check_exit "9.9 fresh channel is empty after reload (EWOULDBLOCK)" 1 \
    timeout 5 "$READER" "$SLOT0" 701

echo ""

# =============================================================================
# Summary
# =============================================================================
total=$((PASS + FAIL))
echo "============================================"
echo "Results: $PASS/$total passed, $FAIL failed"
echo "============================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
