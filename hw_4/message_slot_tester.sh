#!/usr/bin/env bash

# ============================================================
# Message Slot Tester - Full Unabridged Edition
# Tests message_slot.c, message_sender.c, message_reader.c
# ============================================================

set +e

MAJOR_NUM=235
MODULE_NAME="message_slot"
KO_FILE="./message_slot.ko"

SENDER_SRC="message_sender.c"
READER_SRC="message_reader.c"
HEADER_SRC="message_slot.h"

SENDER_BIN="./message_sender"
READER_BIN="./message_reader"

SLOT0="/tmp/msgslot_tester_slot0"
SLOT1="/tmp/msgslot_tester_slot1"
SLOT255="/tmp/msgslot_tester_slot255"

TMP_DIR="/tmp/msgslot_tester_$$"
mkdir -p "$TMP_DIR"

if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

GREEN=""
RED=""
YELLOW=""
RESET=""

if [ -t 1 ]; then
    GREEN="$(printf '\033[0;32m')"
    RED="$(printf '\033[0;31m')"
    YELLOW="$(printf '\033[0;33m')"
    RESET="$(printf '\033[0m')"
fi

ERR_EINVAL=22
ERR_EMSGSIZE=90
ERR_EWOULDBLOCK=11
ERR_ENOSPC=28
ERR_EFAULT=14

print_header() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

pass_test() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    echo "${GREEN}[PASS]${RESET} $1"
}

fail_test() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    echo "${RED}[FAIL]${RESET} $1"
    echo "       Reason: $2"
}

warn_msg() {
    WARNINGS=$((WARNINGS + 1))
    echo "${YELLOW}[WARN]${RESET} $1"
}

show_file_if_not_empty() {
    local label="$1"
    local file="$2"

    if [ -s "$file" ]; then
        echo "       $label:"
        sed 's/^/         /' "$file"
    fi
}

cleanup() {
    echo
    echo "Cleaning up tester resources..."

    rm -f "$TMP_DIR"/expected_* "$TMP_DIR"/actual_* "$TMP_DIR"/err_* "$TMP_DIR"/out_* 2>/dev/null
    rm -f "$TMP_DIR"/msgslot_helper.c "$TMP_DIR"/msgslot_helper 2>/dev/null

    if [ -e "$SLOT0" ]; then
        $SUDO rm -f "$SLOT0" >/dev/null 2>&1
    fi

    if [ -e "$SLOT1" ]; then
        $SUDO rm -f "$SLOT1" >/dev/null 2>&1
    fi
    
    if [ -e "$SLOT255" ]; then
        $SUDO rm -f "$SLOT255" >/dev/null 2>&1
    fi

    if lsmod 2>/dev/null | grep -q "^${MODULE_NAME}"; then
        $SUDO rmmod "$MODULE_NAME" >/dev/null 2>&1
    fi

    rm -rf "$TMP_DIR" 2>/dev/null
}

trap cleanup EXIT

write_expected_file() {
    local file="$1"
    local content="$2"
    printf "%s" "$content" > "$file"
}

assert_file_exact() {
    local label="$1"
    local expected_file="$2"
    local actual_file="$3"
    local stderr_file="$4"
    local status="$5"
    local expected_status="$6"

    if [ "$status" -ne "$expected_status" ]; then
        fail_test "$label" "Expected exit status $expected_status, got $status."
        show_file_if_not_empty "stdout" "$actual_file"
        show_file_if_not_empty "stderr" "$stderr_file"
        return
    fi

    cmp -s "$expected_file" "$actual_file"
    if [ $? -eq 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "Output mismatch."
        echo "       Expected bytes:"
        od -An -tx1 -c "$expected_file" | sed 's/^/         /'
        echo "       Actual bytes:"
        od -An -tx1 -c "$actual_file" | sed 's/^/         /'
        show_file_if_not_empty "stderr" "$stderr_file"
    fi
}

assert_sender_success() {
    local label="$1"
    local dev="$2"
    local channel="$3"
    local censor="$4"
    local message="$5"

    local out="$TMP_DIR/out_sender_${TOTAL}.txt"
    local err="$TMP_DIR/err_sender_${TOTAL}.txt"

    "$SENDER_BIN" "$dev" "$channel" "$censor" "$message" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -eq 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "message_sender should have succeeded, but exited with status $status."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

assert_sender_failure() {
    local label="$1"
    local dev="$2"
    local channel="$3"
    local censor="$4"
    local message="$5"

    local out="$TMP_DIR/out_sender_fail_${TOTAL}.txt"
    local err="$TMP_DIR/err_sender_fail_${TOTAL}.txt"

    "$SENDER_BIN" "$dev" "$channel" "$censor" "$message" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -ne 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "message_sender should have failed, but exited with status 0."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

assert_reader_equals() {
    local label="$1"
    local dev="$2"
    local channel="$3"
    local expected="$4"

    local expected_file="$TMP_DIR/expected_${TOTAL}.bin"
    local actual_file="$TMP_DIR/actual_${TOTAL}.bin"
    local err="$TMP_DIR/err_reader_${TOTAL}.txt"

    write_expected_file "$expected_file" "$expected"

    "$READER_BIN" "$dev" "$channel" > "$actual_file" 2> "$err"
    local status=$?

    assert_file_exact "$label" "$expected_file" "$actual_file" "$err" "$status" 0
}

assert_reader_failure() {
    local label="$1"
    local dev="$2"
    local channel="$3"

    local out="$TMP_DIR/out_reader_fail_${TOTAL}.txt"
    local err="$TMP_DIR/err_reader_fail_${TOTAL}.txt"

    "$READER_BIN" "$dev" "$channel" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -ne 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "message_reader should have failed, but exited with status 0."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

assert_command_failure() {
    local label="$1"
    shift

    local out="$TMP_DIR/out_cmd_fail_${TOTAL}.txt"
    local err="$TMP_DIR/err_cmd_fail_${TOTAL}.txt"

    "$@" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -ne 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "Command should have failed, but exited with status 0."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

assert_helper_errno() {
    local label="$1"
    local expected_errno="$2"
    shift 2

    local out="$TMP_DIR/out_helper_${TOTAL}.txt"
    local err="$TMP_DIR/err_helper_${TOTAL}.txt"

    "$TMP_DIR/msgslot_helper" "$@" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -eq "$expected_errno" ]; then
        pass_test "$label"
    else
        fail_test "$label" "Expected errno $expected_errno, got exit status $status."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

assert_helper_success_output() {
    local label="$1"
    local expected="$2"
    shift 2

    local expected_file="$TMP_DIR/expected_helper_${TOTAL}.bin"
    local actual_file="$TMP_DIR/actual_helper_${TOTAL}.bin"
    local err="$TMP_DIR/err_helper_success_${TOTAL}.txt"

    printf "%s" "$expected" > "$expected_file"

    "$TMP_DIR/msgslot_helper" "$@" > "$actual_file" 2> "$err"
    local status=$?

    assert_file_exact "$label" "$expected_file" "$actual_file" "$err" "$status" 0
}

assert_helper_success_text() {
    local label="$1"
    shift

    local out="$TMP_DIR/out_helper_text_${TOTAL}.txt"
    local err="$TMP_DIR/err_helper_text_${TOTAL}.txt"

    "$TMP_DIR/msgslot_helper" "$@" > "$out" 2> "$err"
    local status=$?

    if [ "$status" -eq 0 ]; then
        pass_test "$label"
    else
        fail_test "$label" "Helper should have succeeded, but exited with status $status."
        show_file_if_not_empty "stdout" "$out"
        show_file_if_not_empty "stderr" "$err"
    fi
}

make_repeated_char() {
    local count="$1"
    local char="$2"
    head -c "$count" /dev/zero | tr '\0' "$char"
}

# ------------------------------------------------------------
# 0. Setup and compilation
# ------------------------------------------------------------

print_header "0. Setup and compilation"

for f in "$SENDER_SRC" "$READER_SRC" "$HEADER_SRC" "Makefile"; do
    if [ ! -f "$f" ]; then
        fail_test "Required file exists: $f" "$f was not found."
        exit 1
    else
        pass_test "Required file exists: $f"
    fi
done

gcc -O3 -Wall -std=c11 "$SENDER_SRC" -o "$SENDER_BIN" > "$TMP_DIR/compile_sender.out" 2> "$TMP_DIR/compile_sender.err"
if [ $? -eq 0 ] && ! grep -qi "warning:" "$TMP_DIR/compile_sender.err"; then
    pass_test "Compile message_sender.c"
else
    fail_test "Compile message_sender.c" "Compilation failed or warnings."
    exit 1
fi

gcc -O3 -Wall -std=c11 "$READER_SRC" -o "$READER_BIN" > "$TMP_DIR/compile_reader.out" 2> "$TMP_DIR/compile_reader.err"
if [ $? -eq 0 ] && ! grep -qi "warning:" "$TMP_DIR/compile_reader.err"; then
    pass_test "Compile message_reader.c"
else
    fail_test "Compile message_reader.c" "Compilation failed or warnings."
    exit 1
fi

make clean > "$TMP_DIR/make_clean.out" 2> "$TMP_DIR/make_clean.err"
make > "$TMP_DIR/make.out" 2> "$TMP_DIR/make.err"
if [ $? -eq 0 ] && [ -f "$KO_FILE" ]; then
    pass_test "Build kernel module"
else
    fail_test "Build kernel module" "make failed."
    exit 1
fi

if lsmod 2>/dev/null | grep -q "^${MODULE_NAME}"; then
    $SUDO rmmod "$MODULE_NAME" >/dev/null 2>&1
fi
$SUDO insmod "$KO_FILE" > "$TMP_DIR/insmod.out" 2> "$TMP_DIR/insmod.err"
if [ $? -eq 0 ]; then
    pass_test "Load module"
else
    fail_test "Load module" "insmod failed."
    exit 1
fi

$SUDO rm -f "$SLOT0" "$SLOT1" "$SLOT255" >/dev/null 2>&1
$SUDO mknod "$SLOT0" c "$MAJOR_NUM" 0 >/dev/null 2>&1
mknod0_status=$?
$SUDO mknod "$SLOT1" c "$MAJOR_NUM" 1 >/dev/null 2>&1
mknod1_status=$?
$SUDO mknod "$SLOT255" c "$MAJOR_NUM" 255 >/dev/null 2>&1
mknod255_status=$?

$SUDO chmod 666 "$SLOT0" "$SLOT1" "$SLOT255" >/dev/null 2>&1

if [ "$mknod0_status" -eq 0 ] && [ "$mknod1_status" -eq 0 ] && [ "$mknod255_status" -eq 0 ]; then
    pass_test "Create device files (including slot0, slot1, slot255)"
else
    fail_test "Create device files" "mknod failed."
    exit 1
fi

# ------------------------------------------------------------
# Helper C Program Construction (Full and Exact)
# ------------------------------------------------------------
cat > "$TMP_DIR/msgslot_helper.c" <<'C_EOF'
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <ctype.h>

#include "message_slot.h"

static unsigned int parse_uint(const char* s) {
    char* end = NULL;
    unsigned long value = strtoul(s, &end, 10);
    if (s == end || *end != '\0') {
        fprintf(stderr, "bad unsigned integer: %s\n", s);
        exit(200);
    }
    return (unsigned int)value;
}

static int return_errno(const char* action) {
    int e = errno;
    fprintf(stderr, "%s failed: errno=%d (%s)\n", action, e, strerror(e));
    return e;
}

static int hex_value(char c) {
    if ('0' <= c && c <= '9') {
        return c - '0';
    }
    if ('a' <= c && c <= 'f') {
        return c - 'a' + 10;
    }
    if ('A' <= c && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

static size_t parse_hex(const char* hex, unsigned char* out, size_t max_len) {
    size_t len = strlen(hex);

    if (len % 2 != 0) {
        fprintf(stderr, "hex string must have even length\n");
        exit(201);
    }

    if (len / 2 > max_len) {
        fprintf(stderr, "hex input too long\n");
        exit(202);
    }

    for (size_t i = 0; i < len; i += 2) {
        int hi = hex_value(hex[i]);
        int lo = hex_value(hex[i + 1]);

        if (hi < 0 || lo < 0) {
            fprintf(stderr, "bad hex digit\n");
            exit(203);
        }

        out[i / 2] = (unsigned char)((hi << 4) | lo);
    }

    return len / 2;
}

static void print_hex(const unsigned char* data, ssize_t len) {
    for (ssize_t i = 0; i < len; ++i) {
        printf("%02X", data[i]);
    }
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: helper mode path ...\n");
        return 199;
    }

    const char* mode = argv[1];
    const char* path = argv[2];

    if (strcmp(mode, "no_channel_read") == 0) {
        char buf[128];
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "no_channel_write") == 0) {
        const char* msg = "abc";
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        ssize_t n = write(fd, msg, 3);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write");
        }

        close(fd);
        printf("write succeeded with %zd bytes\n", n);
        return 0;
    }

    if (strcmp(mode, "zero_channel") == 0) {
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        int rc = ioctl(fd, MSG_SLOT_CHANNEL, 0);
        if (rc < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl zero channel");
        }

        close(fd);
        printf("ioctl zero channel unexpectedly succeeded\n");
        return 0;
    }

    if (strcmp(mode, "bad_ioctl") == 0) {
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        int rc = ioctl(fd, 1234567, 111);
        if (rc < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("bad ioctl");
        }

        close(fd);
        printf("bad ioctl unexpectedly succeeded\n");
        return 0;
    }

    if (strcmp(mode, "empty_write") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper empty_write path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = write(fd, "abc", 0);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("empty write");
        }

        close(fd);
        printf("empty write unexpectedly succeeded with %zd bytes\n", n);
        return 0;
    }

    if (strcmp(mode, "small_read") == 0) {
        if (argc != 5) {
            fprintf(stderr, "usage: helper small_read path channel buflen\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        unsigned int buflen = parse_uint(argv[4]);

        unsigned char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = read(fd, buf, buflen);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("small read");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "raw_write_hex") == 0) {
        if (argc != 6) {
            fprintf(stderr, "usage: helper raw_write_hex path channel censor hex\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        unsigned int censor = parse_uint(argv[4]);
        unsigned char data[256];
        size_t len = parse_hex(argv[5], data, sizeof(data));

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_SET_CEN, censor) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl censor");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = write(fd, data, len);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("raw write");
        }

        close(fd);

        if ((size_t)n != len) {
            fprintf(stderr, "raw write returned partial length: %zd instead of %zu\n", n, len);
            return 204;
        }

        return 0;
    }

    if (strcmp(mode, "raw_read_hex") == 0) {
        if (argc != 5) {
            fprintf(stderr, "usage: helper raw_read_hex path channel buflen\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        unsigned int buflen = parse_uint(argv[4]);
        unsigned char buf[256];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = read(fd, buf, buflen);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("raw read");
        }

        close(fd);
        print_hex(buf, n);
        return 0;
    }

    if (strcmp(mode, "fd_censor_isolation") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper fd_censor_isolation path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);

        int fd1 = open(path, O_RDWR);
        if (fd1 < 0) {
            return return_errno("open fd1");
        }

        int fd2 = open(path, O_RDWR);
        if (fd2 < 0) {
            int e = errno;
            close(fd1);
            errno = e;
            return return_errno("open fd2");
        }

        if (ioctl(fd1, MSG_SLOT_SET_CEN, 1) < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("ioctl censor fd1");
        }

        if (ioctl(fd1, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("ioctl channel fd1");
        }

        if (ioctl(fd2, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("ioctl channel fd2");
        }

        if (write(fd1, "abcd", 4) != 4) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("write fd1");
        }

        if (write(fd2, "wxyz", 4) != 4) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("write fd2");
        }

        char buf[8];
        ssize_t n = read(fd2, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("read fd2");
        }

        close(fd1);
        close(fd2);

        if (n != 4 || memcmp(buf, "wxyz", 4) != 0) {
            fprintf(stderr, "expected wxyz, got: ");
            write(STDERR_FILENO, buf, (size_t)n);
            fprintf(stderr, "\n");
            return 205;
        }

        return 0;
    }


    if (strcmp(mode, "open_close") == 0) {
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (close(fd) < 0) {
            return return_errno("close");
        }

        return 0;
    }

    if (strcmp(mode, "direct_write_read_same_fd") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper direct_write_read_same_fd path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "direct", 6) != 6) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write direct");
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read direct");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "multi_fd_same_channel") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper multi_fd_same_channel path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd1 = open(path, O_RDWR);
        if (fd1 < 0) {
            return return_errno("open fd1");
        }

        int fd2 = open(path, O_RDWR);
        if (fd2 < 0) {
            int e = errno;
            close(fd1);
            errno = e;
            return return_errno("open fd2");
        }

        if (ioctl(fd1, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("ioctl fd1");
        }

        if (ioctl(fd2, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("ioctl fd2");
        }

        if (write(fd1, "shared", 6) != 6) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("write fd1");
        }

        ssize_t n = read(fd2, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd1);
            close(fd2);
            errno = e;
            return return_errno("read fd2");
        }

        close(fd1);
        close(fd2);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "same_fd_switch_channels") == 0) {
        if (argc != 5) {
            fprintf(stderr, "usage: helper same_fd_switch_channels path channel1 channel2\n");
            return 199;
        }

        unsigned int channel1 = parse_uint(argv[3]);
        unsigned int channel2 = parse_uint(argv[4]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel1) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel1");
        }

        if (write(fd, "one", 3) != 3) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write one");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel2) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel2");
        }

        if (write(fd, "two", 3) != 3) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write two");
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read channel2");
        }

        write(STDOUT_FILENO, buf, (size_t)n);
        write(STDOUT_FILENO, "|", 1);

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel1) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("switch back channel1");
        }

        n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read channel1");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "read_twice_same_fd") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper read_twice_same_fd path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n1 = read(fd, buf, sizeof(buf));
        if (n1 < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("first read");
        }

        write(STDOUT_FILENO, buf, (size_t)n1);
        write(STDOUT_FILENO, "|", 1);

        ssize_t n2 = read(fd, buf, sizeof(buf));
        if (n2 < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("second read");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n2);
        return 0;
    }

    if (strcmp(mode, "alternate_censor_same_fd") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper alternate_censor_same_fd path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (ioctl(fd, MSG_SLOT_SET_CEN, 1) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("enable censor");
        }

        if (write(fd, "abcd", 4) != 4) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write censored");
        }

        if (ioctl(fd, MSG_SLOT_SET_CEN, 0) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("disable censor");
        }

        if (write(fd, "wxyz", 4) != 4) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write uncensored");
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read after toggle");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "failed_small_read_keeps_message") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper failed_small_read_keeps_message path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "abcdef", 6) != 6) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write abcdef");
        }

        ssize_t n = read(fd, buf, 3);
        if (n >= 0 || errno != ENOSPC) {
            int e = (n >= 0) ? 0 : errno;
            close(fd);
            if (e == 0) {
                fprintf(stderr, "small read unexpectedly succeeded\n");
                return 206;
            }
            errno = e;
            return return_errno("small read expected ENOSPC");
        }

        n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("full read after failed small read");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "write_then_empty_keeps_old") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper write_then_empty_keeps_old path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "old", 3) != 3) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write old");
        }

        ssize_t n = write(fd, "x", 0);
        if (n >= 0 || errno != EMSGSIZE) {
            int e = (n >= 0) ? 0 : errno;
            close(fd);
            if (e == 0) {
                fprintf(stderr, "empty write unexpectedly succeeded\n");
                return 207;
            }
            errno = e;
            return return_errno("empty write expected EMSGSIZE");
        }

        n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read after failed empty write");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "write_then_oversize_keeps_old") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper write_then_oversize_keeps_old path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char big[129];
        char buf[128];
        memset(big, 'Z', sizeof(big));

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "old", 3) != 3) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write old");
        }

        ssize_t n = write(fd, big, sizeof(big));
        if (n >= 0 || errno != EMSGSIZE) {
            int e = (n >= 0) ? 0 : errno;
            close(fd);
            if (e == 0) {
                fprintf(stderr, "oversize write unexpectedly succeeded\n");
                return 208;
            }
            errno = e;
            return return_errno("oversize write expected EMSGSIZE");
        }

        n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read after failed oversize write");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "bad_user_write") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper bad_user_write path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = write(fd, (const void*)1, 5);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("bad user write");
        }

        close(fd);
        fprintf(stderr, "bad user write unexpectedly succeeded with %zd bytes\n", n);
        return 209;
    }

    if (strcmp(mode, "bad_user_read") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper bad_user_read path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        ssize_t n = read(fd, (void*)1, 5);
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("bad user read");
        }

        close(fd);
        fprintf(stderr, "bad user read unexpectedly succeeded with %zd bytes\n", n);
        return 210;
    }

    if (strcmp(mode, "invalid_ioctl_does_not_destroy_state") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper invalid_ioctl_does_not_destroy_state path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "keep", 4) != 4) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write keep");
        }

        if (ioctl(fd, 7654321, 123) >= 0 || errno != EINVAL) {
            int e = errno;
            close(fd);
            fprintf(stderr, "invalid ioctl did not return EINVAL, errno=%d\n", e);
            return 211;
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read after invalid ioctl");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }

    if (strcmp(mode, "channel_zero_does_not_destroy_previous") == 0) {
        if (argc != 4) {
            fprintf(stderr, "usage: helper channel_zero_does_not_destroy_previous path channel\n");
            return 199;
        }

        unsigned int channel = parse_uint(argv[3]);
        char buf[128];

        int fd = open(path, O_RDWR);
        if (fd < 0) {
            return return_errno("open");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("ioctl channel");
        }

        if (write(fd, "keep", 4) != 4) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("write keep");
        }

        if (ioctl(fd, MSG_SLOT_CHANNEL, 0) >= 0 || errno != EINVAL) {
            int e = errno;
            close(fd);
            fprintf(stderr, "zero channel ioctl did not return EINVAL, errno=%d\n", e);
            return 212;
        }

        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return return_errno("read after zero channel ioctl");
        }

        close(fd);
        write(STDOUT_FILENO, buf, (size_t)n);
        return 0;
    }


    fprintf(stderr, "unknown helper mode: %s\n", mode);
    return 198;
}
C_EOF

gcc -O3 -Wall -std=c11 -I. "$TMP_DIR/msgslot_helper.c" -o "$TMP_DIR/msgslot_helper" > "$TMP_DIR/helper_compile.out" 2> "$TMP_DIR/helper_compile.err"
if [ $? -eq 0 ] && ! grep -qi "warning:" "$TMP_DIR/helper_compile.err"; then
    pass_test "Compile temporary helper for deeper kernel interface tests"
else
    fail_test "Compile temporary helper for deeper kernel interface tests" "Helper compilation failed."
    exit 1
fi

# ------------------------------------------------------------
# Group 1: Basic behavior through message_sender and message_reader
# ------------------------------------------------------------

print_header "1. Basic behavior through sender and reader"

assert_sender_success "Write simple message to slot0 channel 1" "$SLOT0" 1 0 "hello"
assert_reader_equals "Read simple message from slot0 channel 1" "$SLOT0" 1 "hello"
assert_reader_equals "Read same message again, message should persist" "$SLOT0" 1 "hello"

assert_sender_success "Overwrite existing message in same slot and channel" "$SLOT0" 1 0 "bye"
assert_reader_equals "Read overwritten message, should get latest message only" "$SLOT0" 1 "bye"

assert_sender_success "Write message with spaces" "$SLOT0" 2 0 "hello world with spaces"
assert_reader_equals "Read message with spaces exactly" "$SLOT0" 2 "hello world with spaces"

# Extreme boundary lengths
assert_sender_success "Write exactly 1 byte message" "$SLOT0" 101 0 "x"
assert_reader_equals "Read exactly 1 byte message" "$SLOT0" 101 "x"

assert_sender_success "Write exactly 2 byte message" "$SLOT0" 102 0 "ab"
assert_reader_equals "Read exactly 2 byte message" "$SLOT0" 102 "ab"

MSG_127="$(make_repeated_char 127 A)"
MSG_128="$(make_repeated_char 128 A)"
MSG_129="$(make_repeated_char 129 B)"

assert_sender_success "Write exactly 127 bytes, should succeed" "$SLOT0" 103 0 "$MSG_127"
assert_reader_equals "Read exactly 127 bytes" "$SLOT0" 103 "$MSG_127"

assert_sender_success "Write exactly 128 bytes, should succeed" "$SLOT0" 3 0 "$MSG_128"
assert_reader_equals "Read exactly 128 bytes" "$SLOT0" 3 "$MSG_128"

assert_sender_success "Write channel 10 in slot0" "$SLOT0" 10 0 "slot0-channel10"
assert_sender_success "Write channel 11 in slot0" "$SLOT0" 11 0 "slot0-channel11"
assert_reader_equals "Read channel 10, should not be affected by channel 11" "$SLOT0" 10 "slot0-channel10"
assert_reader_equals "Read channel 11, should not be affected by channel 10" "$SLOT0" 11 "slot0-channel11"

assert_sender_success "Write same channel id 20 in slot0" "$SLOT0" 20 0 "message-in-slot0"
assert_sender_success "Write same channel id 20 in slot1" "$SLOT1" 20 0 "message-in-slot1"
assert_reader_equals "Read slot0 channel 20, should be independent from slot1" "$SLOT0" 20 "message-in-slot0"
assert_reader_equals "Read slot1 channel 20, should be independent from slot0" "$SLOT1" 20 "message-in-slot1"

LINE_MSG=$'line1\nline2'
assert_sender_success "Write message containing an internal newline" "$SLOT0" 21 0 "$LINE_MSG"
assert_reader_equals "Read message containing an internal newline exactly" "$SLOT0" 21 "$LINE_MSG"

SPECIAL_MSG='!@#$%^&*()_+=[]{};:,.<>/?'
assert_sender_success "Write special characters" "$SLOT0" 22 0 "$SPECIAL_MSG"
assert_reader_equals "Read special characters exactly" "$SLOT0" 22 "$SPECIAL_MSG"

# ------------------------------------------------------------
# Group 2: Censorship behavior (Expanded)
# ------------------------------------------------------------

print_header "2. Censorship behavior"

assert_sender_success "Write 4 bytes with censorship enabled" "$SLOT0" 30 1 "abcd"
assert_reader_equals "Censorship replaces index 3 with #" "$SLOT0" 30 "abc#"

assert_sender_success "Write 8 bytes with censorship enabled" "$SLOT0" 31 1 "abcdefgh"
assert_reader_equals "Censorship replaces indices 3 and 7 with #" "$SLOT0" 31 "abc#efg#"

assert_sender_success "Write 15 bytes with censorship enabled" "$SLOT0" 32 1 "0123456789abcde"
assert_reader_equals "Censorship works on indices 3, 7, 11" "$SLOT0" 32 "012#456#89a#cde"

assert_sender_success "Write censored message first" "$SLOT0" 33 1 "abcd"
assert_reader_equals "Read stored censored message" "$SLOT0" 33 "abc#"
assert_sender_success "Overwrite same channel with censorship disabled" "$SLOT0" 33 0 "abcd"
assert_reader_equals "Censorship disabled should store original message" "$SLOT0" 33 "abcd"

# Extreme censorship cases
assert_sender_success "Write 3 bytes with censorship enabled (should NOT replace anything)" "$SLOT0" 35 1 "abc"
assert_reader_equals "Censorship ignores strings shorter than 4" "$SLOT0" 35 "abc"

assert_sender_success "Write multiple '#' to see if censorship corrupts existing hashes" "$SLOT0" 36 1 "####"
assert_reader_equals "Censorship on existing '#' works perfectly" "$SLOT0" 36 "####"

assert_helper_success_text "Censorship mode is per file descriptor, not global" fd_censor_isolation "$SLOT0" 34

# ------------------------------------------------------------
# Group 3: Error handling through sender and reader
# ------------------------------------------------------------

print_header "3. Error handling through sender and reader"

assert_reader_failure "Read from unused channel should fail with EWOULDBLOCK" "$SLOT0" 1000

assert_sender_failure "Write with channel id 0 should fail with EINVAL" "$SLOT0" 0 0 "hello"
assert_reader_failure "Read with channel id 0 should fail with EINVAL" "$SLOT0" 0

assert_sender_failure "Write empty message should fail with EMSGSIZE" "$SLOT0" 40 0 ""
assert_sender_failure "Write 129 bytes should fail with EMSGSIZE" "$SLOT0" 41 0 "$MSG_129"

assert_sender_failure "Sender should fail on non existing device path" "/tmp/does_not_exist_msgslot" 1 0 "hello"
assert_reader_failure "Reader should fail on non existing device path" "/tmp/does_not_exist_msgslot" 1

assert_command_failure "Sender should fail with missing command line arguments" "$SENDER_BIN" "$SLOT0" 1 0
assert_command_failure "Reader should fail with missing command line arguments" "$READER_BIN" "$SLOT0"

# ------------------------------------------------------------
# Group 4: Deeper kernel interface edge cases through helper
# ------------------------------------------------------------

print_header "4. Deeper kernel interface edge cases"

assert_helper_errno "read before setting channel should return EINVAL" "$ERR_EINVAL" no_channel_read "$SLOT0"
assert_helper_errno "write before setting channel should return EINVAL" "$ERR_EINVAL" no_channel_write "$SLOT0"
assert_helper_errno "ioctl MSG_SLOT_CHANNEL with channel 0 should return EINVAL" "$ERR_EINVAL" zero_channel "$SLOT0"
assert_helper_errno "unknown ioctl command should return EINVAL" "$ERR_EINVAL" bad_ioctl "$SLOT0"
assert_helper_errno "write with length 0 should return EMSGSIZE" "$ERR_EMSGSIZE" empty_write "$SLOT0" 50

assert_sender_success "Prepare message for small buffer read test" "$SLOT0" 51 0 "abcdef"
assert_helper_errno "read with buffer too small should return ENOSPC" "$ERR_ENOSPC" small_read "$SLOT0" 51 3

assert_helper_success_text "Raw binary write with NUL byte should succeed" raw_write_hex "$SLOT0" 60 0 "410042FF"
assert_helper_success_output "Raw binary read should return exact bytes including NUL and FF" "410042FF" raw_read_hex "$SLOT0" 60 128

assert_helper_success_text "Raw binary write with censorship enabled should succeed" raw_write_hex "$SLOT0" 61 1 "4142434445464748"
assert_helper_success_output "Raw binary censorship should replace every 4th byte with ASCII #, hex 23" "4142432345464723" raw_read_hex "$SLOT0" 61 128

# ------------------------------------------------------------
# Group 5: Many channels and repeated operations
# ------------------------------------------------------------

print_header "5. Many channels and repeated operations"

MANY_OK=1
MANY_REASON=""

for ch in $(seq 2000 2049); do
    msg="many-channel-message-${ch}"
    "$SENDER_BIN" "$SLOT0" "$ch" 0 "$msg" > "$TMP_DIR/many_sender_${ch}.out" 2> "$TMP_DIR/many_sender_${ch}.err"
    st=$?
    if [ "$st" -ne 0 ]; then
        MANY_OK=0
        MANY_REASON="sender failed on channel $ch with status $st"
        break
    fi
done

if [ "$MANY_OK" -eq 1 ]; then
    for ch in $(seq 2000 2049); do
        msg="many-channel-message-${ch}"
        actual="$TMP_DIR/many_actual_${ch}.bin"
        err="$TMP_DIR/many_reader_${ch}.err"
        "$READER_BIN" "$SLOT0" "$ch" > "$actual" 2> "$err"
        st=$?

        expected="$TMP_DIR/many_expected_${ch}.bin"
        printf "%s" "$msg" > "$expected"

        if [ "$st" -ne 0 ]; then
            MANY_OK=0
            MANY_REASON="reader failed on channel $ch with status $st"
            break
        fi

        cmp -s "$expected" "$actual"
        if [ $? -ne 0 ]; then
            MANY_OK=0
            MANY_REASON="wrong message on channel $ch"
            break
        fi
    done
fi

if [ "$MANY_OK" -eq 1 ]; then
    pass_test "Write and read 50 different channels in the same slot"
else
    fail_test "Write and read 50 different channels in the same slot" "$MANY_REASON"
fi

REPEAT_OK=1
REPEAT_REASON=""

for i in $(seq 1 20); do
    msg="repeat-${i}"
    "$SENDER_BIN" "$SLOT1" 3000 0 "$msg" > "$TMP_DIR/repeat_sender_${i}.out" 2> "$TMP_DIR/repeat_sender_${i}.err"
    st=$?
    if [ "$st" -ne 0 ]; then
        REPEAT_OK=0
        REPEAT_REASON="sender failed on iteration $i with status $st"
        break
    fi

    actual="$TMP_DIR/repeat_actual_${i}.bin"
    err="$TMP_DIR/repeat_reader_${i}.err"
    "$READER_BIN" "$SLOT1" 3000 > "$actual" 2> "$err"
    st=$?

    expected="$TMP_DIR/repeat_expected_${i}.bin"
    printf "%s" "$msg" > "$expected"

    if [ "$st" -ne 0 ]; then
        REPEAT_OK=0
        REPEAT_REASON="reader failed on iteration $i with status $st"
        break
    fi

    cmp -s "$expected" "$actual"
    if [ $? -ne 0 ]; then
        REPEAT_OK=0
        REPEAT_REASON="wrong message after overwrite iteration $i"
        break
    fi
done

if [ "$REPEAT_OK" -eq 1 ]; then
    pass_test "Repeated overwrites on same channel always return latest message"
else
    fail_test "Repeated overwrites on same channel always return latest message" "$REPEAT_REASON"
fi


# ------------------------------------------------------------
# Group 6: Additional edge cases, file descriptor behavior,
# invalid user buffers, and larger channel ids
# ------------------------------------------------------------

print_header "6. Additional edge cases and complex behavior"

assert_helper_success_text "Open and close slot0 without choosing a channel" open_close "$SLOT0"
assert_helper_success_text "Open and close slot1 without choosing a channel" open_close "$SLOT1"

assert_sender_success "Write to channel id greater than 2^20, id itself may be large" "$SLOT0" 1048577 0 "large-channel-one"
assert_reader_equals "Read from channel id greater than 2^20" "$SLOT0" 1048577 "large-channel-one"

assert_sender_success "Write to very large ordinary channel id" "$SLOT0" 99999999 0 "very-large-channel"
assert_reader_equals "Read from very large ordinary channel id" "$SLOT0" 99999999 "very-large-channel"

assert_sender_success "Write slot0 channel 7 for independence retest" "$SLOT0" 7 0 "slot0-seven"
assert_sender_success "Write slot1 channel 7 for independence retest" "$SLOT1" 7 0 "slot1-seven"
assert_reader_equals "Read slot0 channel 7 after writing same channel in slot1" "$SLOT0" 7 "slot0-seven"
assert_reader_equals "Read slot1 channel 7 after writing same channel in slot0" "$SLOT1" 7 "slot1-seven"

assert_helper_success_output "Two different file descriptors share the same slot/channel message" "shared" multi_fd_same_channel "$SLOT0" 710
assert_helper_success_output "Same fd can switch channels and preserve both messages in slot0" "two|one" same_fd_switch_channels "$SLOT0" 711 712

assert_sender_success "Prepare message for reading twice from same fd" "$SLOT0" 713 0 "persist"
assert_helper_success_output "Reading twice from same fd should return the same persistent message" "persist|persist" read_twice_same_fd "$SLOT0" 713

assert_helper_success_output "Same fd can turn censorship on and then off before overwriting" "wxyz" alternate_censor_same_fd "$SLOT0" 714
assert_helper_success_output "Failed small read should not consume or damage the message" "abcdef" failed_small_read_keeps_message "$SLOT0" 715

assert_helper_success_output "Failed empty write should not overwrite old message" "old" write_then_empty_keeps_old "$SLOT0" 716
assert_helper_success_output "Failed oversize write should not overwrite old message" "old" write_then_oversize_keeps_old "$SLOT0" 717

assert_sender_success "Write message containing literal # without censorship" "$SLOT0" 718 0 "abc#efg#"
assert_reader_equals "Literal # characters should remain unchanged without censorship" "$SLOT0" 718 "abc#efg#"

assert_sender_success "Censorship enabled on length 3 message should not modify anything" "$SLOT0" 719 1 "abc"
assert_reader_equals "Length 3 censored message should remain abc" "$SLOT0" 719 "abc"

assert_sender_success "Censorship enabled on four # characters should still read four # characters" "$SLOT0" 720 1 "####"
assert_reader_equals "Four # characters with censorship still read as ####" "$SLOT0" 720 "####"

HEX_128="$(printf 'AA%.0s' $(seq 1 128))"
HEX_129="$(printf 'BB%.0s' $(seq 1 129))"

assert_helper_success_text "Raw binary write of exactly 128 bytes should succeed" raw_write_hex "$SLOT0" 721 0 "$HEX_128"
assert_helper_success_output "Raw binary read of exactly 128 bytes should return exact hex" "$HEX_128" raw_read_hex "$SLOT0" 721 128

assert_helper_errno "Raw binary write of 129 bytes should return EMSGSIZE" "$ERR_EMSGSIZE" raw_write_hex "$SLOT0" 722 0 "$HEX_129"
assert_helper_errno "Raw binary write of zero bytes should return EMSGSIZE" "$ERR_EMSGSIZE" raw_write_hex "$SLOT0" 723 0 ""

assert_helper_errno "Write from invalid user pointer should return EFAULT" "$ERR_EFAULT" bad_user_write "$SLOT0" 724
assert_sender_success "Prepare valid message before invalid user read pointer test" "$SLOT0" 725 0 "valid"
assert_helper_errno "Read into invalid user pointer should return EFAULT" "$ERR_EFAULT" bad_user_read "$SLOT0" 725

assert_helper_success_output "Invalid ioctl should not destroy current fd channel state" "keep" invalid_ioctl_does_not_destroy_state "$SLOT0" 726
assert_helper_success_output "Failed channel 0 ioctl should not destroy previous valid channel state" "keep" channel_zero_does_not_destroy_previous "$SLOT0" 727

assert_reader_failure "Read from unused very large channel should fail" "$SLOT0" 88888888
assert_helper_success_output "Direct write and read on the same fd should work" "direct" direct_write_read_same_fd "$SLOT0" 728
assert_helper_success_output "Same fd can switch channels and preserve both messages in slot1" "two|one" same_fd_switch_channels "$SLOT1" 729 730

# ------------------------------------------------------------
# Group 7: Array Bounds, Shrinkage, and Extreme IDs (NEW)
# ------------------------------------------------------------
print_header "7. Array Bounds, Length Shrinkage, and Extreme Edge Cases"

# 7.1 Testing Length Shrinkage (Crucial Bug Check)
MSG_100="$(make_repeated_char 100 S)"
assert_sender_success "Write 100 bytes to channel 500" "$SLOT0" 500 0 "$MSG_100"
assert_sender_success "Overwrite with 5 bytes (Shrinkage Test)" "$SLOT0" 500 0 "short"
assert_reader_equals "Read should return exactly 5 bytes (length updated correctly)" "$SLOT0" 500 "short"

# 7.2 Testing Array Upper Bound (Minor 255)
assert_sender_success "Write to minor 255 (Array absolute limit)" "$SLOT255" 100 0 "edge-of-array"
assert_reader_equals "Read from minor 255" "$SLOT255" 100 "edge-of-array"

assert_sender_success "Write to minor 255 with censorship" "$SLOT255" 101 1 "1234"
assert_reader_equals "Read censored message from minor 255" "$SLOT255" 101 "123#"

# 7.3 Extreme Channel IDs (Boundary Values for 32-bit Unsigned)
assert_sender_success "Write to Max Unsigned Int Channel (4294967295)" "$SLOT0" 4294967295 0 "max-int-limit"
assert_reader_equals "Read from Max Unsigned Int Channel" "$SLOT0" 4294967295 "max-int-limit"

assert_sender_success "Write to Max Int - 1 Channel (4294967294)" "$SLOT0" 4294967294 0 "max-minus-one"
assert_reader_equals "Read from Max Int - 1 Channel" "$SLOT0" 4294967294 "max-minus-one"

# ------------------------------------------------------------
# Group 8: The 100-Iteration Extreme Stress Test (NEW)
# ------------------------------------------------------------
print_header "8. 100-Iteration Extreme Stress Test (Memory Leak & Stability Check)"

STRESS_OK=1
STRESS_FAIL_REASON=""
START_CHANNEL=5000

for i in $(seq 1 100); do
    ch=$((START_CHANNEL + i))
    msg="stress-msg-$i"
    
    # Send
    "$SENDER_BIN" "$SLOT1" "$ch" 0 "$msg" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        STRESS_OK=0
        STRESS_FAIL_REASON="Sender failed on iteration $i (Channel $ch)"
        break
    fi

    # Read
    actual_file="$TMP_DIR/stress_actual_${i}.bin"
    expected_file="$TMP_DIR/stress_expected_${i}.bin"
    printf "%s" "$msg" > "$expected_file"

    "$READER_BIN" "$SLOT1" "$ch" > "$actual_file" 2> /dev/null
    if [ $? -ne 0 ]; then
        STRESS_OK=0
        STRESS_FAIL_REASON="Reader failed on iteration $i (Channel $ch)"
        break
    fi

    cmp -s "$expected_file" "$actual_file"
    if [ $? -ne 0 ]; then
        STRESS_OK=0
        STRESS_FAIL_REASON="Data corrupted on iteration $i (Channel $ch)"
        break
    fi
done

if [ "$STRESS_OK" -eq 1 ]; then
    pass_test "Stress Test: 100 consecutive channel creations and verifications succeeded without crashing."
else
    fail_test "Stress Test Failed" "$STRESS_FAIL_REASON"
fi

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------
print_header "Final summary"

echo "Total tests: $TOTAL"
echo "Passed:      $PASSED"
echo "Failed:      $FAILED"
echo "Warnings:    $WARNINGS"

if [ "$FAILED" -eq 0 ]; then
    echo
    echo "${GREEN}All tests passed. You are a Kernel Master!${RESET}"
    exit 0
else
    echo
    echo "${RED}Some tests failed.${RESET}"
    echo "Read the failure messages above. The important part is usually:"
    echo "  1. Which test failed"
    echo "  2. What the expected behavior was"
    echo "  3. What stdout/stderr or errno was actually received"
    exit 1
fi