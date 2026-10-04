# dotfiles

Version-controlled Claude Code and agent configs. Each file lives here and is symlinked into `$HOME`. One install script sets up the same Claude behavior on any machine.

## What is managed

| Repo path (`dotfiles/`)            | Symlinked to                         | What it is                                     |
| ---------------------------------- | ------------------------------------ | ---------------------------------------------- |
| `claude/CLAUDE.md`                 | `~/.claude/CLAUDE.md`                | Global instructions for every Claude session   |
| `claude/VOICE.md`                  | `~/.claude/VOICE.md`                 | Voice profile. Ships **empty**, see below      |
| `claude/settings.json`             | `~/.claude/settings.json`            | Model, hooks, plugins, marketplaces, UI prefs  |
| `agents/hooks/`                    | `~/.agents/hooks/`                   | Shared command guard for Claude, Codex, Cursor |
| `shell/claude-env.sh`              | sourced by `~/.bashrc`               | Claude Code env vars (auto-compact window)     |

The source of truth is `links.txt`. `install.sh` reads it.

## What is NOT managed (on purpose)

- `~/.claude/.credentials.json`, `~/.claude.json`: login and app state. They hold secrets and change all the time.
- `~/.claude/projects/`, `sessions/`, `history.jsonl`, `cache/`, `backups/`: runtime data.
- `~/.claude/plugins/`: reinstalled from `enabledPlugins` in `settings.json`.
- `~/.claude/skills/no-mistakes`, `agent-vault-cli`, `synced/`: their own CLIs or Claude sync install these.
- `~/.claude/skills/excalidraw-diagram`: a locally modified copy of [coleam00/excalidraw-diagram-skill](https://github.com/coleam00/excalidraw-diagram-skill). That repo has no license, so it can't be redistributed here.
- `~/.bashrc` itself: it stays machine-local and only gets one `source` line added.

## Install on a new machine

```bash
git clone https://github.com/Parham-Paziraie/ubuntu-setup-01.git ubuntu-setup
cd ubuntu-setup/dotfiles
./install.sh
exec bash   # load the env vars
```

What `install.sh` does:
1. Links `~/.dotfiles` to this folder.
2. For each line in `links.txt`, links `~/<target>` to `~/.dotfiles/<source>`.
3. Moves anything already at a target to `~/.dotfiles-backup/<timestamp>/`. Nothing gets deleted.
4. Marks private files (`claude/VOICE.md`) with `git update-index --skip-worktree`, so local content in them is never committed.
5. Adds one line to `~/.bashrc` that sources `shell/claude-env.sh`.

It is idempotent, so you can run it any number of times.

## Daily use

- To edit a config, edit either path. The file in `~/.claude/` is a symlink, so the change lands in this repo.
- To save changes: `git -C ~/.dotfiles diff`, then commit and push as usual.
- To pull on another machine: `git pull`. Links pick up changes right away, and env vars take effect in the next shell.

## Commands

```bash
./install.sh           # link everything (default)
./install.sh status    # check every link: ok / missing / drifted / foreign
./install.sh adopt     # a tool replaced a link with a real file: copy it into the repo and relink
```

## Why `adopt` exists

- Claude Code rewrites `settings.json` when you run `/config`, add a permission, or install a plugin.
- Some writes replace the symlink with a real file. The repo copy then goes stale without any warning.
- Run `./install.sh status` now and then. If it reports `drifted`, run `./install.sh adopt` and review with `git diff`.

## Add a new file

1. Copy it into `dotfiles/` (for example `claude/keybindings.json`).
2. Add a line to `links.txt`: `claude/keybindings.json   .claude/keybindings.json`
3. Run `./install.sh`. The original gets backed up and replaced by a link.

## Add a Claude env var

- Add `export NAME=value` to `shell/claude-env.sh`.
- Keep behavior toggles here, not in the `env` block of `settings.json`, because Claude can rewrite `settings.json` and silently drop them.
- Current toggles:
  - `CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000`: auto-compact starts when the context gets near 500k tokens.

## Undo

```bash
rm ~/.claude/CLAUDE.md                                 # remove a link
cp -a ~/.dotfiles-backup/<timestamp>/.claude/CLAUDE.md ~/.claude/   # restore original
```

## VOICE.md (private content)

- The repo is public, so `claude/VOICE.md` ships as an empty file.
- The real profile lives outside git: `~/Documents/VOICE.md`.
- After install, paste it in: `cp ~/Documents/VOICE.md ~/.claude/VOICE.md`
- `install.sh` marks the file `skip-worktree`, so `git status` stays clean and the content can't be committed by accident.
- If `~/.claude/VOICE.md` is empty, `CLAUDE.md` tells Claude to ask for the profile before writing as Parham.
- To check the protection: `git ls-files -v claude/VOICE.md` should print `S claude/VOICE.md`.

## Public repo rules

- No secrets, tokens, or personal details in tracked files. Put private content in `PRIVATE_FILES` in `install.sh` (shipped empty) or keep it out of the repo.
- Don't vendor third-party skills unless their license allows redistribution.
