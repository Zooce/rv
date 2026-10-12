# Bench baseline

Snapshot from `mise run bench` (`zig build bench -Doptimize=ReleaseSafe`).

- Date: 2026-10-11
- Host: AMD Ryzen AI 5 340, 12 CPUs, Linux 7.2.5-3-omarchy
- git 2.55.0, Zig 0.17.0

Re-run with `mise run bench -- --compare` against `baseline.json`. This snapshot is the mean of three warmed passes. Spawn counts should not change. After an intended shift, `--write-baseline bench/baseline.json` and replace this table.

```
mean of 3 runs
fixture     files  hunks   rows  step                    ms     alloc  spawns
small           5      6     35  git_stdout               7.94     3 KiB       5
small           5      6     35  parse                    0.03     4 KiB       0
small           5      6     35  attach_spans             0.02     6 KiB       0
small           5      6     35  flatten                  0.01     5 KiB       0
small           5      6     35  pair_side_by_side        0.00     2 KiB       0
small           5      6     35  line_number_width        0.00       0 B       0
small           5      6     35  hunk_max_line_width      0.00       0 B       0
small           5      6     35  paint                    0.06       0 B       0
small           5      6     35  present                  0.06       0 B       0
small           5      6     35  paint_noop               0.05       0 B       0
small           5      6     35  present_noop             0.03       0 B       0
small           5      6     35  mutate                   1.95     420 B       1
small           5      6     35  reload_paths             3.78     9 KiB       2
small           5      6     35  approve_save             0.05     572 B       0
small           5      6     35  place                    0.02     307 B       0
small           5      6     35  flatten_placed           0.01     5 KiB       0
small           5      6     35  pair_rebuild             0.00     1 KiB       0
small           5      6     35  paint_approve            0.07      28 B       0
untracked     200    200    601  git_stdout               8.60    70 KiB       5
untracked     200    200    601  parse                    0.14   131 KiB       0
untracked     200    200    601  attach_spans             0.00       0 B       0
untracked     200    200    601  flatten                  0.08    71 KiB       0
untracked     200    200    601  pair_side_by_side        0.05    34 KiB       0
untracked     200    200    601  line_number_width        0.00       0 B       0
untracked     200    200    601  hunk_max_line_width      0.05       0 B       0
untracked     200    200    601  paint                    0.06       0 B       0
untracked     200    200    601  present                  0.08       0 B       0
untracked     200    200    601  paint_noop               0.04       0 B       0
untracked     200    200    601  present_noop             0.03       0 B       0
untracked     200    200    601  mutate                   1.70     420 B       1
untracked     200    200    601  reload_paths             3.37    78 KiB       2
untracked     200    200    601  approve_save             0.06     569 B       0
untracked     200    200    601  place                    0.04     393 B       0
untracked     200    200    601  flatten_placed           0.24    83 KiB       0
untracked     200    200    601  pair_rebuild             0.06    35 KiB       0
untracked     200    200    601  paint_approve            0.07     598 B       0
large           1    167   1502  git_stdout               8.19    79 KiB       5
large           1    167   1502  parse                    0.13   227 KiB       0
large           1    167   1502  attach_spans             0.54   463 KiB       0
large           1    167   1502  flatten                  0.07   152 KiB       0
large           1    167   1502  pair_side_by_side        0.05    69 KiB       0
large           1    167   1502  line_number_width        0.00       0 B       0
large           1    167   1502  hunk_max_line_width      0.46       0 B       0
large           1    167   1502  paint                    0.09       0 B       0
large           1    167   1502  present                  0.04       0 B       0
large           1    167   1502  paint_noop               0.08       0 B       0
large           1    167   1502  present_noop             0.02       0 B       0
large           1    167   1502  mutate                   2.49     659 B       1
large           1    167   1502  reload_paths             5.45   993 KiB       2
large           1    167   1502  approve_save             0.04     568 B       0
large           1    167   1502  place                    0.11     1 KiB       0
large           1    167   1502  flatten_placed           0.08   156 KiB       0
large           1    167   1502  pair_rebuild             0.04    69 KiB       0
large           1    167   1502  paint_approve            0.09     1 KiB       0
large           1    167   1502  approve_rest          2405.02 194043 KiB     498
large_file      1    167   1502  git_stdout               7.56    79 KiB       5
large_file      1    167   1502  parse                    0.20   227 KiB       0
large_file      1    167   1502  attach_spans             0.76   463 KiB       0
large_file      1    167   1502  flatten                  0.08   152 KiB       0
large_file      1    167   1502  pair_side_by_side        0.06    69 KiB       0
large_file      1    167   1502  line_number_width        0.00       0 B       0
large_file      1    167   1502  hunk_max_line_width      0.54       0 B       0
large_file      1    167   1502  paint                    0.10       0 B       0
large_file      1    167   1502  present                  0.05       0 B       0
large_file      1    167   1502  paint_noop               0.09       0 B       0
large_file      1    167   1502  present_noop             0.02       0 B       0
large_file      1    167   1502  approve_file            16.03  1134 KiB       3
```

## Reading

- Local load is git-spawn bound for tracked diffs. 200 untracked files → 5 spawns (`rev-parse` work-tree, `ls-files`, `HEAD` verify, unstaged diff, staged diff). New-file diffs are in-process. `untracked` `git_stdout` is ~9 ms (was ~140 ms / 205 spawns).
- One `a` is three git spawns: `mutate` (`git apply --cached` or `git add`) and `reload_paths` (unstaged + staged diffs of that path). Work-tree check, `HEAD` verify, and untracked listing are skipped. Matching (`place`), omit, and paint stay under 1 ms on these fixtures.
- 166 further `a`s on the 167-hunk file (`approve_rest`) is ~2.4 s and 498 spawns. Each key still pays git; fingerprint matching is not the cost.
- `A` on that file (`approve_file`) is one `git add` plus reload: ~16 ms, 3 spawns.
- First `present` writes every cell (`dirty_all`). `present_noop` is the unchanged-state cell diff (goal 32).
