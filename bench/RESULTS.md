# Bench baseline

Snapshot from `mise run bench` (`zig build bench -Doptimize=ReleaseSafe`).

- Date: 2026-10-07
- Host: AMD Ryzen AI 5 340, 12 CPUs, Linux 7.2.5-3-omarchy
- git 2.55.0, Zig 0.17.0

Re-run with `mise run bench -- --compare` against `baseline.json`. Time moves from run to run; spawn counts should not. After an intended shift, `--write-baseline bench/baseline.json` and replace this table.

```
fixture     files  hunks   rows  step                    ms     alloc  spawns
small           5      6     35  git_stdout               3.49     4 KiB       6
small           5      6     35  parse                    0.01     4 KiB       0
small           5      6     35  attach_spans             0.01     6 KiB       0
small           5      6     35  flatten                  0.00     5 KiB       0
small           5      6     35  pair_side_by_side        0.00     2 KiB       0
small           5      6     35  line_number_width        0.00       0 B       0
small           5      6     35  hunk_max_line_width      0.00       0 B       0
small           5      6     35  paint                    0.04       0 B       0
small           5      6     35  present                  0.03       0 B       0
small           5      6     35  paint_noop               0.03       0 B       0
small           5      6     35  present_noop             0.02       0 B       0
small           5      6     35  mutate                   1.49     683 B       2
small           5      6     35  reload_paths             2.97     9 KiB       4
small           5      6     35  approve_save             0.03     572 B       0
small           5      6     35  place                    0.01     307 B       0
small           5      6     35  flatten_placed           0.01     5 KiB       0
small           5      6     35  pair_rebuild             0.00     1 KiB       0
small           5      6     35  paint_approve            0.04      28 B       0
untracked     200    200    601  git_stdout             286.80   177 KiB     205
untracked     200    200    601  parse                    0.09   131 KiB       0
untracked     200    200    601  attach_spans             0.00       0 B       0
untracked     200    200    601  flatten                  0.05    71 KiB       0
untracked     200    200    601  pair_side_by_side        0.03    34 KiB       0
untracked     200    200    601  line_number_width        0.00       0 B       0
untracked     200    200    601  hunk_max_line_width      0.02       0 B       0
untracked     200    200    601  paint                    0.02       0 B       0
untracked     200    200    601  present                  0.02       0 B       0
untracked     200    200    601  paint_noop               0.02       0 B       0
untracked     200    200    601  present_noop             0.01       0 B       0
untracked     200    200    601  mutate                   2.21     683 B       2
untracked     200    200    601  reload_paths             5.94    78 KiB       4
untracked     200    200    601  approve_save             0.05     569 B       0
untracked     200    200    601  place                    0.02     393 B       0
untracked     200    200    601  flatten_placed           0.12    83 KiB       0
untracked     200    200    601  pair_rebuild             0.03    35 KiB       0
untracked     200    200    601  paint_approve            0.04     598 B       0
large           1    167   1502  git_stdout               8.07    79 KiB       5
large           1    167   1502  parse                    0.19   228 KiB       0
large           1    167   1502  attach_spans             0.63   463 KiB       0
large           1    167   1502  flatten                  0.09   152 KiB       0
large           1    167   1502  pair_side_by_side        0.06    69 KiB       0
large           1    167   1502  line_number_width        0.00       0 B       0
large           1    167   1502  hunk_max_line_width      0.56       0 B       0
large           1    167   1502  paint                    0.11       0 B       0
large           1    167   1502  present                  0.05       0 B       0
large           1    167   1502  paint_noop               0.09       0 B       0
large           1    167   1502  present_noop             0.02       0 B       0
large           1    167   1502  mutate                   2.94     922 B       2
large           1    167   1502  reload_paths             5.40   994 KiB       4
large           1    167   1502  approve_save             0.02     568 B       0
large           1    167   1502  place                    0.09     1 KiB       0
large           1    167   1502  flatten_placed           0.06   156 KiB       0
large           1    167   1502  pair_rebuild             0.03    69 KiB       0
large           1    167   1502  paint_approve            0.08     1 KiB       0
large           1    167   1502  approve_rest          1836.64 194215 KiB     996
large_file      1    167   1502  git_stdout               4.27    79 KiB       5
large_file      1    167   1502  parse                    0.12   228 KiB       0
large_file      1    167   1502  attach_spans             0.52   463 KiB       0
large_file      1    167   1502  flatten                  0.06   152 KiB       0
large_file      1    167   1502  pair_side_by_side        0.04    69 KiB       0
large_file      1    167   1502  line_number_width        0.00       0 B       0
large_file      1    167   1502  hunk_max_line_width      0.46       0 B       0
large_file      1    167   1502  paint                    0.09       0 B       0
large_file      1    167   1502  present                  0.04       0 B       0
large_file      1    167   1502  paint_noop               0.08       0 B       0
large_file      1    167   1502  present_noop             0.02       0 B       0
large_file      1    167   1502  approve_file            12.54  1135 KiB       6
```

## Reading

- Local load is git-spawn bound. 200 untracked files → 205 spawns. `git_stdout` wall time varies a lot across runs (140–430 ms here); the spawn count does not.
- One `a` is six git spawns: `mutate` (work-tree check + `git apply --cached`) and `reload_paths` (four). Matching (`place`), omit, and paint stay under 0.1 ms on these fixtures.
- 166 further `a`s on the 167-hunk file (`approve_rest`) is 1.8 s and 996 spawns. That is the slow approve case: each key pays git again. Fingerprint matching is not the cost.
- `A` on that file (`approve_file`) is one `git add` plus reload: ~13 ms, 6 spawns.
- First `present` writes every cell (`dirty_all`). `present_noop` is the unchanged-state cell diff (goal 32).
