#!/usr/bin/env bash
# =============================================================================
# Ubuntu 26.04 LTS "Resolute Raccoon" — Post-Installation Setup
# Target hardware: ThinkPad X13 Gen 4 (Intel)
# Author: Parham Paziraie  (deb-OBS / VST edition)
# =============================================================================
# Usage:
#   chmod +x ubuntu-26.04-setup-obs-vst.sh
#   ./ubuntu-26.04-setup-obs-vst.sh
#
# LAYOUT
# -----------------------------------------------------------------------------
# This script builds the machine. Everything OBS-related was split out into
# obs-vst-setup.sh, which section 7 invokes:
#
#     ubuntu-26.04-setup-obs-vst.sh        <- you are here
#       1  base toolchain
#       2  third-party repos (VS Code, Docker CE)
#       3  apt packages
#       4  Docker group      5  Node/nvm      6  Python/pipx
#       7  ── ./obs-vst-setup.sh ───────────┐
#       10 Flatpak + NormCap                │
#       11 comms   12 drivers   13 GNOME   14 Ghostty
#                                           │
#     obs-vst-setup.sh  <───────────────────┘
#       obsproject PPA + mandatory-PPA guard
#       obs-studio + lsp-plugins-vst (the whole point)
#       XWayland launcher so VST editor windows can open without a SIGSEGV
#       DistroAV (NDI) · Vertical Canvas · Source Record, with their stale
#         libqt6*t64 dependency names retargeted to the 26.04 package names
#       libndi runtime · Avahi · UFW ports
#       plugin verification roll-up
#
# obs-vst-setup.sh is standalone: run it on its own to rebuild only the OBS rig.
# Section numbers 8, 9 and 15 are retired; they moved there wholesale.
#
# HOW THIS DIFFERS FROM ubuntu-26.04-setup.sh
# -----------------------------------------------------------------------------
# This variant exists for ONE reason: audio VST filters in OBS, which needs the
# deb OBS rather than the Flatpak. The full reasoning now lives in the
# obs-vst-setup.sh header. Short version: the Flatpak OBS hard-sets
# VST_PATH=/app/extensions/Plugins/vst in its manifest, so it scans ONLY that
# sandbox directory and can never see host VSTs in /usr/lib/vst. The deb has no
# such override.
#
# Decisions carried over unchanged:
#   - Node.js     -> nvm
#   - Docker      -> official Docker CE repo  (NOT docker.io)
#   - VS Code     -> Microsoft apt repo       (NOT snap)
#   - NormCap     -> Flatpak
#   - apt UI      -> nala installed in Section 1, used from there on, EXCEPT
#                    for local .deb files, which go through apt
#
# RE-RUNNING THIS SCRIPT
# -----------------------------------------------------------------------------
# It is idempotent by design and re-running is the supported repair path.
# Installing an already-installed apt package is a no-op, and the snap, Flatpak
# and .bashrc steps all check before they act. So if a step fails, fix the cause
# and just run it again - it retries only what is missing.
#
# Failures are collected in FAILURES, replayed at the end, and make the script
# exit 1. That includes a non-zero exit from obs-vst-setup.sh.
#
# NEVER pipe a producer into `grep -q` in this script. `grep -q` exits on its
# first match, killing a still-writing producer with SIGPIPE (141); under
# `set -o pipefail` the pipeline then reports 141 even though grep matched, so
# the check answers "no" precisely when the truth is "yes". Capture to a
# variable and match that instead.
#
# 26.04 facts that shape this script:
#   - Wayland-only (Xorg session removed). The deb OBS still does screen
#     capture through the PipeWire portal, same as the Flatpak.
#   - Python 3.14 default; PEP 668 enforced -> use pipx, NOT sudo pip.
#   - App Center handles .deb natively now (gdebi mostly redundant).
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

# Anything that lands in FAILURES is replayed in the closing summary and makes
# the script exit non-zero, so a broken OBS/plugin never hides behind 600 lines
# of scrollback that ended in a cheerful "Setup complete".
FAILURES=()
fail()    { echo -e "${RED}✗  $1${RESET}"; FAILURES+=("$1"); }

# Refuse to run as root — Flatpak --user, nvm, pipx all need real $HOME
if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}Do not run this script with sudo. It calls sudo itself where needed.${RESET}"
  exit 1
fi


# ══════════════════════════════════════════════════════════════════════════════
section "1 · System update & base toolchain"
# ══════════════════════════════════════════════════════════════════════════════
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
  curl wget git vim \
  build-essential software-properties-common \
  apt-transport-https ca-certificates gnupg lsb-release \
  nala                # nicer apt frontend, used below


# ══════════════════════════════════════════════════════════════════════════════
section "2 · Add third-party APT repositories (VS Code + Docker CE + OBS)"
# ══════════════════════════════════════════════════════════════════════════════
# Doing all repo setup together so we only apt-update once afterwards.

# Scratch space for every transient download in this script. Removed on exit,
# success or failure, so an aborted run never leaves a half-written .deb in
# /tmp that a later `wget -c` would then try to resume into.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- VS Code (Microsoft) ---
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor > "$WORKDIR/packages.microsoft.gpg"
sudo install -o root -g root -m 644 "$WORKDIR/packages.microsoft.gpg" /etc/apt/trusted.gpg.d/
sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'

# --- Docker CE (official) ---
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
sudo chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# --- OBS Studio ---
# The obsproject PPA is NOT set up here. It lives in obs-vst-setup.sh together
# with everything else OBS-related, so that script stays runnable on its own.
# See section 7 below.

sudo apt update


# ══════════════════════════════════════════════════════════════════════════════
section "3 · Install from repositories: VS Code · Git · Docker · Python · misc"
# ══════════════════════════════════════════════════════════════════════════════
# ubuntu-restricted-extras Recommends ttf-mscorefonts-installer, which puts up
# a full-screen debconf EULA that `-y` does NOT dismiss - it will sit there
# waiting for a keypress and stall an otherwise unattended run. Pre-accept the
# licence and force the noninteractive frontend for this one call.
echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
  | sudo debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive nala install -y \
  code \
  git-all \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  python3 python3-pip pipx \
  flatpak \
  gnome-shell-extension-manager \
  gdebi wmctrl tesseract-ocr postgresql-client wl-clipboard \
  intel-gpu-tools mesa-utils intel-microcode linux-firmware \
  ubuntu-restricted-extras \
  shotcut

git --version
code --version | head -n1


# ══════════════════════════════════════════════════════════════════════════════
section "4 · Docker — enable rootless usage for current user"
# ══════════════════════════════════════════════════════════════════════════════
sudo usermod -aG docker "$USER"
warn "Docker group change takes effect on next login. To use now in THIS shell:"
warn "   newgrp docker"


# ══════════════════════════════════════════════════════════════════════════════
section "5 · Node.js via nvm (+ global dev tools)"
# ══════════════════════════════════════════════════════════════════════════════
# Latest nvm release as of writing. Bumping is harmless: nvm.sh is stable.
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

# nvm.sh references unset internal vars (PROVIDED_VERSION etc.) which is fine
# in normal shells but fatal under `set -u`. Relax it around all nvm/npm calls.
set +u
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install --lts        # latest LTS, more stable for a daily driver than "node"
# `nvm install` auto-activates the version it just installed — no need for
# a separate `nvm use` (which is also where the PROVIDED_VERSION crash hits).

node --version
npm --version

npm install -g \
  @nestjs/cli \
  turbo

# Claude Code is deliberately NOT in that list. Its native installer puts a
# binary in ~/.local/bin, which sits ahead of nvm's bin on PATH - so adding the
# npm package on top gives you two independently self-updating copies where the
# npm one is permanently shadowed. Only install it if nothing already provides
# `claude`.
if command -v claude >/dev/null 2>&1; then
  info "claude already on PATH ($(command -v claude)) - skipping the npm package"
else
  npm install -g @anthropic-ai/claude-code
fi
set -u


# ══════════════════════════════════════════════════════════════════════════════
section "6 · Python aliases + pipx tools"
# ══════════════════════════════════════════════════════════════════════════════
# Ubuntu 26.04 ships Python 3.14 and enforces PEP 668. Use pipx for CLI tools,
# never `sudo pip install` system-wide — it will be blocked anyway.
grep -qxF 'alias python=python3' "$HOME/.bashrc" || echo 'alias python=python3' >> "$HOME/.bashrc"
grep -qxF 'alias pip=pip3'       "$HOME/.bashrc" || echo 'alias pip=pip3'       >> "$HOME/.bashrc"

pipx ensurepath
pipx install auto-editor || warn "auto-editor already installed — skipping"


# ══════════════════════════════════════════════════════════════════════════════
section "7 · OBS Studio + audio VST rig  (delegated)"
# ══════════════════════════════════════════════════════════════════════════════
# Everything OBS-related lives in obs-vst-setup.sh: the obsproject PPA and its
# mandatory-PPA guard, obs-studio, the LSP VST payload, DistroAV/NDI, Vertical
# Canvas, Source Record, libndi, Avahi and the plugin verification roll-up.
#
# It is standalone - it installs its own prerequisites and uses plain apt - so
# you can run it on its own to rebuild just the OBS rig without re-running this
# whole script. That is also why it is a separate process here rather than
# sourced: its `exit 1` on a dead PPA should not kill this script's remaining
# sections, and its FAILURES array stays its own.
OBS_SCRIPT="$(dirname "$(readlink -f "$0")")/obs-vst-setup.sh"

if [[ ! -x "$OBS_SCRIPT" ]]; then
  fail "obs-vst-setup.sh not found or not executable at ${OBS_SCRIPT}"
  warn "The OBS/VST rig was skipped entirely. Fetch it alongside this script and run:"
  warn "   ./obs-vst-setup.sh"
elif "$OBS_SCRIPT"; then
  ok "OBS/VST rig complete"
else
  fail "obs-vst-setup.sh reported failures - see its own summary above"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "10 · Flatpak: Flathub + NormCap"
# ══════════════════════════════════════════════════════════════════════════════
# Flatpak is still worth having for NormCap — its Flatpak build ships its own
# tesseract + English traineddata, so it does not depend on the host
# tesseract-ocr package. Screen grabbing goes through the xdg-desktop-portal
# Screenshot interface, which is the only thing that works under 26.04's
# Wayland-only session.
#
# --system on BOTH calls is not cosmetic. If flathub is ALSO registered in the
# user installation - easy to end up with, and already the case on this laptop -
# then a bare `flatpak install flathub ...` cannot tell which one you mean. It
# prompts to disambiguate, `-y` does NOT answer that prompt, and it exits 1:
#     error: No remote chosen to resolve 'flathub' which exists in multiple
#            installations
# Under `set -e` that ended the script here and sections 11-14 never ran.
# Naming the installation explicitly removes the ambiguity.
sudo flatpak remote-add --system --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

# Captured to a variable rather than piped into `grep -qx`. `grep -q` exits on
# its first match, killing the still-writing producer with SIGPIPE (141); under
# `set -o pipefail` that 141 becomes the pipeline's status, so a SUCCESSFUL
# match reported failure. The old form therefore answered "not installed"
# precisely when NormCap WAS installed, and reinstalled it on every run.
FLATPAK_SYS_APPS="$(flatpak list --system --app --columns=application 2>/dev/null || true)"

if grep -qx com.github.dynobo.normcap <<<"$FLATPAK_SYS_APPS"; then
  ok "NormCap already installed - skipping"
else
  sudo flatpak install --system -y flathub com.github.dynobo.normcap \
    || fail "NormCap: flatpak install failed"
fi

ok "NormCap:  flatpak run com.github.dynobo.normcap"

# The "a Flatpak OBS is also installed" warning moved to obs-vst-setup.sh,
# which is where the deb-vs-Flatpak conflict actually matters.


# ══════════════════════════════════════════════════════════════════════════════
section "11 · Communication & desktop apps"
# ══════════════════════════════════════════════════════════════════════════════

# Telegram via snap (official, auto-updating).
# `snap install` on an already-installed snap is not dependably a no-op across
# snapd versions, and under `set -e` one unexpected non-zero here ends the run.
# Ask first. Keeping it current is snapd's job, not this script's.
if snap list telegram-desktop >/dev/null 2>&1; then
  ok "telegram-desktop snap already installed - skipping"
else
  sudo snap install telegram-desktop || fail "telegram-desktop: snap install failed"
fi

# Zoom via official .deb, downloaded into $WORKDIR rather than /tmp with
# `wget -c`: resuming into a fixed filename is exactly how you end up
# installing a .deb that is half one release and half the next.
if wget -q --show-progress -O "$WORKDIR/zoom_amd64.deb" \
     https://zoom.us/client/latest/zoom_amd64.deb; then
  sudo apt install -y "$WORKDIR/zoom_amd64.deb" || fail "Zoom: package install failed"
  rm -f "$WORKDIR/zoom_amd64.deb"
else
  fail "Zoom: download failed - https://zoom.us/client/latest/zoom_amd64.deb"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "12 · Hardware drivers (Intel — X13 Gen 4)"
# ══════════════════════════════════════════════════════════════════════════════
# X13 Gen 4 is Intel Raptor Lake (13th gen). Kernel 7.0 in 26.04 already has
# excellent support, but autoinstall picks up any non-free Lenovo/firmware bits.
# NOTE: `ubuntu-drivers autoinstall` was REMOVED in ubuntu-drivers-common 1:0.10.x.
# The subcommands are now: debug · devices · install · list · list-oem.
# Calling autoinstall on 26.04 just errors with "No such command".
sudo ubuntu-drivers install || warn "ubuntu-drivers had nothing to add (likely fine on Intel-only)"
lspci | grep -iE 'vga|3d|display' || true


# ══════════════════════════════════════════════════════════════════════════════
section "13 · GNOME 50 tweaks"
# ══════════════════════════════════════════════════════════════════════════════
# Double-click on a Dash icon → minimize the window (matches macOS muscle memory).
# Only meaningful if you DIDN'T install Dash-to-Panel. Harmless if extension
# isn't installed — gsettings just silently fails.
gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize-or-previews' \
  2>/dev/null || true

# --- NormCap hotkey: Super+Shift+T -------------------------------------------
# Wayland gives no global hotkey API to apps, so NormCap can't grab one itself.
# A GNOME custom keybinding is the supported way to do it.
NC_KEY_BASE='org.gnome.settings-daemon.plugins.media-keys.custom-keybinding'
NC_PATH='/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/normcap/'

# Under `set -e` a failed gsettings read would end the script one section from
# the finish line. An empty list is the correct fallback.
existing="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo '@as []')"
if [[ "$existing" != *"$NC_PATH"* ]]; then
  if [[ "$existing" == "@as []" || "$existing" == "[]" ]]; then
    updated="['$NC_PATH']"
  else
    updated="${existing%]}, '$NC_PATH']"
  fi
  gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$updated"
fi

gsettings set "${NC_KEY_BASE}:${NC_PATH}" name    'NormCap (OCR capture)'
gsettings set "${NC_KEY_BASE}:${NC_PATH}" command 'flatpak run com.github.dynobo.normcap'
gsettings set "${NC_KEY_BASE}:${NC_PATH}" binding '<Super><Shift>t'
ok "NormCap bound to Super+Shift+T"


# ══════════════════════════════════════════════════════════════════════════════
section "14 · Ghostty terminal"
# ══════════════════════════════════════════════════════════════════════════════
# Ghostty is in the 26.04 universe archive, so plain apt works. -y matters:
# without it this prompts, and under `set -e` a declined prompt kills the run
# on its very last step.
sudo apt install -y ghostty


# The OBS/plugin verification roll-up lives in obs-vst-setup.sh section 8.
# Section 7 above already folded its exit status into this script's FAILURES.


# ══════════════════════════════════════════════════════════════════════════════
section "✅  Setup complete"
# ══════════════════════════════════════════════════════════════════════════════
cat <<'SUMMARY'

Installed:
  • Dev:      VS Code · Git · Node (nvm + LTS) · NestJS · Turbo · Claude Code
  •           Docker CE + Compose plugin · Python 3 + pipx + auto-editor
  • Media:    OBS Studio + VST rig - installed by obs-vst-setup.sh, which
  •           printed its own summary and verification above
  •           Shotcut · ubuntu-restricted-extras
  • Comms:    Zoom · Telegram
  • Tools:    NormCap (OCR screen capture, Super+Shift+T)
  • System:   Avahi · ffmpeg · Tesseract · PostgreSQL client · wl-clipboard
  •           intel-gpu-tools · mesa-utils · intel-microcode · linux-firmware
  •           GNOME Extension Manager · wmctrl · gdebi

Manual next steps:
  1. **Open a new terminal** (or run `source ~/.bashrc`) before using node/npm.
     Reason: nvm is loaded by your shell rc file, and a script can't modify
     its parent shell's environment. New terminals will have it automatically.
  2. Log out and back in (or reboot) for Docker group membership to take effect.
  3. NormCap: press Super+Shift+T, drag a region, text is in your clipboard.
     First run downloads nothing extra - English OCR data ships in the Flatpak.
     Extra languages: NormCap settings (gear icon) → Languages.
  4. (Optional) Install GNOME extensions via Extension Manager:
       - Dash to Panel (charlesg99)
       - Anything else you like
  5. (Optional) Sign in to Claude Code:  claude  → /login

OBS, VSTs and NDI: see the obs-vst-setup.sh summary printed in section 7 above.
It carries its own troubleshooting for an empty VST list and for NDI sources
that don't appear on the LAN. To rebuild just that rig without re-running this
whole script:

    ./obs-vst-setup.sh

SUMMARY


# ══════════════════════════════════════════════════════════════════════════════
# Did anything actually break?
# ══════════════════════════════════════════════════════════════════════════════
# Every optional step above is best-effort so that one dead download cannot cost
# you a 20-minute run. This is where that bill comes due: without it the script
# ends on a cheerful "Setup complete" whether or not OBS can load a single
# plugin, and you find out mid-stream instead.
if ((${#FAILURES[@]})); then
  echo -e "${RED}══════════════════════════════════════════════════${RESET}"
  echo -e "${RED}  ${#FAILURES[@]} step(s) did NOT complete:${RESET}"
  for _f in "${FAILURES[@]}"; do
    echo -e "${RED}    ✗ $_f${RESET}"
  done
  echo -e "${RED}══════════════════════════════════════════════════${RESET}"
  echo
  echo "Re-running this script is safe - everything already in place is a no-op,"
  echo "so it retries only what is missing."
  exit 1
fi

ok "All post-install checks passed."
