# shellcheck shell=bash
# Claude Code behavior toggles, sourced from ~/.bashrc.
# Kept as shell env vars (not in settings.json "env") so Claude rewriting
# settings.json can't regress them.

# Treat the context window as this many tokens: auto-compact triggers near it.
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000
