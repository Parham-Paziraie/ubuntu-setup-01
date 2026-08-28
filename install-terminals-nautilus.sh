#!/usr/bin/env bash
# =============================================================================
# Ghostty + Kitty — install & wire into the Nautilus right-click menu
# Author: Parham Paziraie
# =============================================================================
# Usage:
#   chmod +x install-terminals-nautilus.sh
#   ./install-terminals-nautilus.sh
#
# What you get: right-click any folder (or the empty background inside one)
# in Files and pick "Open in Ghostty" or "Open in Kitty" — opens a terminal
# already cd'd into that directory.
#
# Decisions baked in:
#   - Ghostty  → snap --classic  (Ken VanDine's build; not in the Ubuntu repos)
#   - Kitty    → apt             (GPU-accelerated, ships in universe, no PPA)
#   - Menu     → nautilus-python extension, which is what puts an entry at the
#                TOP level of the context menu. Plain Nautilus scripts get
#                buried under a "Scripts" submenu, so we install both: the
#                extension for the good UX, the scripts as a fallback for when
#                the extension fails to load.
#
# Ubuntu 24.04 / Nautilus 46 facts that shape this script:
#   - Nautilus 46 is GTK4 → needs python3-nautilus 4.0 + gir1.2-nautilus-4.0,
#     and get_file_items() no longer takes a window argument.
#   - The top-level "Open in Terminal" you already have comes from the
#     nautilus-extension-gnome-terminal package and HARDCODES gnome-terminal.
#     It ignores xdg-terminals.list. See the optional cleanup at the end.
#   - Nautilus does not reliably inherit the login shell's PATH, so the
#     extension resolves absolute binary paths rather than trusting PATH.
# =============================================================================

set -euo pipefail

# ── Cosmetics ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; RESET='\033[0m'
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════${RESET}"; \
            echo -e "${GREEN}  $1${RESET}"; \
            echo -e "${CYAN}══════════════════════════════════════════════════${RESET}\n"; }
warn()    { echo -e "${YELLOW}⚠  $1${RESET}"; }
info()    { echo -e "${CYAN}ℹ  $1${RESET}"; }
ok()      { echo -e "${GREEN}✓  $1${RESET}"; }

# Refuse to run as root — everything below writes into the real user's $HOME
if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}Do not run this script with sudo. It calls sudo itself where needed.${RESET}"
  exit 1
fi

EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
SCRIPT_DIR="$HOME/.local/share/nautilus/scripts"


# ══════════════════════════════════════════════════════════════════════════════
section "1 · Install the terminals"
# ══════════════════════════════════════════════════════════════════════════════

if snap list ghostty &>/dev/null; then
  ok "Ghostty snap already installed"
else
  info "Installing Ghostty (snap, classic confinement)…"
  sudo snap install ghostty --classic
  ok "Ghostty installed"
fi

if command -v kitty &>/dev/null; then
  ok "Kitty already installed"
else
  info "Installing Kitty (apt)…"
  sudo apt update
  sudo apt install -y kitty
  ok "Kitty installed"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "2 · Install the Nautilus Python bindings"
# ══════════════════════════════════════════════════════════════════════════════
# gir1.2-nautilus-4.0 is pulled in as a dependency but named explicitly here so
# it is obvious this is the GTK4 / Nautilus 46 pairing, not the old 3.0 one.

if dpkg-query -W -f='${Status}' python3-nautilus 2>/dev/null | grep -q "^install ok installed$"; then
  ok "python3-nautilus already installed"
else
  info "Installing python3-nautilus…"
  sudo apt install -y python3-nautilus gir1.2-nautilus-4.0
  ok "python3-nautilus installed"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "3 · Write the context-menu extension"
# ══════════════════════════════════════════════════════════════════════════════

mkdir -p "$EXT_DIR"

# Earlier hand-rolled single-terminal version of this extension. Left in place
# it would register a second, duplicate "Open in Ghostty" entry.
rm -f "$EXT_DIR/open-in-ghostty.py"
rm -rf "$EXT_DIR/__pycache__"

cat > "$EXT_DIR/open-in-terminal.py" <<'PYEOF'
"""Nautilus extension adding "Open in <Terminal>" right-click entries.

Each entry appears both when right-clicking a folder and when right-clicking
the empty background of the folder currently being viewed. Terminals that are
not installed are silently skipped, so this file is safe to ship as-is.

Managed by install-terminals-nautilus.sh — local edits will be overwritten.
"""

import os
import shutil
import subprocess
from urllib.parse import unquote, urlparse

import gi

gi.require_version("Nautilus", "4.0")
from gi.repository import GObject, Nautilus  # noqa: E402

# (label, command name, fallback path, flag used to set the start directory).
# The fallback path matters because Nautilus does not always inherit the login
# shell's PATH, which is where /snap/bin normally comes from.
TERMINALS = [
    ("Ghostty", "ghostty", "/snap/bin/ghostty", "--working-directory="),
    ("Kitty", "kitty", "/usr/bin/kitty", "--directory="),
]


def _available():
    """Yield (label, executable, flag) for each terminal present on the system."""
    for label, command, fallback, flag in TERMINALS:
        executable = shutil.which(command)
        if executable is None and os.path.exists(fallback):
            executable = fallback
        if executable is not None:
            yield label, executable, flag


def _local_path(file_info):
    """Return the on-disk path for a Nautilus file, or None if it is remote."""
    uri = urlparse(file_info.get_uri())
    if uri.scheme != "file":
        return None
    return unquote(uri.path)


class OpenInTerminalExtension(GObject.GObject, Nautilus.MenuProvider):
    def _activate(self, menu_item, executable, flag, path):
        subprocess.Popen(
            [executable, flag + path],
            cwd=path,
            start_new_session=True,
        )

    def _menu_items(self, scope, path):
        items = []
        for label, executable, flag in _available():
            item = Nautilus.MenuItem(
                name="OpenInTerminal::%s::%s" % (label, scope),
                label="Open in %s" % label,
                tip="Open %s in %s" % (path, label),
            )
            item.connect("activate", self._activate, executable, flag, path)
            items.append(item)
        return items

    def get_file_items(self, files):
        if len(files) != 1 or not files[0].is_directory():
            return []
        path = _local_path(files[0])
        if path is None:
            return []
        return self._menu_items("folder", path)

    def get_background_items(self, folder):
        path = _local_path(folder)
        if path is None:
            return []
        return self._menu_items("background", path)
PYEOF

ok "Extension written to $EXT_DIR/open-in-terminal.py"

# Fail fast on syntax errors rather than letting Nautilus swallow them silently
if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$EXT_DIR/open-in-terminal.py"; then
  ok "Extension parses cleanly"
else
  warn "Extension has a syntax error — the menu entries will not appear"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "4 · Write the fallback Nautilus scripts"
# ══════════════════════════════════════════════════════════════════════════════
# These show up under right-click > Scripts. Redundant when the extension
# loads, but they cost nothing and survive Nautilus API churn.

mkdir -p "$SCRIPT_DIR"

write_fallback_script() {
  local label="$1" executable="$2" flag="$3"

  cat > "$SCRIPT_DIR/Open in $label" <<EOF
#!/usr/bin/env bash
# Opens $label in the selected folder, or in the folder currently being
# viewed when nothing (or a plain file) is selected.
# Appears under right-click > Scripts > Open in $label.
#
# Managed by install-terminals-nautilus.sh — local edits will be overwritten.

set -euo pipefail

target=""

# Prefer the first selected item if it is a directory.
if [[ -n "\${NAUTILUS_SCRIPT_SELECTED_FILE_PATHS:-}" ]]; then
    first=\$(printf '%s' "\$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS" | head -n 1)
    if [[ -d "\$first" ]]; then
        target="\$first"
    fi
fi

# Otherwise fall back to the directory being displayed. The URI is
# percent-encoded, hence the unquote round-trip.
if [[ -z "\$target" && -n "\${NAUTILUS_SCRIPT_CURRENT_URI:-}" ]]; then
    case "\$NAUTILUS_SCRIPT_CURRENT_URI" in
        file://*)
            target=\$(printf '%s' "\${NAUTILUS_SCRIPT_CURRENT_URI#file://}" \\
                | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))')
            ;;
    esac
fi

[[ -n "\$target" ]] || target="\$HOME"

exec $executable $flag"\$target"
EOF

  chmod +x "$SCRIPT_DIR/Open in $label"
  ok "Fallback script: $SCRIPT_DIR/Open in $label"
}

write_fallback_script "Ghostty" "/snap/bin/ghostty" "--working-directory="
write_fallback_script "Kitty"   "/usr/bin/kitty"    "--directory="


# ══════════════════════════════════════════════════════════════════════════════
section "5 · Prefer Ghostty for apps that honour the XDG terminal spec"
# ══════════════════════════════════════════════════════════════════════════════
# Note this does NOT change Nautilus's own built-in "Open in Terminal" entry —
# that one is hardcoded to gnome-terminal. See the closing notes.

mkdir -p "$HOME/.config"
cat > "$HOME/.config/xdg-terminals.list" <<'EOF'
ghostty_ghostty.desktop
kitty.desktop
org.gnome.Terminal.desktop
EOF
ok "Wrote ~/.config/xdg-terminals.list"


# ══════════════════════════════════════════════════════════════════════════════
section "6 · Restart Nautilus"
# ══════════════════════════════════════════════════════════════════════════════

nautilus -q &>/dev/null || true
sleep 2
ok "Nautilus quit — it will relaunch with the extension on next use"


# ══════════════════════════════════════════════════════════════════════════════
section "Done"
# ══════════════════════════════════════════════════════════════════════════════
cat <<EOF
Right-click a folder in Files. You should see:

    Open in Ghostty
    Open in Kitty

If they are missing, log out and back in — that reliably picks up newly
installed Nautilus extensions when a plain restart does not.

Optional: the existing top-level "Open in Terminal" still launches GNOME
Terminal, because it comes from a package that hardcodes it:

    sudo apt remove nautilus-extension-gnome-terminal

Removing it leaves only the two entries above.
EOF
