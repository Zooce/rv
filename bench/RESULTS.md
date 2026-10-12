# Bench baseline

Snapshot from `mise run bench` (`zig build bench -Doptimize=ReleaseSafe`).

- Date: 2026-10-11
- Host: AMD Ryzen AI 5 340, 12 CPUs, Linux 7.2.5-3-omarchy
- git 2.55.0, Zig 0.17.0

Re-run with `mise run bench -- --compare` against `baseline.json`. This snapshot is the mean of three warmed passes. Spawn counts should not change. After an intended shift, `--write-baseline bench/baseline.json` and replace this table.

```
mean of 3 runs
fixture     files  hunks   rows  step                    ms     alloc  spawns
small           5      6     35  git_stdout               3.33     3 KiB       5
small           5      6     35  parse                    0.01     4 KiB       0
small           5      6     35  attach_spans             0.01     6 KiB       0
small           5      6     35  flatten                  0.00     5 KiB       0
small           5      6     35  pair_side_by_side        0.00     2 KiB       0
small           5      6     35  line_number_width        0.00       0 B       0
small           5      6     35  hunk_max_line_width      0.00       0 B       0
small           5      6     35  paint                    0.03       0 B       0
small           5      6     35  present                  0.03       0 B       0
small           5      6     35  paint_noop               0.02       0 B       0
small           5      6     35  present_noop             0.01       0 B       0
small           5      6     35  mutate                   0.83     420 B       1
small           5      6     35  reload_paths             1.61     9 KiB       2
small           5      6     35  approve_save             0.03     572 B       0
small           5      6     35  place                    0.01     1 KiB       0
small           5      6     35  flatten_placed           0.00     5 KiB       0
small           5      6     35  pair_rebuild             0.00     2 KiB       0
small           5      6     35  paint_approve            0.03      28 B       0
untracked     200    200    601  git_stdout               3.54    70 KiB       5
untracked     200    200    601  parse                    0.05   131 KiB       0
untracked     200    200    601  attach_spans             0.00       0 B       0
untracked     200    200    601  flatten                  0.03    71 KiB       0
untracked     200    200    601  pair_side_by_side        0.02    34 KiB       0
untracked     200    200    601  line_number_width        0.00       0 B       0
untracked     200    200    601  hunk_max_line_width      0.02       0 B       0
untracked     200    200    601  paint                    0.02       0 B       0
untracked     200    200    601  present                  0.02       0 B       0
untracked     200    200    601  paint_noop               0.02       0 B       0
untracked     200    200    601  present_noop             0.01       0 B       0
untracked     200    200    601  mutate                   0.76     420 B       1
untracked     200    200    601  reload_paths             1.55    78 KiB       2
untracked     200    200    601  approve_save             0.02     569 B       0
untracked     200    200    601  place                    0.01     1 KiB       0
untracked     200    200    601  flatten_placed           0.08    83 KiB       0
untracked     200    200    601  pair_rebuild             0.02    35 KiB       0
untracked     200    200    601  paint_approve            0.02     598 B       0
large           1    167   1502  git_stdout               4.26    79 KiB       5
large           1    167   1502  parse                    0.08   227 KiB       0
large           1    167   1502  attach_spans             0.36   463 KiB       0
large           1    167   1502  flatten                  0.04   152 KiB       0
large           1    167   1502  pair_side_by_side        0.03    69 KiB       0
large           1    167   1502  line_number_width        0.00       0 B       0
large           1    167   1502  hunk_max_line_width      0.33       0 B       0
large           1    167   1502  paint                    0.07       0 B       0
large           1    167   1502  present                  0.03       0 B       0
large           1    167   1502  paint_noop               0.06       0 B       0
large           1    167   1502  present_noop             0.01       0 B       0
large           1    167   1502  mutate                   1.15     659 B       1
large           1    167   1502  reload_paths             2.77   993 KiB       2
large           1    167   1502  approve_save             0.02     568 B       0
large           1    167   1502  place                    0.07     4 KiB       0
large           1    167   1502  flatten_placed           0.06   159 KiB       0
large           1    167   1502  pair_rebuild             0.03    69 KiB       0
large           1    167   1502  paint_approve            0.06     1 KiB       0
large           1    167   1502  approve_rest           747.08 213857 KiB     498
large_file      1    167   1502  git_stdout               4.21    79 KiB       5
large_file      1    167   1502  parse                    0.08   227 KiB       0
large_file      1    167   1502  attach_spans             0.42   463 KiB       0
large_file      1    167   1502  flatten                  0.04   152 KiB       0
large_file      1    167   1502  pair_side_by_side        0.03    69 KiB       0
large_file      1    167   1502  line_number_width        0.00       0 B       0
large_file      1    167   1502  hunk_max_line_width      0.33       0 B       0
large_file      1    167   1502  paint                    0.06       0 B       0
large_file      1    167   1502  present                  0.03       0 B       0
large_file      1    167   1502  paint_noop               0.06       0 B       0
large_file      1    167   1502  present_noop             0.01       0 B       0
large_file      1    167   1502  approve_file             4.22  1241 KiB       3
```

## Reading

- Local load is git-spawn bound for tracked diffs. 200 untracked files → 5 spawns (`rev-parse` work-tree, `ls-files`, `HEAD` verify, unstaged diff, staged diff). New-file diffs are in-process. `untracked` `git_stdout` is ~9 ms (was ~140 ms / 205 spawns).
- One `a` is three git spawns: `mutate` (`git apply --cached` or `git add`) and `reload_paths` (unstaged + staged diffs of that path). Work-tree check, `HEAD` verify, and untracked listing are skipped. Matching (`place`), omit, and paint stay under 1 ms on these fixtures.
- 166 further `a`s on the 167-hunk file (`approve_rest`) is ~0.75 s and 498 spawns. Each key still pays git. Matching is a hash lookup.
- `A` on that file (`approve_file`) is one `git add` plus reload: ~4 ms, 3 spawns.
- First `present` writes every cell (`dirty_all`). `present_noop` is the unchanged-state cell diff (goal 32).
