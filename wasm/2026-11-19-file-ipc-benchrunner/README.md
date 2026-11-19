# Lind file I/O, IPC, process and compute costs (benchrunner)

## Summary
lind-wasm's own benchmark suite (benchrunner) on the normal (non-perf) build: the same C programs
built natively and for Lind, plus file I/O behind the in-memory file system grate (`imfs-grate`).
5 runs, pinned to one core, seccomp off; values are medians of the 5 runs (`data/medians.csv`).

| Benchmark | Native | Lind | Lind − native | Lind + imfs grate |
|---|---|---|---|---|
| `getpid` / `getppid` (no kernel call in Lind) | 62 / 63 ns | 73 / 73 ns | +10 ns | |
| mixed id lookups | 62 ns | 103 ns | +41 ns | |
| id lookups from 4 threads | 64 ns | 129 ns | 2.0× | |
| `pread` 1 B / 1 KB / 4 KB / 10 KB | 188 / 199 / 217 / 317 ns | 382 / 392 / 413 / 519 ns | **+194–202 ns** | 645 / 649 / 674 / 726 ns |
| `pwrite` 1 B / 1 KB / 4 KB / 10 KB | 301 / 309 / 327 / 556 ns | 485 / 494 / 509 / 743 ns | **+182–187 ns** | 773 / 777 / 799 / 843 ns |
| pipe round trip, 1 B / 10 KB | 1,810 / 3,006 ns | 2,436 / 3,898 ns | 1.3× | |
| Unix socket round trip (stream / datagram, 1 B–10 KB) | 2,657–4,229 ns | 3,117–4,539 ns | 1.05–1.27× | |
| Fibonacci(1000), computation only | 587 ns | 1,823 ns | 3.1× | |
| fork + waitpid | 47.6 µs | **11.8 ms** | 248× | |

- File I/O costs Lind a roughly constant ~190–200 ns per call whatever the size: a per-call cost
  (fd translation, buffer address conversion), not a per-byte one.
- The imfs grate answers reads and writes from memory, adding ~260–290 ns per call up to 4 KB over
  Lind alone (less at 10 KB: +207 ns for reads, +100 ns for writes).
- IPC round trips are close to native: each is dominated by context switches.
- Computation is ~3× slower. benchrunner compiles the native programs without optimization
  (`-O0`) and Lind's with `-O2`, so this understates Lind's compute overhead; the benchmark also
  uses `volatile` variables, so every step is a memory access.
- fork is the outlier. `cage_stress` is dynamically linked (lind_compile's default); the lind-perf
  fork breakdown (`wasm/2026-11-19-syscall-microbench`) shows why dynamic programs fork slowly.

Outliers visible in the raw runs (the medians are unaffected): run 1's 4-thread lookup under Lind
(468 ns, others 128–129), run 5's native Fibonacci (860 ns, others 580–591), run 2's native 1-byte
`pwrite` (383 ns, others 301–302), and run 2's imfs-grate reads (~45 ns higher than the other runs).

## Benchmarks
Each is a small C program in `tests/benchmarks/` that repeats one operation in a loop, reads
`clock_gettime(CLOCK_MONOTONIC)` before and after, and prints the average time per operation.

| Program | What one operation is | Parameter | Repetitions |
|---|---|---|---|
| `fs_read.c` | `pread()` of PARAM bytes from offset 0 of a file it created | 1, 1024, 4096, 10240 bytes | 1,000,000 (10,000 above 4 KB) |
| `fs_write.c` | `pwrite()` of PARAM bytes at offset 0 | same | same |
| `ipc_pipe.c` | round trip: the parent writes PARAM bytes to a child through one pipe, the child writes them back through another | same | same |
| `ipc_uds.c` | the same round trip over an `AF_UNIX` `socketpair`, datagram and stream | same | same |
| `cage_stress.c` | `getpid()`; `getppid()`; a mix of `getpid`/`getppid`/`getuid`/`geteuid`; that mix from 4 threads at once; `fork()` + `waitpid()` of a child that exits | – (4 threads) | 1,000,000 lookups; 2,000 forks |
| `perf_fibonacci.c` | compute Fibonacci(1000) with a loop (no syscalls) | – | 10,000 |
| `imfs-grate.fs_read.grate` / `imfs-grate.fs_write.grate` | `fs_read` / `fs_write` run as the cage of `imfs-grate`, which keeps files in memory and answers the reads and writes itself | as above | as above |

## Method
1. Record the setup: `scripts/test/perf_env.sh 2 > env.txt` (CPU and frequency settings, kernel,
   mitigations, container and seccomp status, lind-wasm commit).
2. Run `scripts/test/benchrunner.py fs_ ipc_ cage_ perf_ imfs-grate.` five times, pinned to CPU 2
   with `taskset`. For each `.c` benchmark, benchrunner compiles it natively (`cc`, no
   optimization flag) and for Lind (`lind_compile`, `-O2`, dynamically linked), runs both, and
   prints both times and their ratio. For each `.grate` file it fetches the grate from
   lind-wasm-example-grates into `tests/benchmarks/grates/`, builds it (the Rust `imfs-grate`, with
   `cargo lind_compile --release`), and runs the cage behind it (the GRATE column).
3. Record which grate version was built: `grates-commit.txt`.
4. For every benchmark and parameter, take the median of the 5 runs for native, Lind and grate
   (`data/medians.csv`, computed from `benchrunner.txt`).

## Source
- Code: [lind-wasm](https://github.com/Lind-Project/lind-wasm), branch `lind-perf`, commit
  `0cb8221ec6bfdf62e66abf44c9528bc980076cd8` (lind-wasm `main` including #1427, plus the lind-perf
  commits; these benchmarks don't use lind-perf).
- Benchmarks: `tests/benchmarks/fs_read.c`, `fs_write.c`, `ipc_pipe.c`, `ipc_uds.c`,
  `cage_stress.c`, `perf_fibonacci.c`, and `imfs-grate.fs_read.grate` / `imfs-grate.fs_write.grate`,
  run by `scripts/test/benchrunner.py`.
- The grate: `imfs-grate` from
  [lind-wasm-example-grates](https://github.com/Lind-Project/lind-wasm-example-grates), fetched by
  benchrunner into `tests/benchmarks/grates/`; its commit is in `data/.../grates-commit.txt`.

## Environment
- CPU: 12th Gen Intel Core i9-12900K (hybrid P/E cores), 24 logical CPUs, SMT on.
- Pinned to CPU 2 (a P-core, up to 5.1 GHz; SMT sibling CPU 3). `intel_pstate`, `powersave`
  governor (`balance_performance`), turbo on, clock source `tsc`.
- Docker container on a Linux server, started with `--security-opt seccomp=unconfined`.
- Full details: `data/e2-file-ipc-benchrunner-20261119-051034/env.txt`.

## How to reproduce
In a lind-wasm checkout of the commit above, inside the container (`make build` and
`make lind-boot` done; lindfs `/dev/null` and `/dev/zero` real devices):
```bash
OUT=~/lind-perf-results/e2-file-ipc-benchrunner-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
{ echo "# e2-file-ipc-benchrunner"; date -Is; scripts/test/perf_env.sh 2; } > "$OUT/env.txt"
{ git rev-parse --abbrev-ref HEAD; git log --oneline -1
  for i in 1 2 3 4 5; do echo "== run $i"; taskset -c 2 scripts/test/benchrunner.py fs_ ipc_ cage_ perf_ imfs-grate.; done; } 2>&1 \
  | tee "$OUT/benchrunner.txt"
git -C tests/benchmarks/grates log -1 --format='%H %s' > "$OUT/grates-commit.txt"
```

## Files
- `data/e2-file-ipc-benchrunner-20261119-051034/env.txt`: machine, kernel, container and seccomp
  settings, lind-wasm commit.
- `data/.../benchrunner.txt`: the 5 full benchrunner runs (tables in ns; ratios to native in
  brackets).
- `data/.../grates-commit.txt`: the lind-wasm-example-grates commit `imfs-grate` was built from.
- `data/medians.csv`: per benchmark and parameter, the median, min and max of the 5 runs for
  native, Lind and Lind + grate, and the differences.
