# Inside RawPOSIX's handlers: where a real syscall's extra cost goes (lind-perf on lmbench)

## Summary
lmbench showed that real syscalls cost Lind much more than a null syscall (read +144 ns, `stat`
+455 ns, `select` +1 µs over native; `wasm/2026-11-19-lmbench`). Here lmbench's own programs run
under the lind-perf build with `--perf-scope=all`, timing every syscall's layers and the steps
inside RawPOSIX's read, write, `stat`, `select` and `clock_gettime` handlers. Median of 5 runs,
pinned to one core, seccomp off; net ns per call.

Where the host-side time goes (per-syscall table: syscall entry → 3i → RawPOSIX):

| Syscall | Syscall entry (host side) | 3i handler lookup | RawPOSIX handler + kernel | Native (lmbench) |
|---|---|---|---|---|
| `read` 1 byte (`/dev/zero`) | 182.9 | 31.9 | 155.7 | 88 |
| `write` 1 byte (`/dev/null`) | 166.2 | 30.8 | 137.6 | 73 |
| `stat` | ~1,100 | 30.8 | ~1,000 | 664 |
| `clock_gettime` | 120.5 | 30.4 | 84.7 | ~20 (vDSO) |

Inside the handlers (RawPOSIX timers):

| Handler | Whole | Steps |
|---|---|---|
| `read` | 152.3 | fd lookup in fdtables **50.2** · kernel `read` 105.1 |
| `write` | 134.9 | fd lookup 49.1 · kernel `write` 86.6 |
| `stat` | ~1,000 | path conversion **164.1** · kernel `stat` **829.5** · copy-out 1.2 |
| `select`, 10 fds, zero timeout | ~1,100 | preparing the fd sets **688.1** · kernel loop 261.1 · results 107.4 |
| `clock_gettime` | 83.4 | kernel call 82.7 |

In every handler the steps add up to the whole within noise (the derived remainders are −2 to
+25 ns).

Takeaways:
- lind-common and 3i add little (~30 ns handler lookup plus a few ns); the extra cost of real
  syscalls is inside RawPOSIX's handlers.
- Every fd-based call pays ~50 ns to look up the real fd in fdtables.
- `stat`: path conversion costs ~164 ns, and the kernel `stat` itself takes ~830 ns under Lind
  against 664 ns for the whole native call (the converted path is not longer; the cause is not
  yet known).
- `select`: `fdtables::prepare_bitmasks_for_select` takes ~690 ns for 10 fds, four times the whole
  native `select`. It copies the cage's whole fd table row (1,024 entries, ~32 KB) for each fd set
  (`let myfdrow = *binding.value();` in `get_bitmask_for_select`).
- `clock_gettime` is a real kernel call in Lind (RawPOSIX uses `syscall(SYS_clock_gettime)`),
  ~83 ns, where natively glibc answers it in user space (vDSO) in ~20 ns.

## Benchmarks
| Run | lmbench program | RawPOSIX timers switched on |
|---|---|---|
| read | `lat_syscall -W 1 -N 5 read` | `rawposix::read::*`, `rawposix::clock_gettime::*` |
| write | `lat_syscall -W 1 -N 5 write` | `rawposix::write::*` |
| stat | `lat_syscall -W 1 -N 5 stat /tmp/lindperf-apps/sample.bin` | `rawposix::stat::*` |
| select | `lat_select -n 10 -W 1 -N 5 file` | `rawposix::select::*` (zero-timeout calls only) |

Every run also switches on the layer timers `lind_common::syscall_entry`,
`threei::make_syscall`, `…::handler_lookup` and `…::rawposix_dispatch`, which produce the
per-syscall table.

## Method
- `lind-boot-perf --perf --perf-scope=all`: time every syscall, not only benchmark syscalls; each
  selected timer is measured in its own run of the program (one process per timer), and the
  timer's own cost (~11 ns) is subtracted.
- `--perf-filter` selects the layer timers plus one handler's timers.
- Each run is repeated 5 times, pinned to CPU 2; `summarize_microbench.py` takes the median, min
  and max of every timer, derived line and per-syscall row (values converted to ns first).
- The `select` handler timers record only zero-timeout calls (lmbench's measurement loop), so
  lmbench's own sleeping `select` calls don't distort them. The per-syscall `select (23)` rows,
  however, include those sleeps: use the handler timers for `select`.
- The per-syscall tables also show lmbench's own calls (`clock_gettime`, `clone`, `exit_group`,
  `open`, …); rows for a syscall other than the run's own come from lmbench's setup and are not
  measurements of that syscall.

## Source
- lind-wasm: branch `lind-perf`, commit `0cb8221ec6bfdf62e66abf44c9528bc980076cd8` (the RawPOSIX
  handler timers are in `src/rawposix/src/{fs_calls.rs,net_calls.rs,perf.rs}`; see
  `src/lind-perf/README.md`).
- lmbench: lind-wasm-apps, dynamically linked (as in `wasm/2026-11-19-lmbench`).

## Environment
- CPU: 12th Gen Intel Core i9-12900K, pinned to CPU 2 (a P-core); `intel_pstate`, `powersave`
  (`balance_performance`), turbo on.
- Docker container on a Linux server, `--security-opt seccomp=unconfined`; lindfs `/dev/null` and
  `/dev/zero` are real devices.
- Full details: `data/e4-rawposix-handlers-20261119-063255/env.txt`.

## How to reproduce
In the lind-wasm checkout (`make lind-boot-perf` done, lmbench installed in lindfs, the test file
`/tmp/lindperf-apps/sample.bin` present in lindfs):
```bash
OUT=~/lind-perf-results/e4-rawposix-handlers-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
{ echo "# e4-rawposix-handlers"; date -Is; scripts/test/perf_env.sh 2; } > "$OUT/env.txt"
LAYERS=lind_common::syscall_entry,threei::make_syscall,threei::make_syscall::handler_lookup,threei::make_syscall::rawposix_dispatch
run() {
  local name=$1 filter=$2; shift 2
  for i in 1 2 3 4 5; do
    { echo "=================================================="; echo " $name"; echo "=================================================="
      timeout -k 10 300 sudo -E taskset -c 2 build/lind-boot-perf --preload env=/lib/libc.cwasm --preload env=/lib/libm.cwasm \
        --perf --perf-scope=all --perf-filter=$LAYERS,$filter "$@"; } > "$OUT/$name-$i.txt" 2>&1
  done
}
run read   rawposix::read,rawposix::clock_gettime  bin/lat_syscall -W 1 -N 5 read
run write  rawposix::write                         bin/lat_syscall -W 1 -N 5 write
run stat   rawposix::stat                          bin/lat_syscall -W 1 -N 5 stat /tmp/lindperf-apps/sample.bin
run select rawposix::select                        bin/lat_select -n 10 -W 1 -N 5 file
python3 scripts/test/summarize_microbench.py --csv "$OUT/summary.csv" "$OUT"/*-[1-5].txt > "$OUT/summary.txt"
```

## Files
- `data/e4-rawposix-handlers-20261119-063255/env.txt`: setup.
- `data/.../read-1.txt` … `select-5.txt`: the full lind-perf report of each run (layer timers,
  RawPOSIX timers, per-syscall table, derived lines).
- `data/.../summary.txt`, `summary.csv`: median, min and max across the 5 runs of each (CSV in ns).
