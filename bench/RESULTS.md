# Bench baseline

Snapshot from `mise run bench` (`zig build bench -Doptimize=ReleaseSafe`).

- Date: 2026-10-08
- Host: AMD Ryzen AI 5 340, 12 CPUs, Linux 7.2.5-3-omarchy
- git 2.55.0, Zig 0.17.0

Re-run with `mise run bench -- --compare` against `baseline.json`. Time moves from run to run; spawn counts should not. After an intended shift, `--write-baseline bench/baseline.json` and replace this table.

```
fixture     files  hunks   rows  step                    ms     alloc  spawns
small           5      6     35  git_stdout               4.08     4 KiB       6
small           5      6     35  parse                    0.01     4 KiB       0
small           5      6     35  attach_spans             0.01     6 KiB       0
small           5      6     35  flatten                  0.00     5 KiB       0
small           5      6     35  pair_side_by_side        0.00     2 KiB       0
small           5      6     35  line_number_width        0.00       0 B       0
small           5      6     35  hunk_max_line_width      0.00       0 B       0
small           5      6     35  paint                    0.03       0 B       0
small           5      6     35  present                  0.02       0 B       0
small           5      6     35  paint_noop               0.02       0 B       0
small           5      6     35  present_noop             0.01       0 B       0
small           5      6     35  mutate                   0.86     420 B       1
small           5      6     35  reload_paths             1.45     9 KiB       2
small           5      6     35  approve_save             0.02     572 B       0
small           5      6     35  place                    0.01     307 B       0
small           5      6     35  flatten_placed           0.00     5 KiB       0
small           5      6     35  pair_rebuild             0.00     1 KiB       0
small           5      6     35  paint_approve            0.02      28 B       0
untracked     200    200    601  git_stdout             137.93   177 KiB     205
untracked     200    200    601  parse                    0.07   131 KiB       0
untracked     200    200    601  attach_spans             0.00       0 B       0
untracked     200    200    601  flatten                  0.03    71 KiB       0
untracked     200    200    601  pair_side_by_side        0.03    34 KiB       0
untracked     200    200    601  line_number_width        0.00       0 B       0
untracked     200    200    601  hunk_max_line_width      0.02       0 B       0
untracked     200    200    601  paint                    0.02       0 B       0
untracked     200    200    601  present                  0.02       0 B       0
untracked     200    200    601  paint_noop               0.02       0 B       0
untracked     200    200    601  present_noop             0.01       0 B       0
untracked     200    200    601  mutate                   0.82     420 B       1
untracked     200    200    601  reload_paths             1.88    78 KiB       2
untracked     200    200    601  approve_save             0.05     569 B       0
untracked     200    200    601  place                    0.03     393 B       0
untracked     200    200    601  flatten_placed           0.13    83 KiB       0
untracked     200    200    601  pair_rebuild             0.03    35 KiB       0
untracked     200    200    601  paint_approve            0.04     598 B       0
large           1    167   1502  git_stdout               4.17    79 KiB       5
large           1    167   1502  parse                    0.08   227 KiB       0
large           1    167   1502  attach_spans             0.39   463 KiB       0
large           1    167   1502  flatten                  0.04   152 KiB       0
large           1    167   1502  pair_side_by_side        0.03    69 KiB       0
large           1    167   1502  line_number_width        0.00       0 B       0
large           1    167   1502  hunk_max_line_width      0.32       0 B       0
large           1    167   1502  paint                    0.07       0 B       0
large           1    167   1502  present                  0.03       0 B       0
large           1    167   1502  paint_noop               0.06       0 B       0
large           1    167   1502  present_noop             0.01       0 B       0
large           1    167   1502  mutate                   1.30     659 B       1
large           1    167   1502  reload_paths             2.80   993 KiB       2
large           1    167   1502  approve_save             0.02     568 B       0
large           1    167   1502  place                    0.08     1 KiB       0
large           1    167   1502  flatten_placed           0.05   156 KiB       0
large           1    167   1502  pair_rebuild             0.03    69 KiB       0
large           1    167   1502  paint_approve            0.06     1 KiB       0
large           1    167   1502  approve_rest          1413.07 194043 KiB     498
large_file      1    167   1502  git_stdout               4.30    79 KiB       5
large_file      1    167   1502  parse                    0.08   227 KiB       0
large_file      1    167   1502  attach_spans             0.37   463 KiB       0
large_file      1    167   1502  flatten                  0.04   152 KiB       0
large_file      1    167   1502  pair_side_by_side        0.03    69 KiB       0
large_file      1    167   1502  line_number_width        0.00       0 B       0
large_file      1    167   1502  hunk_max_line_width      0.33       0 B       0
large_file      1    167   1502  paint                    0.06       0 B       0
large_file      1    167   1502  present                  0.03       0 B       0
large_file      1    167   1502  paint_noop               0.05       0 B       0
large_file      1    167   1502  present_noop             0.01       0 B       0
large_file      1    167   1502  approve_file             9.97  1134 KiB       3
```

## Reading

- Local load is git-spawn bound. 200 untracked files → 205 spawns. `git_stdout` wall time varies a lot across runs; the spawn count does not.
- One `a` is three git spawns: `mutate` (`git apply --cached` or `git add`) and `reload_paths` (unstaged + staged diffs of that path). Work-tree check, `HEAD` verify, and untracked listing are skipped. Matching (`place`), omit, and paint stay under 0.1 ms on these fixtures.
- 166 further `a`s on the 167-hunk file (`approve_rest`) is ~1.4 s and 498 spawns. Each key still pays git; fingerprint matching is not the cost.
- `A` on that file (`approve_file`) is one `git add` plus reload: ~10 ms, 3 spawns.
- First `present` writes every cell (`dirty_all`). `present_noop` is the unchanged-state cell diff (goal 32).
