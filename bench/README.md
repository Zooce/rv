# Bench

Named-step wall timings for the local review path: git stdout, parse, intra-line spans, row list, side-by-side pairing, paint, present, and approve. Generated git fixtures, no controlling terminal.

```sh
mise run bench
mise run bench -- --json
mise run bench -- --fixture small
mise run bench -- --compare
mise run bench -- --write-baseline bench/baseline.json
```

`mise run bench` builds `rv-bench` with `-Doptimize=ReleaseSafe`. Compare runs from the same optimize mode. Debug numbers are not a baseline.

## How timings are collected

There is no profiling library in this binary. Each step is:

1. **Wall time** — `Io.Clock.awake` (monotonic, excludes suspend) around one public API.
2. **Alloc** — requested bytes through a counting allocator. Frees do not subtract. This is not peak RSS.
3. **Spawns** — how many `git` processes that step started (`LoadStats` on `git()`).

That is how `--compare` can line up the same step names across commits. A sampling profiler answers a different question (where the CPU is inside a step). For that, attach `samply` or `perf` to interactive `rv` below.

`spawns` is counted on steps that run git: `git_stdout`, `mutate`, `reload_paths`, `approve_rest`, `approve_file`. Intra-line spans are in-process; they do not spawn `git diff --word-diff`.

## Fixtures

Generated under `/tmp` and deleted after the run.

| Name | What it is |
|---|---|
| `small` | Ordinary review: unstaged, staged, mixed, one untracked file |
| `untracked` | 200 untracked files (in-process new-file diffs after `ls-files`) |
| `large` | One 2000-line file with an edit every 12 lines; one `a` then the rest of the hunks |
| `large_file` | Same file as `large`; `A` stages the whole file in one `git add` |

`--fixture` can be passed more than once. Default is all three.

Each fixture warms git and the page cache once, then times a second pass. `present` writes the cell-diff CSI stream to `/dev/null`. `present_noop` is the second paint+present with unchanged cells (goal 32).

## Approve

One `a` is split on every fixture: `mutate` (`git apply --cached` or `git add`), `reload_paths` (unstaged and staged diffs of that path), `approve_save`, `place` (fingerprint matching), `flatten_placed`, `pair_rebuild`, `paint_approve`.

On `large` only:

- `approve_rest` — the remaining unstaged hunks in that file, one `a` each, one wall time. The store grows; later hunks can regroup into the staged neighbor.

On `large_file`:

- `approve_file` — `A`: one `git add`, reload, fingerprint every hunk, omit, paint.

The TUI currently matches (`place`) more than once per `a` (reload compose, then prune, then omit). The bench times matching once.

## Compare

`bench/baseline.json` is the machine-readable snapshot. `RESULTS.md` is the same run as a table.

```sh
mise run bench -- --compare
mise run bench -- --write-baseline bench/baseline.json
```

`--compare` prints baseline vs this run for each step (ms and spawns). Time moves around from run to run; spawn counts should not. The process exits `1` when any compared step’s spawn count changed, `2` when the baseline file is missing or invalid.

After a load, paint, present, or approve change, re-run, read the compare table, and if the new numbers are the intended baseline:

```sh
mise run bench -- --write-baseline bench/baseline.json
```

Then replace the table in `RESULTS.md` with the new stdout table. Do not treat a single run as a CI gate.

## Interactive profiling

Build a ReleaseSafe `rv`, then attach a profiler to a real session on a copy of a large work tree (not this repo, and not `~/Documents/scratch/temp`).

```sh
zig build -Doptimize=ReleaseSafe
samply record ./zig-out/bin/rv
```

Or:

```sh
perf record -g -- ./zig-out/bin/rv
perf report
```

Run those from the repository you want to load. Untracked files are listed with one `ls-files` and turned into new-file diffs in-process. The `untracked` fixture is 200 of those files.
