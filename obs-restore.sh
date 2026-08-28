#!/usr/bin/env bash
# =============================================================================
# OBS Studio - rebuild the setup captured in obs-config.md
# Machine of record: x13-ThinkPad-X13-Yoga-Gen-4 · Ubuntu 26.04
# Author: Parham Paziraie
# =============================================================================
# Reinstalls OBS + the three plugins that were in use, reapplies the host-side
# prerequisites, and optionally restores the config backup taken 2026-08-28.
#
# Usage:
#   ./obs-restore.sh                                   # packages + host prereqs only
#   ./obs-restore.sh --restore-config <backup.tar.gz>  # ...and restore scenes/profile
#   ./obs-restore.sh --no-ndi                          # skip DistroAV + Avahi entirely
#   ./obs-restore.sh --deb --restore-config <tarball>  # config only, for a DEB OBS
#
# --deb MATTERS. The two OBS packagings read config from different places:
#   Flatpak : ~/.var/app/com.obsproject.Studio/config/obs-studio
#   deb     : ~/.config/obs-studio
# The backup was taken from a Flatpak install, so restoring it onto a deb OBS
# needs the tree relocated - that is all --deb does. It installs nothing,
# because ubuntu-26.04-setup-obs-vst.sh already handles the deb packages.
#
# Decisions baked in:
#   - ALL FOUR flatpaks go in the SYSTEM scope. The original install had OBS and
#     DistroAV system-wide but SourceRecord and VerticalCanvas --user. Flatpak
#     does resolve extensions across scopes, so it worked, but updates and
#     uninstalls then have to be done twice and orphaned plugins are easy to
#     leave behind. One scope, one command.
#   - Avahi override is applied ONLY with NDI. It is what makes DistroAV able to
#     discover sources at all since OBS 32, and it is dead weight without it.
#   - Config restore is opt-in. A restored profile carries a live YouTube OAuth
#     refresh token; see the Secrets section of obs-config.md before using it.
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

if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}Do not run this script with sudo. It calls sudo itself where needed.${RESET}"
  exit 1
fi

# ── Arguments ────────────────────────────────────────────────────────────────
WITH_NDI=true
DEB_MODE=false
RESTORE_TARBALL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ndi)         WITH_NDI=false; shift ;;
    --deb)            DEB_MODE=true; shift ;;
    --restore-config) RESTORE_TARBALL="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    *) echo -e "${RED}Unknown argument: $1${RESET}"; exit 1 ;;
  esac
done

if [[ -n "$RESTORE_TARBALL" && ! -f "$RESTORE_TARBALL" ]]; then
  echo -e "${RED}Backup not found: $RESTORE_TARBALL${RESET}"; exit 1
fi

if $DEB_MODE && [[ -z "$RESTORE_TARBALL" ]]; then
  echo -e "${RED}--deb only restores config, so it needs --restore-config <tarball>.${RESET}"
  echo -e "${RED}For the deb packages themselves, run ubuntu-26.04-setup-obs-vst.sh.${RESET}"
  exit 1
fi

OBS_DATA="$HOME/.var/app/com.obsproject.Studio"
# Where obs-studio/ finally has to live for this packaging:
if $DEB_MODE; then
  OBS_CONFIG_PARENT="$HOME/.config"
else
  OBS_CONFIG_PARENT="$OBS_DATA/config"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "1 · Flatpak remote"
# ══════════════════════════════════════════════════════════════════════════════
if $DEB_MODE; then
  info "--deb: skipping Flatpak remote (deb OBS comes from the apt PPA)"
else
  sudo flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
  ok "flathub present (system scope)"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "2 · OBS Studio + plugins"
# ══════════════════════════════════════════════════════════════════════════════
if $DEB_MODE; then
  info "--deb: skipping Flatpak OBS + plugins."
  info "       Those come from ubuntu-26.04-setup-obs-vst.sh sections 7-8."
else
sudo flatpak install -y flathub com.obsproject.Studio

# Source Record  - per-source recording. Used by the "Source Record (youtube)"
#                  filter on the webcam, which records the cam to its own file
#                  independently of the main recording.
sudo flatpak install -y flathub com.obsproject.Studio.Plugin.SourceRecord

# Vertical Canvas (Aitum) - the 1080x1920 shorts canvas. This is the plugin the
#                  whole vertical workflow depends on.
sudo flatpak install -y flathub com.obsproject.Studio.Plugin.VerticalCanvas

if $WITH_NDI; then
  # DistroAV is the renamed OBS-NDI plugin (since 2024-06) and bundles libndi,
  # so there is no manual SDK install. The old com.obsproject.Studio.Plugin.NDI
  # is abandoned - having it loaded makes OBS crash on the NDI source.
  sudo flatpak install -y flathub com.obsproject.Studio.Plugin.DistroAV
  sudo flatpak uninstall -y com.obsproject.Studio.Plugin.NDI 2>/dev/null || true
  ok "OBS + SourceRecord + VerticalCanvas + DistroAV installed"
else
  info "Skipping DistroAV (--no-ndi)"
  ok "OBS + SourceRecord + VerticalCanvas installed"
fi
fi   # end: not --deb


# ══════════════════════════════════════════════════════════════════════════════
section "3 · NDI host prerequisites"
# ══════════════════════════════════════════════════════════════════════════════
if $WITH_NDI; then
  if $DEB_MODE; then
    # No override needed: a deb OBS is not sandboxed and reaches the host
    # Avahi directly. Only the daemon itself matters.
    info "--deb: no flatpak override needed (deb OBS is not sandboxed)"
  else
    # CRITICAL: without this the sandbox cannot reach Avahi and DistroAV discovers
    # exactly zero NDI sources, with no error to tell you why.
    sudo flatpak override com.obsproject.Studio \
      --system-talk-name=org.freedesktop.Avahi
    ok "Avahi flatpak override applied"
  fi

  # Either way the host needs the mDNS daemon running.
  sudo apt install -y avahi-daemon
  sudo systemctl enable --now avahi-daemon
  ok "avahi-daemon enabled"
else
  info "Skipping Avahi override and avahi-daemon (--no-ndi)"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "4 · Config restore"
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$RESTORE_TARBALL" ]]; then
  # The backup tarball is always in the Flatpak's layout, i.e. it contains
  #     config/obs-studio/...   plus config/pulse/ and data/
  # Only config/obs-studio is worth restoring - it holds the scenes, profile
  # and plugin settings. The pulse cookie and the empty data/ dir are per
  # install and are deliberately left alone so a fresh install keeps its own.
  #
  # Where obs-studio/ has to end up depends on the packaging, which is the
  # entire reason --deb exists. See the header.
  TARGET="$OBS_CONFIG_PARENT/obs-studio"

  if [[ -d "$TARGET" ]]; then
    STAMP="$(date +%Y%m%d-%H%M%S)"
    warn "Existing config at $TARGET"
    warn "Moving it aside to obs-studio.pre-restore-$STAMP"
    mv "$TARGET" "${TARGET}.pre-restore-$STAMP"
  fi

  mkdir -p "$OBS_CONFIG_PARENT"
  EXTRACT_TMP="$(mktemp -d)"
  tar xzf "$RESTORE_TARBALL" -C "$EXTRACT_TMP"

  if [[ ! -d "$EXTRACT_TMP/config/obs-studio" ]]; then
    warn "Backup has no config/obs-studio inside it - nothing restored."
    warn "Contents:"
    tar tzf "$RESTORE_TARBALL" | head -5 | sed 's/^/     /'
    rm -rf "$EXTRACT_TMP"
    exit 1
  fi

  mv "$EXTRACT_TMP/config/obs-studio" "$TARGET"
  rm -rf "$EXTRACT_TMP"
  ok "Config restored to $TARGET"

  if $DEB_MODE; then
    # Source Record is installed outside dpkg by the setup script. If it is
    # missing, OBS silently drops the "Source Record (youtube)" filter from
    # the webcam when it loads the restored scene collection.
    if [[ ! -f /usr/lib/x86_64-linux-gnu/obs-plugins/source-record.so ]]; then
      warn "source-record.so is not installed. The restored scene collection"
      warn "references a source_record_filter, which OBS will drop on load."
      warn "Run section 8 of ubuntu-26.04-setup-obs-vst.sh first."
    fi
    if [[ ! -f /usr/lib/x86_64-linux-gnu/obs-plugins/vertical-canvas.so ]]; then
      warn "vertical-canvas.so is not installed - the 1080x1920 canvas and"
      warn "its two Vertical scenes will not come back. Same fix as above."
    fi
  fi

  warn "The restored profile carries a live YouTube OAuth refresh token."
  warn "Revoke it at https://myaccount.google.com/permissions and re-link in"
  warn "Settings > Stream if you do not want to carry it forward."

  # The VAAPI render node is hardcoded in the recording encoder and in the
  # Source Record filter. On this machine it is the Intel iGPU at 00:02.0.
  VAAPI_NODE="/dev/dri/by-path/pci-0000:00:02.0-render"
  if [[ ! -e "$VAAPI_NODE" ]]; then
    warn "VAAPI node $VAAPI_NODE does not exist on this machine."
    warn "Fix the device in Settings > Output > Recording AND in the"
    warn "'Source Record (youtube)' filter, or recording will fail. Available:"
    ls /dev/dri/by-path/ 2>/dev/null | sed 's/^/     /' || true
  else
    ok "VAAPI render node present: $VAAPI_NODE"
  fi
else
  info "No --restore-config given. OBS starts clean."
  info "Rebuild scenes by hand from section 4 of obs-config.md."
fi


# ══════════════════════════════════════════════════════════════════════════════
section "5 · Desktop launcher"
# ══════════════════════════════════════════════════════════════════════════════
if $DEB_MODE; then
  # The obs-studio deb ships /usr/share/applications/com.obsproject.Studio.desktop.
  # A hand-rolled duplicate would just show up twice in Activities.
  info "--deb: using the launcher shipped by the obs-studio package"
elif $WITH_NDI; then
  mkdir -p "$HOME/.local/share/applications"
  cat > "$HOME/.local/share/applications/obs-studio-ndi.desktop" << 'EOF'
[Desktop Entry]
Name=OBS Studio (with NDI)
Comment=OBS Studio with DistroAV (NDI) - Avahi override already applied
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
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  ok "Launcher 'OBS Studio (with NDI)' created"
else
  # Nothing to add - the Flatpak ships its own com.obsproject.Studio.desktop.
  info "Using the stock OBS launcher"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "Done"
# ══════════════════════════════════════════════════════════════════════════════
if $DEB_MODE; then LAUNCH_CMD="obs                              # /usr/bin/obs"
else                LAUNCH_CMD="flatpak run com.obsproject.Studio"; fi

cat << EOF
  Launch:   $LAUNCH_CMD

  Manual steps that no restore can cover:
    1. Screen Capture (PipeWire) will ask you to re-pick the display or window.
       The portal restore token does not survive a reinstall.
    2. If you revoked the YouTube token, re-link under Settings > Stream.
    3. Check Settings > Output > Recording still points at a VAAPI device that
       exists on this machine.

  Full reference: obs-config.md
EOF
