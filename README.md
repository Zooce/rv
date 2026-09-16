# rv

**Local terminal diff review for humans. Precise comments for AI agents.**

Stay in the terminal. Point at the exact lines. Hand the note to Grok, Claude, or any other agent.

![Side-by-side review with the current line highlighted](docs/screenshots/review.png)

![Inline comment box under the cursor](docs/screenshots/comment.png)

![Help overlay (`?`)](docs/screenshots/help.png)

## Install

Linux and macOS. No Windows builds yet.

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/rv/master/install.sh | sh
```

Puts `rv` and the bundled skill under `~/.local`. If `~/.local/bin` is not on `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
rv install-skill
```

### From source

Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## Use

```sh
rv                 # local changes (staged, unstaged, untracked)
rv HEAD            # one commit
rv main...HEAD     # a range
```

Vim keys move a **current line** on the diff. `i` / `Enter` comments there. Press `?` for every key.

```sh
rv export          # comments for the agent
rv list
rv resolve <id>    # drop an addressed comment
```

`rv` does not apply fixes. It is the comment board; the agent does the work.

## License

MIT. See [LICENSE](LICENSE).
