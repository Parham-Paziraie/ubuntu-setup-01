#!/usr/bin/env bash
# =============================================================================
# Ubuntu 26.04 LTS "Resolute Raccoon" - Post-Installation Setup
# Target hardware: ASUS Creator/Vivobook Q540VJ
#                  Intel Core i9-13900H · NVIDIA RTX 3050 6GB · 15.6" 2.8K OLED
# Author: Parham Paziraie
# =============================================================================
# BEFORE YOU WIPE WINDOWS:
#   1. Flash the latest BIOS from Windows / MyASUS. ASUS consumer laptops are
#      largely absent from LVFS, so fwupd will not do it for you afterwards and
#      you would have to build a USB flasher to get back to it.
#   2. Leave Secure Boot ENABLED. This script deliberately installs only
#      Canonical-signed kernel modules, so there is no MOK enrollment dance.
#
# Usage:
#   chmod +x ubuntu-26.04-setup-asus-q540vj.sh
#   ./ubuntu-26.04-setup-asus-q540vj.sh
#
# Differences vs. the ThinkPad X13 script:
#   - OBS      -> STANDARD OBS ONLY. No DistroAV/NDI, no Avahi, no NDI firewall
#                 rules. Just OBS + a working virtual camera.
#   - GPU      -> Hybrid Intel Iris Xe + RTX 3050. `ubuntu-drivers install`,
#                 which pulls nvidia-headless-no-dkms-* plus the prebuilt
#                 linux-modules-nvidia-*-generic (signed, no DKMS, no MOK).
#                 NOT asusctl/supergfxctl: no Ubuntu package, needs a Rust
#                 source build, and targets ROG boards, not this Vivobook.
#   - Adds     -> GIMP · Claude Desktop · ChatGPT desktop · Codex CLI · pi
#                 Google Chrome · Outlook PWA · Okular + Acrobat Reader DC
#
# Decisions baked in:
#   - Node.js        -> nvm (not apt, not snap)
#   - Docker         -> official Docker CE repo (NOT docker.io)
#   - VS Code        -> Microsoft apt repo (NOT snap)
#   - Claude Desktop -> official Anthropic apt repo (Linux beta, June 2026),
#                       with the signing key fingerprint actually verified
#   - ChatGPT        -> official OpenAI .deb (Linux preview, Aug 2026); the .deb
#                       registers OpenAI's apt repo, so it self-updates after
#   - OBS / GIMP     -> Flatpak from Flathub, installed --user. A system-wide
#                       flatpak install needs polkit admin auth (auth_admin_keep
#                       on org.freedesktop.Flatpak.app-install), which -y cannot
#                       bypass and which stalls an otherwise unattended run.
#   - v4l2loopback   -> linux-modules-v4l2loopback-generic (main, Canonical-
#                       signed) instead of v4l2loopback-dkms. The DKMS package
#                       triggers a MOK password dialog under Secure Boot and
#                       then rebuilds on every kernel bump.
#   - PDF            -> Okular as daily driver + acrordrdc snap as the fallback
#                       for Adobe-only XFA forms (that snap is old and flaky)
#   - apt UI         -> nala, installed in Section 1 and used from there on
#
# 26.04 facts that shape this script:
#   - Wayland-only (Xorg session removed). Screen capture goes through the
#     PipeWire portal - Flatpak OBS gets this for free.
#   - Python 3.14 default; PEP 668 enforced -> pipx, never `sudo pip`.
#   - Ghostty is in the 26.04 universe archive now, so plain apt works.
#   - `ubuntu-drivers` has NO `autoinstall` subcommand any more. It is exactly:
#     debug · devices · install · list · list-oem
# =============================================================================

set -euo pipefail

# -- Cosmetics ---------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; RESET='\033[0m'
section() { echo -e "\n${CYAN}==================================================${RESET}"; \
            echo -e "${GREEN}  $1${RESET}"; \
            echo -e "${CYAN}==================================================${RESET}\n"; }
warn()    { echo -e "${YELLOW}!  $1${RESET}"; }
info()    { echo -e "${CYAN}i  $1${RESET}"; }
ok()      { echo -e "${GREEN}+  $1${RESET}"; }

# Refuse to run as root - Flatpak --user, nvm, pipx all need the real $HOME
if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}Do not run this script with sudo. It calls sudo itself where needed.${RESET}"
  exit 1
fi

ARCH="$(dpkg --print-architecture)"


# ==============================================================================
section "1 · System update & base toolchain"
# ==============================================================================
sudo apt update && sudo apt upgrade -y

# --no-update because add-apt-repository runs `apt-get update` by default, and
# we just ran one. The repos added in Section 3 get their own update.
sudo add-apt-repository -y --no-update universe

sudo apt install -y \
  curl wget git vim \
  build-essential software-properties-common \
  apt-transport-https ca-certificates gnupg lsb-release \
  mokutil \
  nala                # nicer apt frontend, used below


# ==============================================================================
section "2 · Secure Boot preflight"
# ==============================================================================
# Nothing here changes state. It only reports, because Secure Boot decides
# whether the NVIDIA and v4l2loopback modules will load at all.
SB_STATE="$(mokutil --sb-state 2>/dev/null | head -n1 || echo 'unknown')"
info "Secure Boot: ${SB_STATE}"

if [[ "$SB_STATE" == *"enabled"* ]]; then
  ok "Secure Boot is on. This script installs only Canonical-signed modules:"
  ok "   NVIDIA        -> linux-modules-nvidia-*-generic  (restricted, signed)"
  ok "   v4l2loopback  -> linux-modules-v4l2loopback-*    (main, signed)"
  ok "So there is no MOK password prompt and no blue MOK Manager screen."
  info "If you ever install a DKMS module by hand, THAT is when you get one."
else
  info "Secure Boot is off or unknown - signed modules load either way."
fi


# ==============================================================================
section "3 · Third-party APT repositories (VS Code · Docker CE · Chrome · Claude Desktop)"
# ==============================================================================
# All repo setup happens together so we only apt-update once afterwards.
sudo install -m 0755 -d /usr/share/keyrings

# --- VS Code (Microsoft) ---
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/packages.microsoft.gpg
sudo chmod a+r /usr/share/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

# --- Docker CE (official) ---
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
sudo chmod a+r /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# --- Google Chrome (needed for the Outlook PWA in Section 13) ---
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
sudo chmod a+r /usr/share/keyrings/google-chrome.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
  | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null

# --- Claude Desktop (official Anthropic repo, Linux beta) -------------------
# The key is ASCII armor, so signed-by can point at the .asc directly. The
# fingerprint is COMPARED, not just printed: a mismatch means the key rotated
# or something is wrong upstream, and either way we would rather skip the repo
# than trust it silently.
EXPECTED_CLAUDE_FP="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
INSTALL_CLAUDE_DESKTOP=1

sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc \
  https://downloads.claude.ai/claude-desktop/key.asc
sudo chmod a+r /usr/share/keyrings/claude-desktop-archive-keyring.asc

ACTUAL_CLAUDE_FP="$(gpg --show-keys --with-colons \
  /usr/share/keyrings/claude-desktop-archive-keyring.asc 2>/dev/null \
  | awk -F: '/^fpr:/ {print $10; exit}')"

if [[ "$ACTUAL_CLAUDE_FP" == "$EXPECTED_CLAUDE_FP" ]]; then
  echo "deb [signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
    | sudo tee /etc/apt/sources.list.d/claude-desktop.list > /dev/null
  ok "Claude Desktop signing key verified (${EXPECTED_CLAUDE_FP})"
else
  INSTALL_CLAUDE_DESKTOP=0
  sudo rm -f /usr/share/keyrings/claude-desktop-archive-keyring.asc \
             /etc/apt/sources.list.d/claude-desktop.list
  warn "Claude Desktop key fingerprint MISMATCH - repo not added, package skipped."
  warn "   expected: ${EXPECTED_CLAUDE_FP}"
  warn "   got:      ${ACTUAL_CLAUDE_FP:-<none>}"
  warn "Check https://support.claude.com for a rotated key before trusting it."
fi

sudo apt update


# ==============================================================================
section "4 · Install from repositories"
# ==============================================================================
sudo nala install -y \
  code \
  git-all \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin \
  python3 python3-pip pipx \
  flatpak \
  google-chrome-stable \
  okular okular-extra-backends poppler-utils \
  ghostty \
  gnome-shell-extension-manager \
  gdebi wmctrl tesseract-ocr postgresql-client wl-clipboard \
  intel-gpu-tools mesa-utils intel-microcode linux-firmware nvtop \
  shotcut

# Kept separate: it fails the whole batch if the key check above rejected it.
if [[ "$INSTALL_CLAUDE_DESKTOP" == "1" ]]; then
  sudo nala install -y claude-desktop
  ok "Claude Desktop installed - launch it from Activities"
else
  warn "Claude Desktop skipped (see key mismatch above)"
fi

# Kept separate too: ubuntu-restricted-extras recommends ttf-mscorefonts-installer,
# which stops the run dead on a full-screen EULA dialog. Preseed the answer and
# force a non-interactive frontend so an unattended run actually completes.
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
  | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive nala install -y ubuntu-restricted-extras
info "Microsoft core fonts EULA was auto-accepted (/usr/share/doc/ttf-mscorefonts-installer/)"

git --version
code --version | head -n1


# ==============================================================================
section "5 · Docker - enable rootless usage for current user"
# ==============================================================================
sudo usermod -aG docker "$USER"
warn "Docker group change takes effect on next login. To use it in THIS shell:"
warn "   newgrp docker"


# ==============================================================================
section "6 · Node.js via nvm + AI CLIs (Claude Code · Codex · pi)"
# ==============================================================================
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

# nvm.sh references unset internal vars (PROVIDED_VERSION etc.) which is fine
# in normal shells but fatal under `set -u`. Relax it around all nvm/npm calls.
set +u
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install --lts        # latest LTS, more stable for a daily driver than "node"
# `nvm install` auto-activates what it just installed - no separate `nvm use`.

node --version
npm --version

npm install -g \
  @nestjs/cli \
  turbo \
  @anthropic-ai/claude-code \
  @openai/codex

# pi publishes no install/postinstall hooks, so --ignore-scripts costs nothing
# and keeps the dependency tree from running arbitrary code at install time.
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
set -u

# Assert the three CLIs actually run, rather than assuming npm exit 0 meant a
# working binary.
for cli in claude codex pi; do
  if command -v "$cli" >/dev/null 2>&1; then
    ok "$cli -> $("$cli" --version 2>&1 | head -n1)"
  else
    warn "$cli is not on PATH - check the npm output above"
  fi
done


# ==============================================================================
section "7 · Python aliases + pipx tools"
# ==============================================================================
# Ubuntu 26.04 ships Python 3.14 and enforces PEP 668. Use pipx for CLI tools,
# never `sudo pip install` system-wide - it is blocked anyway.
grep -qxF 'alias python=python3' "$HOME/.bashrc" || echo 'alias python=python3' >> "$HOME/.bashrc"
grep -qxF 'alias pip=pip3'       "$HOME/.bashrc" || echo 'alias pip=pip3'       >> "$HOME/.bashrc"

pipx ensurepath
pipx install auto-editor \
  || warn "pipx install auto-editor failed - already installed, or read the error above"


# ==============================================================================
section "8 · Flatpak (--user): OBS Studio (standard) · GIMP · NormCap"
# ==============================================================================
# Everything here is --user. A system install would hit polkit
# (org.freedesktop.Flatpak.app-install = auth_admin_keep) and block on a
# password dialog that `-y` does not answer.
flatpak remote-add --user --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

# --- OBS Studio, plain. No NDI/DistroAV plugin on this machine. --------------
# Flatpak pulls the matching org.freedesktop.Platform.GL.nvidia runtime on its
# own, so NVENC hardware encoding on the RTX 3050 works without extra setup.
flatpak install --user -y flathub com.obsproject.Studio

# Drop NDI leftovers from either scope if this box ever had them - both plugins
# loaded at once makes OBS crash on the NDI source.
flatpak uninstall --user -y com.obsproject.Studio.Plugin.DistroAV 2>/dev/null || true
flatpak uninstall --user -y com.obsproject.Studio.Plugin.NDI      2>/dev/null || true

ok "OBS installed:  flatpak run com.obsproject.Studio"

# --- GIMP (Flathub tracks 3.x; the apt package lags a release behind) --------
flatpak install --user -y flathub org.gimp.GIMP
ok "GIMP installed:  flatpak run org.gimp.GIMP"

# --- NormCap: OCR screen capture (select a region -> text in clipboard) ------
# Bundles its own tesseract + English traineddata, and grabs the screen through
# the xdg-desktop-portal Screenshot interface - the only thing that works on
# 26.04's Wayland-only session. Hotkey is bound in Section 14.
flatpak install --user -y flathub com.github.dynobo.normcap
ok "NormCap installed:  flatpak run com.github.dynobo.normcap"


# ==============================================================================
section "9 · OBS virtual camera (signed v4l2loopback)"
# ==============================================================================
# OBS's "Start Virtual Camera" button needs v4l2loopback on the HOST - the
# Flatpak cannot provide a kernel module. Ubuntu 26.04 ships this prebuilt and
# Canonical-signed in main, so we use that instead of v4l2loopback-dkms:
#   - loads under Secure Boot with no MOK enrollment
#   - no rebuild (and no silent breakage) on every kernel upgrade
V4L2_META="linux-modules-v4l2loopback-generic"
if ! apt-cache show "$V4L2_META" >/dev/null 2>&1; then
  V4L2_META="linux-modules-v4l2loopback-generic-hwe-26.04"
fi
info "Using signed module metapackage: ${V4L2_META}"
sudo nala install -y "$V4L2_META" ffmpeg

# --no-install-recommends matters: v4l2loopback-utils recommends
# v4l2loopback-dkms, which would drag the DKMS build back in behind our back.
sudo apt-get install -y --no-install-recommends v4l2loopback-utils

echo 'v4l2loopback' | sudo tee /etc/modules-load.d/v4l2loopback.conf > /dev/null
printf 'options v4l2loopback devices=1 video_nr=9 card_label="OBS Virtual Camera" exclusive_caps=1\n' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf > /dev/null

sudo modprobe -r v4l2loopback 2>/dev/null || true
if sudo modprobe v4l2loopback devices=1 video_nr=9 card_label="OBS Virtual Camera" exclusive_caps=1 2>/dev/null; then
  ok "v4l2loopback loaded now (/dev/video9)"
else
  # Expected when Section 1's upgrade installed a newer kernel: the signed
  # module ships for the NEW ABI, which is not the one currently running.
  info "v4l2loopback will load after the reboot - the signed module tracks the newest kernel ABI"
fi


# ==============================================================================
section "10 · Snaps: Telegram · Adobe Acrobat Reader DC"
# ==============================================================================
sudo snap install telegram-desktop

# acrordrdc is Acrobat Reader DC running under Wine in a snap. It is the 2019
# Reader and unmaintained - keep it ONLY for Adobe-specific XFA forms that
# Okular refuses. Okular is the daily driver.
sudo snap install acrordrdc \
  || warn "acrordrdc snap unavailable - Okular is installed and handles annotations, forms and signing"


# ==============================================================================
section "11 · .deb apps: Zoom · ChatGPT desktop"
# ==============================================================================
# --- Zoom ---
wget -c "https://zoom.us/client/latest/zoom_${ARCH}.deb" -O "/tmp/zoom_${ARCH}.deb"
sudo nala install -y "/tmp/zoom_${ARCH}.deb"
sudo apt --fix-broken install -y || true
rm -f "/tmp/zoom_${ARCH}.deb"

# --- ChatGPT desktop (official OpenAI Linux preview) ---
# Installing the .deb registers OpenAI's signed apt repo, so from here on it
# updates with a normal `apt upgrade`. Ships the GUI Codex integration too.
wget -c "https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_${ARCH}.deb" \
  -O "/tmp/chatgpt_${ARCH}.deb"
sudo nala install -y "/tmp/chatgpt_${ARCH}.deb"
sudo apt --fix-broken install -y || true
rm -f "/tmp/chatgpt_${ARCH}.deb"
ok "ChatGPT desktop installed:  chatgpt"


# ==============================================================================
section "12 · Hardware: hybrid Intel Iris Xe + NVIDIA RTX 3050"
# ==============================================================================
# The Q540VJ is Raptor Lake-H with an Ampere RTX 3050 6GB on a hybrid (Optimus)
# setup - no MUX switch.
#
# `ubuntu-drivers install` resolves to nvidia-headless-no-dkms-<ver> plus the
# prebuilt linux-modules-nvidia-<ver>-generic package (Canonical-signed, in
# restricted). DKMS is opt-in behind --include-dkms and we do NOT want it: DKMS
# is what would demand a MOK password under Secure Boot.
#
# There is no `autoinstall` subcommand in ubuntu-drivers-common 1:0.10.x any
# more, so do not "fall back" to it - that limb is dead code.
sudo ubuntu-drivers install \
  || warn "ubuntu-drivers install failed - inspect 'ubuntu-drivers devices' and 'ubuntu-drivers list' by hand"

# nvidia-prime normally arrives as a dependency of the nvidia-driver-* metapackage.
# Only install it if prime-select somehow is not there.
command -v prime-select >/dev/null 2>&1 || sudo nala install -y nvidia-prime
prime-select query || true

lspci | grep -iE 'vga|3d|display' || true

# Deliberately NOT forcing a mode. on-demand is the sane default here and it is
# the only mode where both things you want are true at once:
#   - the desktop runs on the Iris Xe, so the fans stay quiet on battery
#   - the RTX 3050 is still available for OBS NVENC when you need it
# `prime-select intel` would kill the dGPU entirely, including NVENC in OBS.
info "GPU mode left at the default (on-demand). Offload a single app with:"
info "   __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <command>"
info "Force a mode with:  sudo prime-select intel|nvidia|on-demand   (then log out)"


# ==============================================================================
section "13 · Outlook PWA (Chrome app window)"
# ==============================================================================
# Chrome's --app mode gives a real, chrome-less window with its own launcher
# entry and taskbar identity. The session lives in the normal Chrome profile,
# so you sign in once.
#
# No icon download here on purpose: Microsoft's PWA icon CDN paths 404, the OWA
# manifest.json returns an empty body to non-browser clients, and favicon.ico is
# a 32x32 .ico that looks terrible on a 2.8K panel. Ship the generic mail icon
# and let Chrome's own "Install page as app" replace this entry with a proper
# PWA (real icon, real app id) once you are signed in - see the summary.
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/outlook-pwa.desktop" << 'EOF'
[Desktop Entry]
Name=Outlook
Comment=Outlook web app in a dedicated Chrome window
Exec=/usr/bin/google-chrome-stable --app=https://outlook.office.com/mail/
Icon=internet-mail
Terminal=false
Type=Application
Categories=Network;Email;Office;
StartupNotify=true
StartupWMClass=chrome-outlook.office.com__mail_-Default
EOF
chmod +x "$HOME/.local/share/applications/outlook-pwa.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
ok "Outlook launcher created (work/school account). For a personal account, edit"
ok "   ~/.local/share/applications/outlook-pwa.desktop -> https://outlook.live.com/mail/"


# ==============================================================================
section "14 · GNOME 50 tweaks"
# ==============================================================================
# Note on gsettings: with no session bus these commands print a dconf warning
# and still exit 0, so they cannot abort the script under `set -e`. They just
# silently do not persist - which is why you want to run this inside a GNOME
# session, not over SSH.

# Double-click a Dash icon -> minimize the window (macOS muscle memory).
# Silently no-ops if Dash-to-Dock is not installed.
gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize-or-previews' \
  2>/dev/null || true

# OLED panel: dark mode is not only taste here. Black pixels are off pixels, so
# it cuts power draw and slows uneven wear. Delete this line if you want light.
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true

# --- NormCap hotkey: Super+Shift+T -------------------------------------------
# Wayland gives apps no global hotkey API, so a GNOME custom keybinding is the
# supported way to do this.
NC_KEY_BASE='org.gnome.settings-daemon.plugins.media-keys.custom-keybinding'
NC_PATH='/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/normcap/'

existing=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")
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


# ==============================================================================
section "15 · Firmware (informational only)"
# ==============================================================================
# ASUS consumer laptops are largely not published to LVFS, so expect this to
# find nothing. The real BIOS update path for a Vivobook is MyASUS on Windows,
# which is why it is listed as a prerequisite at the top of this file.
sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
fwupdmgr get-updates 2>/dev/null \
  || info "No LVFS firmware for this model - expected on an ASUS Vivobook. Flash BIOS from Windows/MyASUS."


# ==============================================================================
section "Setup complete"
# ==============================================================================
cat <<'SUMMARY'

Installed:
  • Dev:      VS Code · Git · Node (nvm + LTS) · NestJS · Turbo
  •           Docker CE + Compose plugin · Python 3 + pipx + auto-editor
  •           Ghostty terminal · PostgreSQL client
  • AI:       Claude Code · Codex CLI · pi coding agent
  •           Claude Desktop (apt, key-verified) · ChatGPT desktop (apt)
  • Media:    OBS Studio (standard, no NDI) + signed v4l2loopback virtual camera
  •           GIMP · Shotcut · ubuntu-restricted-extras · ffmpeg
  • Docs:     Okular (+ backends) · Acrobat Reader DC snap · poppler-utils
  • Comms:    Zoom · Telegram · Outlook PWA (Chrome app window)
  • Tools:    NormCap (OCR capture, Super+Shift+T) · Google Chrome · wl-clipboard
  • System:   NVIDIA (signed, no DKMS) + prime-select · nvtop · intel-gpu-tools
  •           mesa-utils · intel-microcode · linux-firmware · Extension Manager

Manual next steps:
  1. **Reboot.** The NVIDIA modules, v4l2loopback and your docker group all
     need it. (A logout alone only covers docker.)
  2. Open a new terminal before using node/npm - nvm loads from your shell rc,
     and a script cannot modify its parent shell's environment.
  3. Sign in:
       claude          -> /login           (Claude Code)
       codex           -> follow prompts    (Codex CLI)
       pi              -> follow prompts    (pi coding agent)
       Claude Desktop / ChatGPT desktop -> launch from Activities
  4. OBS: launch it, then Start Virtual Camera. It should appear in Zoom as
     "OBS Virtual Camera" on /dev/video9. Screen capture uses the PipeWire
     portal - pick "Screen Capture (PipeWire)", not the old X11 sources.
  5. Outlook: sign in, then Chrome menu -> Cast, save and share -> Install page
     as app. That registers a real PWA with Microsoft's own icon; afterwards
     delete the stopgap ~/.local/share/applications/outlook-pwa.desktop.
  6. (Optional) GNOME extensions via Extension Manager - Dash to Panel etc.

Verify after reboot:
  nvidia-smi                                  # driver loaded, signed, alive
  prime-select query                          # expect: on-demand
  ls -l /dev/video9                           # OBS virtual camera node
  mokutil --sb-state                          # Secure Boot still enabled
  # dGPU actually parked? (PCI address may differ - this finds it)
  cat /sys/bus/pci/devices/$(lspci -D | awk '/NVIDIA/{print $1; exit}')/power/runtime_status
  # expect "suspended" when idle. "active" while nothing uses the GPU means
  # something is holding it awake, which is what makes the fans spin.

Not installed here, deliberately:
  - NDI / DistroAV, Avahi, NDI firewall rules - this box runs plain OBS.
  - v4l2loopback-dkms - the signed in-archive module replaces it.
  - asusctl / supergfxctl - no Ubuntu packages, needs a Rust source build, and
    it targets ROG hardware. prime-select covers dGPU power on this Vivobook.

SUMMARY
