#!/bin/bash
# Dotfiles installer: symlinks Claude Code / agent configs from this repo into $HOME.
#
# Usage:
#   ./install.sh           link everything in links.txt (default)
#   ./install.sh status    show the state of every link
#   ./install.sh adopt     pull real files that replaced a link back into the repo, then relink
#
# Layout:
#   ~/.dotfiles  -> <this directory>
#   ~/<target>   -> ~/.dotfiles/<source>   (per line of links.txt)
# Anything already at a target is moved to ~/.dotfiles-backup/<timestamp>/ first.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$HOME/.dotfiles"
MANIFEST="$DIR/links.txt"
BASHRC="$HOME/.bashrc"
# shellcheck disable=SC2016 # literal line written into ~/.bashrc, expands there
SOURCE_LINE='[ -f "$HOME/.dotfiles/shell/claude-env.sh" ] && . "$HOME/.dotfiles/shell/claude-env.sh"'
BACKUP="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }

# Prints "src target" pairs from the manifest, skipping comments and blanks.
entries() { grep -Ev '^\s*(#|$)' "$MANIFEST" | awk '{print $1, $2}'; }

backup() { # $1 = absolute path to move out of the way
  local rel="${1#"$HOME"/}"
  mkdir -p "$BACKUP/$(dirname "$rel")"
  mv "$1" "$BACKUP/$rel"
  yellow "  backed up $1 -> $BACKUP/$rel"
}

link_root() {
  if [ -L "$DOTFILES" ] && [ "$(readlink -f "$DOTFILES")" = "$DIR" ]; then return; fi
  [ -e "$DOTFILES" ] || [ -L "$DOTFILES" ] && backup "$DOTFILES"
  ln -s "$DIR" "$DOTFILES"
  green "linked $DOTFILES -> $DIR"
}

link_all() {
  local src target want
  while read -r src target; do
    [ -e "$DIR/$src" ] || { red "missing in repo: $src"; continue; }
    target="$HOME/$target"
    want="$DOTFILES/$src"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$want" ]; then
      echo "ok      $target"
      continue
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then backup "$target"; fi
    mkdir -p "$(dirname "$target")"
    ln -s "$want" "$target"
    green "linked  $target -> $want"
  done < <(entries)
}

# Private files ship empty in the repo. skip-worktree makes git ignore local edits,
# so content pasted into them is never committed.
PRIVATE_FILES=(claude/VOICE.md)
protect_private() {
  local f
  for f in "${PRIVATE_FILES[@]}"; do
    git -C "$DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1 || continue
    git -C "$DIR" update-index --skip-worktree "$f"
  done
  green "private files protected from commits: ${PRIVATE_FILES[*]}"
}

hook_bashrc() {
  touch "$BASHRC"
  grep -qF "$SOURCE_LINE" "$BASHRC" && return
  printf '\n# Claude Code env toggles (managed by ~/.dotfiles)\n%s\n' "$SOURCE_LINE" >> "$BASHRC"
  green "added claude-env.sh source line to $BASHRC"
}

status() {
  local src target want rc=0
  while read -r src target; do
    target="$HOME/$target"
    want="$DOTFILES/$src"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$want" ]; then
      green "ok       $target"
    elif [ -L "$target" ]; then
      red "foreign  $target -> $(readlink "$target")"; rc=1
    elif [ -e "$target" ]; then
      red "drifted  $target (real file, replaced the link; run: ./install.sh adopt)"; rc=1
    else
      red "missing  $target (run: ./install.sh)"; rc=1
    fi
  done < <(entries)
  if grep -qF "$SOURCE_LINE" "$BASHRC" 2>/dev/null; then
    green "ok       ~/.bashrc sources claude-env.sh"
  else
    red "missing  ~/.bashrc source line (run: ./install.sh)"; rc=1
  fi
  return $rc
}

# A tool (e.g. Claude editing settings.json) may replace a symlink with a real file.
# adopt copies that newer file into the repo and restores the symlink.
adopt() {
  local src target
  while read -r src target; do
    target="$HOME/$target"
    [ -e "$target" ] && [ ! -L "$target" ] || continue
    [[ " ${PRIVATE_FILES[*]} " == *" $src "* ]] && { yellow "skipped private $src"; continue; }
    rm -rf "${DIR:?}/$src"
    cp -a "$target" "$DIR/$src"
    rm -rf "$target"
    ln -s "$DOTFILES/$src" "$target"
    green "adopted $target into repo ($src) and relinked"
  done < <(entries)
  echo "review with: git -C \"$DIR\" diff"
}

case "${1:-install}" in
  install) link_root; link_all; protect_private; hook_bashrc; echo; echo "done. open a new shell to load env vars." ;;
  status) status ;;
  adopt) adopt ;;
  *) echo "usage: $0 [install|status|adopt]" >&2; exit 1 ;;
esac
