# linux-systems-programming

A collection of systems-programming projects covering file I/O, virtual memory, process control, kernel modules, concurrency, and network programming — implemented in C on Linux.

## Concepts & Tools

- **Concepts:** file I/O, virtual memory & page tables, process control, signals & zombie/orphan handling, pipes & redirection, kernel modules & character devices, `ioctl`, C11 thread synchronization & condition variables, TCP sockets.
- **Tools:** GCC, GNU Make, the Linux kbuild system (kernel modules).


## 1. File Copy Utility (`copy/`)

A command-line file-copy tool built directly on the `open`/`read`/`write`/`close` system calls (no `fopen`/`fread`), copying in fixed-size chunks and looping on partial writes until the whole buffer is flushed. Validates argument count, refuses to overwrite an existing destination file, and reports system-call failures with `perror`.

**Build:** `cd copy && gcc -O3 -Wall -std=c11 copy.c -o copy`
**Usage:** `./copy <source_file> <dest_file> <buffer_size_bytes>`

## 2. Multi-Level Page Table (`page_table/`)

A simulated 5-level trie-based page table for a 64-bit address space (57 bits used for translation, 4 KB pages → 12-bit offset, 9 bits per level across 5 levels). Implements:
- `page_table_update(pt, vpn, ppn)` — creates, remaps, or destroys a virtual-to-physical mapping (destroys when `ppn == NO_MAPPING`).
- `page_table_query(pt, vpn)` — walks the trie and returns the mapped physical page, or `NO_MAPPING`.

> **Note:** `pt.c` is written against `os.c`/`os.h` (course-provided helpers for `alloc_page_frame()` and `phys_to_virt()`), and `test.c` was not written by me.

**Build:** `cd page_table && gcc -O3 -Wall -std=c11 os.c pt.c`

## 3. Custom Shell (`shell/`)

A command-line interpreter built around `fork()`/`execvp()`/`waitpid()`, supporting:
- **Background execution** (trailing `&`)
- **I/O redirection** (`<` for input, `>` for output, via `dup2`)
- **Multi-stage piping** (`|`, chaining up to 10 commands)
- **Signal handling** — the shell ignores `SIGINT` so Ctrl+C doesn't kill it, while foreground children restore the default disposition; a `SIGCHLD` handler reaps background children to avoid zombies.
> **Note:** `tests.sh` was not written by me.

**Build:** `cd shell && gcc -O3 -Wall -std=c11 myshell.c -o myshell`

## 4. Message Slot Kernel Module (`message_slot/`)

A loadable kernel module implementing a custom IPC mechanism: a character device where each device file (minor number) hosts multiple independent message channels, addressed via `ioctl`. Each channel retains its last message until overwritten, so it can be read more than once.

Files: `message_slot.c`, `message_slot.h`, `message_sender.c`, `message_reader.c`, `Makefile` — all under `message_slot/`.

- `MSG_SLOT_CHANNEL` — sets the active channel for a file descriptor.
- `MSG_SLOT_SET_CEN` — toggles per-file-descriptor censorship, replacing every 4th byte of a written message with `#`.
- `message_sender` / `message_reader` are small userspace programs that open a slot, configure it via `ioctl`, and write/read a message.

> **Note:** `message_slot_tester.sh` was not written by me.

**Build:** `cd message_slot && make` (builds `message_slot.ko` via kbuild, plus the sender/reader binaries)
**Setup:**
```bash
sudo insmod message_slot.ko
sudo mknod /dev/slot0 c 235 0
sudo chmod 666 /dev/slot0
```
**Usage:**
```bash
./message_sender /dev/slot0 <channel_id> <0|1 censorship> "<message>"
./message_reader /dev/slot0 <channel_id>
```

## 5. Thread-Safe FIFO Queue (`mutex_queue/`)

A generic concurrent queue built on **C11 threads** (`threads.h`, not pthreads directly), supporting `initQueue`, `destroyQueue`, `enqueue`, and a blocking `dequeue`. Threads that arrive at an empty queue sleep on a condition variable and are woken strictly in the order they started waiting, guaranteeing FIFO fairness between producers and waiting consumers. `visited()` reports the number of items that have passed through the queue using an atomic counter, with no locking.

> **Note:** `tests.sh` was not written by me.

**Build:** `cd mutex_queue && gcc -O3 -D_POSIX_C_SOURCE=200809 -Wall -std=c11 -pthread -c queue.c`

## 6. PCC — Printable Character Counting Server (`pcc_server/`)

A single-threaded TCP server that accepts client connections, reads a length-prefixed byte stream, counts printable characters (`32 ≤ byte ≤ 126`), and returns the count over the same connection — then folds the result into a running total across all clients. On `SIGINT`, it finishes the client currently being served, prints per-character totals in ascending ASCII order, and exits. Per-connection errors (timeout, reset, broken pipe, unexpected close) are logged and handled without taking the server down.

The matching client (`pcc_client.c`) is provided by the course and intentionally isn't included here — this repo only contains the server implementation.

> **Note:** `pcc_client.c` was not written by me.

**Build:** `cd pcc_server && gcc -O3 -D_POSIX_C_SOURCE=200809 -Wall -std=c11 pcc_server.c`
**Usage:** `./a.out <port>`


