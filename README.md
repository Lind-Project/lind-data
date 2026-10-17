# lind-data

This repository stores experiment data and figures for the [Lind](https://github.com/Lind-Project) framework.

It holds **results only**: raw data, processed data, and figures. The tests and benchmarks that produced them live in their own repositories. Each result directory has a `README.md` that links to the code used to produce it.

## Repository layout

Each top-level directory is a **runtime** (e.g. `wasm`, `mpk`, `lfi`) or a **grate**. Inside it, results are grouped into one subfolder per date (`YYYY-MM-DD`).

```
lind-data/
├── wasm/
│   ├── 2026-10-01/
│   │   ├── README.md      # what was run, where the code is, how to reproduce
│   │   ├── data/          # raw and processed results (csv, json, logs, ...)
│   │   └── figures/       # plots generated from data/
│   └── 2026-10-16/
├── mpk/
│   └── YYYY-MM-DD/
├── lfi/
│   └── YYYY-MM-DD/
└── <grate-name>/
    └── YYYY-MM-DD/
```

If there is more than one experiment on the same date, add a short suffix to the folder name, e.g. `2026-10-16-syscall-latency`.

## Adding results

1. Find the top-level directory for the runtime or grate you measured, or create it if it doesn't exist yet.
2. Create a date subfolder named `YYYY-MM-DD`.
3. Put the results in `data/` and the plots in `figures/`.
4. Write a `README.md` in the date folder, using the template below.

### Per-result README template

```markdown
# <Short title of the experiment>

## Summary
What was measured and the key takeaway.

## Source
- Test / benchmark: <link to repo, path, or script>
- Commit: <commit hash of the benchmark code and of the Lind components used>

## Environment
- Machine / CPU / memory:
- OS / kernel:
- Runtime / grate configuration:

## How to reproduce
Commands used to run the benchmark and to generate the figures.

## Files
- `data/<file>`: description
- `figures/<file>`: description
```
