# rv

**Local terminal diff review for humans.**

Open `rv` on your local changes. Approve the changes you like, and comment on the changes you have feedback on. Tell your agent to address your rv comments. Reload with `r` and continue until you are happy with the changes.

## Install

Linux and macOS. No Windows builds yet.

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/rv/master/install.sh | sh
```

Puts `rv` in `~/.local/bin`. A specific release (published tags such as `v2.2.0`; the next tag is `v2.3`):

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/rv/master/install.sh | RV_VERSION=v2.2.0 sh
```

If `~/.local/bin` is not on `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
npx skills add Zooce/rv -g
```

### From source

Zig 0.17.0.

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
npx skills add Zooce/rv -g
```

`rv --version` prints `major.minor` (zon `2.2.0` prints `rv 2.2`).

Load, paint, present, and approve timings: `mise run bench`. Compare a run to `bench/baseline.json` with `--compare`. How timings are taken, and how to attach `samply` or `perf`, is in [bench/README.md](bench/README.md).

## Screenshots

### Side-by-side diff

Changed words are colored on the line. Unchanged words on that line stay grey. A whole line that was added or deleted stays green or red.

![Side-by-side diff. Changed words are colored; whole added and deleted lines stay solid.](docs/screenshots/review.png)

### Writing a comment

`i` opens the comment box under the diff. The box grows as the comment wraps.

![Comment box open with a comment that wraps across several lines.](docs/screenshots/comment.png)

### Unified diff

`t` shows the same review as a unified diff.

![Unified diff of the same review.](docs/screenshots/unified.png)

### Comment list

`Space` then `c` lists open comments.

![Comment list over the diff.](docs/screenshots/comments.png)

### Approved list

`Space` then `a` lists approved hunks. Approving stages a hunk and hides it from the diff.

![Approved list. Those hunks are staged and hidden from the diff.](docs/screenshots/approved.png)

## Use

```sh
rv                 # local changes (staged, unstaged, untracked)
```

`j` and `k` move the current line. The scroll wheel moves the window and leaves that line selected. Shift+wheel, or a sideways trackpad scroll, pans the hunk under the pointer. `a` approves the hunk at that line and `A` approves the whole file. Approving stages the change and hides it from the diff. `i` or `Enter` comments on the current line. Press `?` for every key, and `q` to quit.

Tell your agent to address your rv comments. The skill from the install step reads those comments, edits the code, and resolves each comment it has handled. What you approved stays staged and stays out of the next diff.

`r` reloads the diff and the comments. Continue until you are happy with the changes.

```sh
rv HEAD            # one commit
rv main...HEAD     # a range
```

```sh
rv list            # open comments
rv export          # those comments as markdown
rv resolve <id>    # drop an addressed comment
rv approved        # hidden hunks and files
rv unapprove <n>
```

`rv` keeps your approvals and your comments. Your agent changes the code.

## Releases

Pushing a git tag `v<major>.<minor>` (zon `2.3.0` is tag `v2.3`) publishes a GitHub Release with Linux and macOS tarballs (x86_64 and aarch64) and SHA256 checksums. The Linux binaries are musl builds. The release name is the tag. The tag message is the release notes.

1. Bump `.version` in `build.zig.zon` to `major.minor.0` (for example `2.3.0`).
2. Commit that change.
3. Tag `v<major>.<minor>`: `git tag -a v2.3`
4. Push the tag: `git push origin v2.3`

The release action checks that the tag matches `build.zig.zon` and `rv --version`, then publishes the Release.

## License

MIT. See [LICENSE](LICENSE).
