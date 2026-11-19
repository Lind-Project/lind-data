# Lind syscall path: per-layer costs, grates and fork (lind-perf)

## Summary
Where the time of one syscall goes in Lind, layer by layer, measured with lind-perf (per-layer
timers compiled into a perf build of lind-boot), plus the cost of a grate in the path and of
`fork()`. A native-Linux comparison comes from benchrunner on the normal (non-perf) build.

Key results (net ns per call, median of 5 runs, pinned to one core, seccomp off):

| Benchmark | What it measures | Time |
|---|---|---|
| null syscall (2003) | leaving and re-entering Wasm only | 25.9 ns |
| fdtables (2002) | full Lind path, answered by fdtables, no kernel call | 58.3 ns |
| libc (2001) | full Lind path plus a kernel `geteuid()` | 128.4 ns |
| no-op grate + 2001 / 2002 | reaching a handler in a grate and back (RawPOSIX and the kernel never run) | 224.8 / 224.2 ns |
| forwarding grate + 2001 | cage -> grate -> RawPOSIX -> kernel | 524.1 ns (+396 over 2001) |
| forwarding grate + 2002 | cage -> grate -> RawPOSIX -> fdtables | 418.2 ns (+360 over 2002) |
| fork + waitpid (dynamically linked program) | 200 forks of a child that exits at once | 9.0 ms |

Where a direct syscall's time goes (2001): leaving and re-entering Wasm ~30 ns, 3i's handler
lookup ~31 ns, the RawPOSIX handler with its kernel call ~60 ns, glue a few ns. The dead-cage
check costs ~0.2-0.8 ns since lind-wasm #1427.

Native Linux vs Lind (benchrunner, normal build, median of 5, same core):

| Call | Native | Lind |
|---|---|---|
| `close(-1)` | 62 ns | 59 ns (answered by fdtables, no kernel call) |
| `geteuid()` | 60 ns | 131 ns (+71 ns: Wasm transition + handler lookup) |

Inside a fork + wait (9.0 ms): the child's Asyncify rewind into `fork()` and exit 3.1 ms, the
parent waiting for the child to be built 4.2 ms (of which the child's setup 2.6 ms: copying
memory 1.0 ms, relinking the dynamic libraries ~1.4 ms), the parent's rewind 0.75 ms, the child's
exit cleanup ~0.76 ms. A statically linked program forks about 40x faster (measured separately:
~0.22 ms), so the linking mode matters most for fork.

## Source
- Code: [lind-wasm](https://github.com/Lind-Project/lind-wasm), branch `lind-perf`, commit
  `0cb8221ec6bfdf62e66abf44c9528bc980076cd8` (lind-wasm `main` including #1427, plus the lind-perf
  commits). `env.txt` counts one uncommitted change in the checkout at run time: the untracked
  `tests/benchmarks/grates/` folder, benchrunner's downloaded copy of lind-wasm-example-grates. No
  tracked file was modified, so the measured code is exactly this commit.
- lind-perf: `src/lind-perf/` (timers, report) with timers in lind-common, 3i, RawPOSIX,
  lind-boot, lind-3i, lind-multi-process and the cage crate; `src/lind-perf/README.md` explains
  each counter.
- Benchmarks: `tests/benchmarks/lind-perf/` (`libc_syscall.c`, `fdtables_syscall.c`,
  `null_syscall.c`, `grate_syscall.c` (no-op grate), `grate_forward.c` (forwarding grate),
  `fork_wait.c`), run by `scripts/test/run_microbench.sh` and repeated by
  `scripts/test/collect_microbench.sh`.
- Native comparison: `scripts/test/benchrunner.py` with `tests/benchmarks/sys_close.c` and
  `sys_geteuid.c`.

## Environment
- CPU: 12th Gen Intel Core i9-12900K (hybrid P/E cores), 24 logical CPUs, SMT on.
- Pinned to CPU 2 (a P-core, up to 5.1 GHz; SMT sibling CPU 3). `intel_pstate` driver, `powersave`
  governor, energy/performance preference `balance_performance`, turbo on, clock source `tsc`.
- Docker container on a Linux server, started with `--security-opt seccomp=unconfined` (Docker's
  seccomp filter off; with it on, every syscall that reaches the kernel costs ~13-15 ns more).
- Kernel version, mitigations and container limits: `data/e1-syscall-microbench-20261119-040820/env.txt`.

## How to reproduce
In a lind-wasm checkout of the commit above, inside the container:
```bash
make build                      # in a fresh container
make lind-boot lind-boot-perf   # normal binary + perf binary (feature lind_perf)
ls -l lindfs/dev/null lindfs/dev/zero   # must be character devices (1,3 and 1,5)
scripts/test/collect_microbench.sh -n 5 -c 2 -l e1-syscall-microbench -b 5
```
This runs `run_microbench.sh` 5 times (8 benchmarks; each lind-perf timer is measured in its own
process), then benchrunner (`sys_close sys_geteuid`) 5 times, pinned to the same CPU, and writes
the folder in `data/`. To summarize the raw runs again:
```bash
python3 scripts/test/summarize_microbench.py data/e1-syscall-microbench-20261119-040820/run-*.txt
```

## Files
- `data/e1-syscall-microbench-20261119-040820/env.txt`: machine, kernel, container and seccomp
  settings, lind-wasm commit, load at start and end.
- `data/.../run-1.txt` ... `run-5.txt`: full output of each `run_microbench.sh` repetition (every
  counter, per-syscall tables for the forwarding grate, derived lines).
- `data/.../summary.txt`, `summary.csv`: median, min and max of every counter, derived line and
  per-syscall row across the 5 runs.
- `data/.../benchrunner-pinned.txt`: 5 benchrunner runs, native Linux vs Lind.

Notes: `net/call` subtracts the timer's own cost (~11 ns). Derived lines (outer timer minus the
timers inside it) combine several separate runs, so values within ~10 ns of zero mean zero.

