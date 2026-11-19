# lmbench under Lind: native vs Lind vs Lind behind a grate

## Summary
Standard lmbench operating-system microbenchmarks, built from the same source natively and for
Lind, each run in three modes: **native** Linux, **Lind**, and **Lind behind a pass-through grate**
(`testing-grate`, which intercepts ~60 file, I/O, socket and identity syscalls and forwards each
one unchanged). Normal (non-perf) build; median of 5 runs, seccomp off.

Syscalls (µs per call):

| Workload | Native | Lind | Lind − native | Lind + grate | Grate − Lind |
|---|---|---|---|---|---|
| null syscall (`getppid`) | 0.063 | 0.073 | +0.011 | 0.427 | +0.354 |
| read 1 byte (`/dev/zero`) | 0.088 | 0.233 | +0.144 | 0.673 | +0.440 |
| write 1 byte (`/dev/null`) | 0.073 | 0.207 | +0.134 | 0.654 | +0.447 |
| `fstat` | 0.382 | 0.676 | +0.294 | 1.187 | +0.511 |
| `stat` | 0.664 | 1.119 | +0.455 | 1.609 | +0.491 |
| `open` + `close` | 1.237 | 2.014 | +0.777 | 3.035 | +1.021 (2 calls) |
| `select` on 10 files | 0.172 | 1.172 | +1.000 (6.8×) | 1.770 | +0.598 |
| install a signal handler | 0.097 | 0.114 | +0.016 | 0.113 | 0 (not intercepted) |

Processes, IPC, memory, computation (µs):

| Workload | Native | Lind | Lind + grate |
|---|---|---|---|
| function call (`lat_proc procedure`) | 0.0015 | 0.0034 (2.3×) | not run |
| fork + exit + wait | 48.9 | 9,726 (199×) | 9,606 |
| fork + exec + wait | 176 | 14,534 (83×) | 14,641 |
| pipe round trip | 1.81 | 2.44 (1.35×) | 4.49 |
| Unix socket round trip | 3.03 | 3.29 (1.09×) | 5.37 |
| `mmap` + `munmap` 1 MB of a file | 6.48 | 7.78 (1.20×) | 8.12 |
| context switch, 2 processes (2 cores) | 1.42 | 1.37 (0.96×) | 1.19 |
| page fault on a mapped file (2 cores) | 0.0994 | 0.0985 (0.99×) | 0.0987 |

Bandwidth (MB/s):

| Workload | Native | Lind | Lind + grate |
|---|---|---|---|
| file read, 64 MB | 10,550 | 7,177 (0.68×) | 6,644 |
| file read, 4 MB | 22,122 | 10,112 (0.46×) | 9,208 |
| pipe | 11,026 | 10,444 (0.95×) | 8,866 |
| Unix socket | 12,231 | 11,238 (0.92×) | 9,172 |

Takeaways:
- A null syscall costs Lind only ~11 ns, but real syscalls cost more, growing with what the call
  carries: an fd (read/write +134–144 ns), a path (`stat` +455 ns), an fd set (`select` +1 µs).
  A lind-perf breakdown (separate experiment) puts nearly all of it inside RawPOSIX's handlers.
- A grate in the path adds a steady ~0.35–0.5 µs per intercepted call, whatever the call; calls
  it doesn't intercept (signals, `mmap`, fork, exec) cost nothing extra.
- Process creation is the outlier: fork 199×, exec 83×. This lmbench is dynamically linked; a
  statically linked program forks about 40× faster under Lind.
- IPC, context switches and page faults are close to native. File read bandwidth is not
  (0.46–0.68×): a per-byte or per-page cost.

## Benchmarks
lmbench measures each workload itself and reports a latency or a bandwidth; `-W 1 -N 5` is its own
warm-up and repetition setting. The list is `scripts/test/appbench_workloads.txt` (copied into
each data folder as `workloads.txt`).

| Workload | lmbench command |
|---|---|
| `lat_syscall_null` / `_read` / `_write` | `lat_syscall -W 1 -N 5 null` / `read` / `write` |
| `lat_syscall_stat` / `_fstat` / `_open` | `lat_syscall -W 1 -N 5 stat` / `fstat` / `open /tmp/lindperf-apps/sample.bin` |
| `lat_select_file10` | `lat_select -n 10 -W 1 -N 5 file` |
| `lat_sig_install` | `lat_sig -W 1 -N 5 install` |
| `lat_pipe` / `lat_unix` | `lat_pipe -W 1 -N 5` / `lat_unix -W 1 -N 5` |
| `lat_mmap_1m` | `lat_mmap -W 1 -N 5 1m /tmp/lindperf-apps/sample.bin` |
| `lat_proc_procedure` / `_fork` / `_exec` | `lat_proc -W 1 -N 5 procedure`; `lat_proc -W 0 -N 3 fork` / `exec` |
| `bw_file_rd_64m` / `_4m` | `bw_file_rd -W 1 -N 5 64m io_only sample64.bin` / `4m io_only sample.bin` |
| `bw_pipe` / `bw_unix` | `bw_pipe -W 1 -N 5` / `bw_unix -W 1 -N 5` |
| `lat_ctx_2` (2 cores) | `lat_ctx -W 1 -N 5 -s 0 2` |
| `lat_pagefault` (2 cores) | `lat_pagefault -W 1 -N 5 /tmp/lindperf-apps/sample.bin` |

Not included: `lat_sig catch` (fails under Lind; `lat_sig` also fails lind-wasm-apps' own lmbench
smoke test) and TCP (needs a separately started server).

## Method
`scripts/test/collect_appbench.sh`:
1. Creates the test files identically on the host and in lindfs (`/tmp/lindperf-apps`: an 8 MB and
   a 64 MB file, copies of lmbench's `hello` for `lat_proc exec`), and records the setup in
   `env.txt`.
2. Runs each workload 5 times; each time in all three modes in turn (native, Lind, grate), so slow
   drift affects all modes equally. Every run is pinned with `taskset`, limited to 120 s
   (`timeout -k 10`).
3. Saves each run's output in `raw/` and a line per run in `results.tsv`.
4. Summarizes: for each workload and mode, the median, min and max of the 5 values lmbench
   reported (`summary.txt`, `summary.csv`); runs that failed are left out and counted.

Two runs: most workloads pinned to one core (CPU 2); `lat_ctx_2` and `lat_pagefault` on two cores
(CPUs 2–3), because under Lind they fail when pinned to a single core (the measurement uses
separate processes, which in Lind are threads of one process); natively they work either way.
Compare context-switch numbers only at the same core setting: natively it is 0.64 µs on one core.

## Source
- lind-wasm: branch `lind-perf`, commit `0cb8221ec6bfdf62e66abf44c9528bc980076cd8` (scripts:
  `scripts/test/collect_appbench.sh`, `summarize_appbench.py`, `appbench_workloads.txt`,
  `perf_env.sh`).
- Lind lmbench: [lind-wasm-apps](https://github.com/Lind-Project/lind-wasm-apps) `lmbench/`, built
  with `make lmbench && make install-lmbench` (the Makefile default, `LIND_DYLINK=1`: dynamically
  linked); commit in `data/apps-commit.txt`.
- Native lmbench: the same lmbench source, built with
  `make OS=native CC=gcc CFLAGS="-DNO_PORTMAPPER -O2 -g" CPPFLAGS="-I/usr/include/tirpc" LDLIBS="-ltirpc -lm" all`
  (dynamically linked against glibc).
- The grate: `testing-grate` from
  [lind-wasm-example-grates](https://github.com/Lind-Project/lind-wasm-example-grates)
  (`rust-grates/testing-grate`, `cargo lind_compile --release`); commit in
  `data/grates-commit.txt`. The syscalls it intercepts are listed in `env.txt`
  ("default grate syscalls").

## Environment
- CPU: 12th Gen Intel Core i9-12900K (hybrid P/E cores), 24 logical CPUs, SMT on; CPU 2 is a
  P-core (SMT sibling CPU 3). `intel_pstate`, `powersave` governor (`balance_performance`), turbo on.
- Docker container on a Linux server, `--security-opt seccomp=unconfined`.
- lindfs `/dev/null` and `/dev/zero` are real character devices (created with `mknod`); with an
  ordinary file as `/dev/null`, a 1-byte write measured +455 ns instead of +134.
- Full details: each data folder's `env.txt`.

## How to reproduce
In the lind-wasm checkout (`make lind-boot` done), with lmbench installed in lindfs, the native
lmbench in `~/lmbench-native`, and `lindfs/grates/testing-grate.cwasm`:
```bash
scripts/test/collect_appbench.sh -n 5 -c 2 -l e3-lmbench -t 120 \
  -f '^(lat_(syscall|select|sig_install|pipe|unix|mmap|proc)|bw_)'
scripts/test/collect_appbench.sh -n 5 -c 2,3 -l e3-lmbench-2cpu -t 120 \
  -f '^(lat_pagefault|lat_ctx_2)$'
```
To summarize a data folder again: `python3 scripts/test/summarize_appbench.py <folder>`.

## Files
- `data/e3-lmbench-apps-20261119-054951/`: the one-core run (18 workloads).
- `data/e3-lmbench-2cpu-apps-20261119-060403/`: the two-core run (`lat_ctx_2`, `lat_pagefault`).
- In each: `env.txt` (setup), `workloads.txt` (the workload list used), `results.tsv` (one line per
  run: workload, metric, mode, repetition, exit status, wall time, output file), `raw/` (each
  run's output), `summary.txt` / `summary.csv` (medians and differences).
- `data/apps-commit.txt`, `data/grates-commit.txt`: the lind-wasm-apps and
  lind-wasm-example-grates commits used.
