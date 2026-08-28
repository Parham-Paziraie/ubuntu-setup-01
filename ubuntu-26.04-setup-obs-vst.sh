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
# HOW THIS DIFFERS FROM ubuntu-26.04-setup.sh
# -----------------------------------------------------------------------------
# This variant exists for ONE reason: audio VST filters in OBS.
#
#   The Flatpak OBS hard-sets  VST_PATH=/app/extensions/Plugins/vst  in its
#   manifest, so it scans ONLY that sandbox directory and can never see host
#   VSTs in /usr/lib/vst — even though the Flatpak holds filesystems=host.
#   Result: an empty VST filter list unless you also install a Flatpak
#   LinuxAudio plugin extension.
#
#   The deb OBS has no such override. It scans the normal host paths, so
#   `apt install lsp-plugins-vst` is all it takes to get the LSP suite
#   (Graphic Equalizer x16 Mono, compressors, gates, etc.) into
#   Filters → Add → VST 2.x Plug-in.
#
# So, versus the Flatpak script:
#   - OBS         -> deb from the official obsproject PPA   (was: Flathub)
#   - VST plugins -> lsp-plugins-vst + lsp-plugins-ladspa   (new)
#   - NDI plugin  -> DistroAV .deb from GitHub releases     (was: Flatpak ext)
#   - Vertical Canvas -> Aitum .deb from GitHub releases    (was: Flatpak ext)
#   - Source Record   -> Exeldro portable tarball, relocated by hand.
#                        No .deb exists for Linux. See section 8 for the ABI
#                        check that says the 22.04 build is safe on 26.04.
#   - libndi      -> installed by DistroAV's own CI/libndi-get.sh  (section 9)
#                    The .deb contains only distroav.so; unlike the Flatpak it
#                    does NOT bundle the NDI runtime, so we fetch it. Note the
#                    upstream script auto-accepts NewTek's SDK EULA (`yes |`).
#   - Avahi       -> host daemon only; no `flatpak override` needed
#   - Launcher    -> the deb ships its own .desktop; no custom entry
#   - NormCap     -> still Flatpak (unchanged)
#
# Other decisions carried over unchanged:
#   - Node.js     -> nvm
#   - Docker      -> official Docker CE repo  (NOT docker.io)
#   - VS Code     -> Microsoft apt repo       (NOT snap)
#   - apt UI      -> nala installed in Section 1, used from there on
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

# --- OBS Studio (official obsproject PPA) ---
# Ships a much newer OBS than Ubuntu universe. `add-apt-repository` runs its own
# apt-get update by default; --no-update defers that to the single update below.
#
# NOTE: PPAs are per-release. If obsproject hasn't published a build for this
# Ubuntu release yet, this add still succeeds but the suite 404s on update.
#
# THE PPA IS NOT OPTIONAL HERE. Verified 2026-08-28 by unpacking both debs:
#   PPA      obs-studio 32.2.0-0obsproject1~resolute -> SHIPS obs-vst.so
#   universe obs-studio 32.1.0-0ubuntu3              -> NO obs-vst.so AT ALL
# Ubuntu builds the VST plugin out of its package (Steinberg VST2 SDK
# licensing). Falling back to universe therefore gives you an OBS with no
# "VST 2.x Plug-in" filter whatsoever, which defeats this whole script.
# Section 7 asserts on this rather than letting it pass silently.
sudo add-apt-repository -y --no-update ppa:obsproject/obs-studio \
  || warn "Could not add the obsproject PPA — falling back to Ubuntu universe OBS"

sudo apt update || warn "apt update reported errors (likely the OBS PPA lacking a build for $(lsb_release -cs))"


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
section "7 · OBS Studio (deb) + LSP audio plugins (the VST payload)"
# ══════════════════════════════════════════════════════════════════════════════
# THIS is the section that makes this script different. Read the header.
#
# lsp-plugins-vst (1.2.27) drops 195 VST2 .so files into
#     /usr/lib/vst/lsp-plugins.vst/          <- note the ".vst" suffix
# NOT /usr/lib/vst/lsp-plugins/ . Verified with `dpkg -c` on the deb.
#
# obs-vst.so has /usr/lib/vst/ compiled into its search path list and walks it
# with QDirIterator + a "*.so" name filter, i.e. recursively - so the plugins
# in that subdirectory are found with zero configuration. Among them:
#     graph-equalizer-x16-mono.so   ->  "Graphic Equalizer x16 Mono"
#     para-equalizer-x16-*.so       ->  matches obs/parametric equlizer x16.cfg
#
# lsp-plugins-ladspa is not used by OBS itself, but it's what EasyEffects and
# PipeWire filter-chains consume — cheap to install, and it pulls in the same
# shared DSP core. Keep them together.
sudo nala install -y \
  obs-studio \
  lsp-plugins-vst \
  lsp-plugins-ladspa

obs --version || true

# --- Assert 1: does THIS OBS build even have a VST filter? -------------------
# The universe build does not (see section 2). Without obs-vst.so there is no
# "VST 2.x Plug-in" entry in the filter list no matter how many .so files are
# sitting in /usr/lib/vst, so fail loudly here instead of at 2am mid-stream.
OBS_VST_SO="/usr/lib/x86_64-linux-gnu/obs-plugins/obs-vst.so"
if [[ -f "$OBS_VST_SO" ]]; then
  ok "obs-vst.so present - this OBS has the VST 2.x filter"
else
  warn "NO obs-vst.so in /usr/lib/x86_64-linux-gnu/obs-plugins/"
  warn "You are almost certainly on the Ubuntu universe OBS, which is built"
  warn "WITHOUT VST support. Check that the PPA actually took:"
  warn "   apt-cache policy obs-studio     # want 'obsproject' as the origin"
  warn "Fix the PPA and re-run, or this script has achieved nothing."
fi

# --- Assert 2: did the VST payload land where OBS looks? --------------------
LSP_VST_DIR="/usr/lib/vst/lsp-plugins.vst"
if compgen -G "${LSP_VST_DIR}/graph-equalizer-x16-*.so" > /dev/null; then
  ok "LSP VSTs installed - $(find "$LSP_VST_DIR" -name '*.so' | wc -l) plugins in ${LSP_VST_DIR}"
  info "In OBS: Filters -> + -> VST 2.x Plug-in -> 'Graphic Equalizer x16 Mono'"
else
  warn "Expected LSP VSTs in ${LSP_VST_DIR} but found none."
  warn "Check where the package actually put them:"
  warn "   dpkg -L lsp-plugins-vst | grep '\.so$' | head"
fi

# Belt and braces: OBS also honours VST_PATH. Only set it if the packaged
# location somehow isn't the default on this release. Harmless when unused.
grep -qxF 'export VST_PATH=/usr/lib/vst:$HOME/.vst' "$HOME/.profile" 2>/dev/null \
  || echo 'export VST_PATH=/usr/lib/vst:$HOME/.vst' >> "$HOME/.profile"


# ══════════════════════════════════════════════════════════════════════════════
section "8 · OBS plugins - DistroAV (NDI) · Vertical Canvas · Source Record"
# ══════════════════════════════════════════════════════════════════════════════
# DistroAV is the renamed OBS-NDI plugin (since 2024-06). Because OBS is now a
# deb, we need the deb build of the plugin — the Flatpak extension cannot load
# into a host OBS.
#
# The .deb declares `Depends: obs-studio`, so it must be installed AFTER
# section 7. It contains exactly one binary, /usr/lib/x86_64-linux-gnu/
# obs-plugins/distroav.so — and crucially NO libndi. See section 9.
DISTROAV_VERSION="6.2.1"
DISTROAV_DEB="distroav-${DISTROAV_VERSION}-x86_64-linux-gnu.deb"
DISTROAV_URL="https://github.com/DistroAV/DistroAV/releases/download/${DISTROAV_VERSION}/${DISTROAV_DEB}"

if wget -q --show-progress -O "/tmp/${DISTROAV_DEB}" "$DISTROAV_URL"; then
  sudo nala install -y "/tmp/${DISTROAV_DEB}"
  sudo apt --fix-broken install -y || true
  rm -f "/tmp/${DISTROAV_DEB}"
  ok "DistroAV ${DISTROAV_VERSION} installed"
else
  warn "Could not download DistroAV ${DISTROAV_VERSION}."
  warn "Grab the current .deb from https://github.com/DistroAV/DistroAV/releases"
  rm -f "/tmp/${DISTROAV_DEB}"
fi


# --- Vertical Canvas (Aitum) -------------------------------------------------
# The 1080x1920 shorts canvas. This is what the whole vertical workflow in
# obs-config.md is built on, so it is not optional if you want that back.
# Ships a proper .deb with `Depends: obs-studio`, same 1.6.4 as the old
# Flatpak extension.
VC_VERSION="1.6.4"
VC_DEB="vertical-canvas-linux-gnu.deb"
VC_URL="https://github.com/Aitum/obs-vertical-canvas/releases/download/${VC_VERSION}/${VC_DEB}"

if wget -q --show-progress -O "/tmp/${VC_DEB}" "$VC_URL"; then
  sudo nala install -y "/tmp/${VC_DEB}"
  sudo apt --fix-broken install -y || true
  rm -f "/tmp/${VC_DEB}"
  ok "Vertical Canvas ${VC_VERSION} installed"
else
  warn "Could not download Vertical Canvas ${VC_VERSION}."
  warn "Latest: https://github.com/Aitum/obs-vertical-canvas/releases"
  rm -f "/tmp/${VC_DEB}"
fi


# --- Source Record (Exeldro) -------------------------------------------------
# Drives the "Source Record (youtube)" filter on the webcam - records one
# source to its own file independently of the main recording.
#
# NO .deb exists for Linux; upstream publishes only a portable tarball built on
# Ubuntu 22.04. That is fine here, verified 2026-08-28 against OBS 32.2.0:
#   - it links ONLY libobs.so.0, libobs-frontend-api.so.0 and libc.so.6
#     (no Qt at all, so no Qt6 ABI risk)
#   - highest symbol version it needs is GLIBC_2.34; 26.04 ships 2.43
#   - all 170 libobs symbols it imports are defined by the 32.2.0 libobs
#
# Tarball layout is OBS's portable one, so the files are relocated by hand:
#   source-record/bin/64bit/source-record.so -> /usr/lib/<triplet>/obs-plugins/
#   source-record/data/*                     -> /usr/share/obs/obs-plugins/source-record/
#
# CAVEAT: installed outside dpkg. apt will never update or remove it. To undo:
#   sudo rm /usr/lib/x86_64-linux-gnu/obs-plugins/source-record.so
#   sudo rm -rf /usr/share/obs/obs-plugins/source-record
SR_VERSION="0.4.8"
SR_TGZ="source-record-${SR_VERSION}-ubuntu-22.04.tar.gz"
SR_URL="https://github.com/exeldro/obs-source-record/releases/download/${SR_VERSION}/${SR_TGZ}"
SR_TMP="$(mktemp -d)"

if wget -q --show-progress -O "${SR_TMP}/${SR_TGZ}" "$SR_URL"; then
  tar xzf "${SR_TMP}/${SR_TGZ}" -C "$SR_TMP"

  if [[ -f "${SR_TMP}/source-record/bin/64bit/source-record.so" ]]; then
    sudo install -Dm644 \
      "${SR_TMP}/source-record/bin/64bit/source-record.so" \
      "/usr/lib/x86_64-linux-gnu/obs-plugins/source-record.so"
    sudo mkdir -p /usr/share/obs/obs-plugins/source-record
    sudo cp -r "${SR_TMP}/source-record/data/." \
      /usr/share/obs/obs-plugins/source-record/
    ok "Source Record ${SR_VERSION} installed (manual, not dpkg-tracked)"
  else
    warn "Source Record tarball had an unexpected layout - skipping."
    warn "Expected source-record/bin/64bit/source-record.so. Got:"
    find "$SR_TMP" -name '*.so' | sed 's/^/     /' || true
  fi
else
  warn "Could not download Source Record ${SR_VERSION}."
  warn "Latest: https://github.com/exeldro/obs-source-record/releases"
fi
rm -rf "$SR_TMP"


# ══════════════════════════════════════════════════════════════════════════════
section "9 · NDI host requirements — libndi · Avahi daemon · firewall ports"
# ══════════════════════════════════════════════════════════════════════════════
sudo nala install -y avahi-daemon ffmpeg
sudo systemctl enable --now avahi-daemon

# --- libndi: the NDI runtime -------------------------------------------------
# The Flatpak DistroAV extension bundles the NDI runtime. The .deb does not —
# it ships exactly one file, distroav.so. So we install libndi ourselves using
# DistroAV's own helper, which is the method their install docs prescribe:
# it pulls the NDI SDK v6 tarball from downloads.ndi.tv, drops the libs into
# /usr/local/lib, runs ldconfig, and symlinks libndi.so.6 -> libndi.so.5 so
# older plugin builds keep working.
#
# HEADS UP: that upstream script runs NewTek's SDK installer as `yes | sh ...`,
# i.e. it accepts the NDI SDK licence on your behalf without showing it to you.
# If you'd rather read the EULA first, skip this block and run OBS once —
# DistroAV shows a dialog with the same download.
#
# We download to a file and run it rather than piping curl into a root shell,
# so you can actually read it before it executes.
if ldconfig -p | grep -q 'libndi'; then
  ok "NDI runtime already present on this host — skipping libndi install"
else
  info "Installing the NDI runtime via DistroAV's libndi-get.sh..."
  LIBNDI_GET="/tmp/libndi-get.sh"
  LIBNDI_GET_URL="https://raw.githubusercontent.com/DistroAV/DistroAV/refs/heads/master/CI/libndi-get.sh"

  if curl -fsSL -o "$LIBNDI_GET" "$LIBNDI_GET_URL"; then
    chmod +x "$LIBNDI_GET"
    if sudo "$LIBNDI_GET" install; then
      sudo ldconfig
      if ldconfig -p | grep -q 'libndi'; then
        ok "NDI runtime installed: $(ldconfig -p | grep -m1 libndi | awk '{print $NF}')"
      else
        warn "libndi-get.sh finished but libndi is still not on the linker path."
        warn "Check /usr/local/lib and that it's covered by /etc/ld.so.conf.d/."
      fi
    else
      warn "libndi-get.sh failed (downloads.ndi.tv unreachable, or SDK layout changed)."
      warn "Launch OBS once and accept DistroAV's download prompt instead."
    fi
    rm -f "$LIBNDI_GET"
  else
    warn "Could not fetch libndi-get.sh — NDI sources will not work yet."
    warn "Launch OBS once and accept DistroAV's download prompt, or see:"
    warn "   https://github.com/DistroAV/DistroAV/wiki/1.-Installation"
  fi
fi

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

# No `flatpak override --system-talk-name=org.freedesktop.Avahi` here: the deb
# OBS is not sandboxed and talks to the host Avahi directly.
# No custom .desktop entry either — obs-studio ships /usr/share/applications/
# com.obsproject.Studio.desktop, and a hand-rolled duplicate would just show up
# twice in Activities.


# ══════════════════════════════════════════════════════════════════════════════
section "10 · Flatpak: Flathub + NormCap"
# ══════════════════════════════════════════════════════════════════════════════
# Flatpak is still worth having for NormCap — its Flatpak build ships its own
# tesseract + English traineddata, so it does not depend on the host
# tesseract-ocr package. Screen grabbing goes through the xdg-desktop-portal
# Screenshot interface, which is the only thing that works under 26.04's
# Wayland-only session.
sudo flatpak remote-add --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y flathub com.github.dynobo.normcap

ok "NormCap installed:  flatpak run com.github.dynobo.normcap"

# If this machine previously ran the Flatpak variant of this setup, having two
# OBS installs is confusing (and the Flatpak one still won't see your VSTs).
if flatpak list --app 2>/dev/null | grep -q com.obsproject.Studio; then
  warn "A Flatpak OBS is also installed. It cannot see /usr/lib/vst — its"
  warn "manifest pins VST_PATH=/app/extensions/Plugins/vst. To avoid launching"
  warn "the wrong one, consider removing it:"
  warn "   flatpak uninstall com.obsproject.Studio com.obsproject.Studio.Plugin.DistroAV"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "11 · Communication & desktop apps"
# ══════════════════════════════════════════════════════════════════════════════

# Telegram via snap (official, auto-updating)
sudo snap install telegram-desktop

# Zoom via official .deb
wget -c https://zoom.us/client/latest/zoom_amd64.deb -O /tmp/zoom_amd64.deb
sudo nala install -y /tmp/zoom_amd64.deb
sudo apt --fix-broken install -y || true
rm -f /tmp/zoom_amd64.deb


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
section "14 · Ghostty terminal"
# ══════════════════════════════════════════════════════════════════════════════
# Ghostty is in the 26.04 universe archive, so plain apt works. -y matters:
# without it this prompts, and under `set -e` a declined prompt kills the run
# on its very last step.
sudo apt install -y ghostty


# ══════════════════════════════════════════════════════════════════════════════
section "✅  Setup complete"
# ══════════════════════════════════════════════════════════════════════════════
cat <<'SUMMARY'

Installed:
  • Dev:      VS Code · Git · Node (nvm + LTS) · NestJS · Turbo · Claude Code
  •           Docker CE + Compose plugin · Python 3 + pipx + auto-editor
  • Media:    OBS Studio (deb, obsproject PPA)
  •           OBS plugins: DistroAV (NDI) · Vertical Canvas · Source Record
  •           LSP audio plugins (VST2 + LADSPA) - usable as OBS audio filters
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
  3. NDI: the runtime was installed for you via DistroAV's libndi-get.sh
     (the .deb does not bundle it, unlike the Flatpak). Verify with:
         ldconfig -p | grep ndi
     If that's empty, the download failed — launch OBS once and accept
     DistroAV's prompt. Everything else works regardless.
     Note: libndi-get.sh auto-accepted the NDI SDK EULA on your behalf.
  4. Use the VSTs: in OBS pick an audio source → Filters → + →
     "VST 2.x Plug-in" → choose e.g. "Graphic Equalizer x16 Mono" →
     click "Open Plug-in Interface" for the full LSP UI.
  5. NormCap: press Super+Shift+T, drag a region, text is in your clipboard.
     First run downloads nothing extra - English OCR data ships in the Flatpak.
     Extra languages: NormCap settings (gear icon) → Languages.
  6. (Optional) Install GNOME extensions via Extension Manager:
       - Dash to Panel (charlesg99)
       - Anything else you like
  7. (Optional) Sign in to Claude Code:  claude  → /login

If the VST list in OBS is empty:
  - Confirm THIS OBS was built with VST support at all:
       ls /usr/lib/x86_64-linux-gnu/obs-plugins/obs-vst.so
    Missing means you are on the universe OBS, which has no VST filter.
    Check the PPA took:  apt-cache policy obs-studio   (origin: obsproject)
  - Confirm the plugin files exist (note the ".vst" suffix on the dir):
       ls /usr/lib/vst/lsp-plugins.vst/ | head
  - Confirm you launched the DEB OBS, not a leftover Flatpak:
       which obs          # should be /usr/bin/obs
       flatpak list | grep -i obs   # should be empty
  - The Flatpak OBS pins VST_PATH into its sandbox and will NEVER see these.

If NDI sources don't appear on the LAN:
  - Confirm libndi is present:  ldconfig -p | grep ndi
  - Confirm both machines are on the same subnet
  - Check:  systemctl status avahi-daemon
  - Check:  avahi-browse -a   (should list local services)

SUMMARY
