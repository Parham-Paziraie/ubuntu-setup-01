#!/usr/bin/env bash
# =============================================================================
# Ubuntu 26.04 LTS "Resolute Raccoon" — Post-Installation Setup
# Target hardware: ThinkPad X13 Gen 4 (Intel)
# Author: Parham Paziraie  (revised consolidated edition)
# =============================================================================
# Usage:
#   chmod +x ubuntu-26.04-setup.sh
#   ./ubuntu-26.04-setup.sh
#
# Decisions baked in (vs. the old messy notes):
#   - Node.js     → nvm  (marked "better" in your notes)
#   - Docker      → official Docker CE repo  (NOT docker.io)
#   - VS Code     → Microsoft apt repo       (NOT snap)
#   - OBS         → Flatpak from Flathub     (Wayland-friendly, portal-aware)
#   - NDI plugin  → DistroAV (com.obsproject.Studio.Plugin.DistroAV)
#                   *** This is the renamed OBS-NDI plugin.
#                   *** The old Plugin.NDI is abandoned and broken.
#   - libndi      → bundled inside DistroAV Flatpak - NO manual SDK install
#   - Avahi       → flatpak override (system-wide) + host avahi-daemon
#   - NormCap     → Flatpak from Flathub (bundles its own tesseract + langdata)
#                   *** Wayland has no global hotkeys, so we bind it to a
#                   *** GNOME custom shortcut instead (Super+Shift+T).
#   - apt UI      → nala installed in Section 1, used from there on
#
# 26.04 facts that shape this script:
#   - Wayland-only (Xorg session removed). OBS screen capture works via
#     PipeWire portal — Flatpak gets this for free.
#   - Python 3.14 default; PEP 668 enforced → use pipx, NOT sudo pip.
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
section "2 · Add third-party APT repositories (VS Code + Docker CE)"
# ══════════════════════════════════════════════════════════════════════════════
# Doing all repo setup together so we only apt-update once afterwards.

# --- VS Code (Microsoft) ---
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor > packages.microsoft.gpg
sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list'
rm -f packages.microsoft.gpg

# --- Docker CE (official) ---
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
sudo chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update


# ══════════════════════════════════════════════════════════════════════════════
section "3 · Install from repositories: VS Code · Git · Docker · Python · misc"
# ══════════════════════════════════════════════════════════════════════════════
sudo nala install -y \
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
  turbo \
  @anthropic-ai/claude-code
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
section "7 · Flatpak: Flathub + OBS Studio + DistroAV (NDI) + NormCap"
# ══════════════════════════════════════════════════════════════════════════════
# DistroAV is the renamed OBS-NDI plugin (since 2024-06). The Flatpak version
# bundles libndi internally - no manual NDI SDK install needed on the host.
# The old com.obsproject.Studio.Plugin.NDI is abandoned; do NOT install it.
sudo flatpak remote-add --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y flathub com.obsproject.Studio
flatpak install -y flathub com.obsproject.Studio.Plugin.DistroAV

# If a previous install left the dead Plugin.NDI behind, drop it - having both
# loaded makes OBS crash on the NDI source.
flatpak uninstall -y com.obsproject.Studio.Plugin.NDI 2>/dev/null || true

# CRITICAL: Avahi access for NDI discovery (required since OBS 32).
# This override persists, so you don't need --system-talk-name= on every launch.
sudo flatpak override com.obsproject.Studio --system-talk-name=org.freedesktop.Avahi

ok "OBS + DistroAV installed. Just run:  flatpak run com.obsproject.Studio"

# --- NormCap: OCR screen capture (select a region → text lands in clipboard) ---
# Flatpak build ships its own tesseract + English traineddata, so it does not
# depend on the host tesseract-ocr package. Screen grabbing goes through the
# xdg-desktop-portal Screenshot interface, which is the only thing that works
# under 26.04's Wayland-only session.
flatpak install -y flathub com.github.dynobo.normcap

ok "NormCap installed:  flatpak run com.github.dynobo.normcap"


# ══════════════════════════════════════════════════════════════════════════════
section "8 · NDI host requirements — Avahi daemon + firewall ports"
# ══════════════════════════════════════════════════════════════════════════════
# Even with the Flatpak override, the HOST needs avahi running for mDNS
# discovery to actually broadcast/find NDI sources on the LAN.
sudo nala install -y avahi-daemon ffmpeg
sudo systemctl enable --now avahi-daemon

# UFW rules for NDI. Only applied if ufw is installed AND active.
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  info "Configuring UFW rules for NDI..."
  sudo ufw allow 5353/udp                  # mDNS (Avahi)
  sudo ufw allow 5959:5969/tcp
  sudo ufw allow 5959:5969/udp
  sudo ufw allow 6960:6970/tcp
  sudo ufw allow 6960:6970/udp
  sudo ufw allow 7960:7970/tcp
  sudo ufw allow 7960:7970/udp
  sudo ufw allow 5960/tcp
  ok "UFW rules added for NDI"
else
  info "UFW inactive — skipping firewall rules (NDI works without UFW on home LAN)"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "9 · OBS desktop launcher entry (cosmetic — override already covers Avahi)"
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/obs-studio-ndi.desktop" << 'EOF'
[Desktop Entry]
Name=OBS Studio (with NDI)
Comment=OBS Studio with DistroAV (NDI) — Avahi override already applied
Exec=flatpak run com.obsproject.Studio
Icon=com.obsproject.Studio
Terminal=false
Type=Application
Categories=AudioVideo;Video;Broadcasting;
MimeType=application/x-obs-scene;
StartupNotify=true
StartupWMClass=obs
EOF
chmod +x "$HOME/.local/share/applications/obs-studio-ndi.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true


# ══════════════════════════════════════════════════════════════════════════════
section "10 · Communication & desktop apps"
# ══════════════════════════════════════════════════════════════════════════════

# Telegram via snap (official, auto-updating)
sudo snap install telegram-desktop

# Zoom via official .deb
wget -c https://zoom.us/client/latest/zoom_amd64.deb -O /tmp/zoom_amd64.deb
sudo nala install -y /tmp/zoom_amd64.deb
sudo apt --fix-broken install -y || true
rm -f /tmp/zoom_amd64.deb


# ══════════════════════════════════════════════════════════════════════════════
section "11 · Hardware drivers (Intel — X13 Gen 4)"
# ══════════════════════════════════════════════════════════════════════════════
# X13 Gen 4 is Intel Raptor Lake (13th gen). Kernel 7.0 in 26.04 already has
# excellent support, but autoinstall picks up any non-free Lenovo/firmware bits.
sudo ubuntu-drivers autoinstall || warn "ubuntu-drivers had nothing to add (likely fine)"
lspci | grep -iE 'vga|3d|display' || true


# ══════════════════════════════════════════════════════════════════════════════
section "12 · GNOME 50 tweaks"
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

existing=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
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
section "ghosty terminal"
# ══════════════════════════════════════════════════════════════════════════════
sudo apt update
sudo apt install ghostty

# ══════════════════════════════════════════════════════════════════════════════
section "✅  Setup complete"
# ══════════════════════════════════════════════════════════════════════════════
cat <<'SUMMARY'

Installed:
  • Dev:      VS Code · Git · Node (nvm + LTS) · NestJS · Turbo · Claude Code
  •           Docker CE + Compose plugin · Python 3 + pipx + auto-editor
  • Media:    OBS Studio (Flatpak) + DistroAV NDI plugin
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
  3. Launch OBS: search "OBS Studio (with NDI)" in Activities,
     or run:    flatpak run com.obsproject.Studio
     NDI sources should appear automatically once Avahi is up.
  4. NormCap: press Super+Shift+T, drag a region, text is in your clipboard.
     First run downloads nothing extra - English OCR data ships in the Flatpak.
     Extra languages: NormCap settings (gear icon) → Languages.
  5. (Optional) Install GNOME extensions via Extension Manager:
       - Dash to Panel (charlesg99)
       - Anything else you like
  6. (Optional) Sign in to Claude Code:  claude  → /login

If NDI sources don't appear on the LAN:
  - Confirm both machines are on the same subnet
  - Check:  systemctl status avahi-daemon
  - Check:  avahi-browse -a   (should list local services)
  - Verify the Flatpak override is in place:
       flatpak override --show com.obsproject.Studio

SUMMARY
