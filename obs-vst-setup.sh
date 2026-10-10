#!/usr/bin/env bash
# =============================================================================
# OBS Studio + audio VST rig for Ubuntu 26.04 LTS "Resolute Raccoon"
# Author: Parham Paziraie
# =============================================================================
# Usage:
#   ./obs-vst-setup.sh
#
# Standalone by design. It installs its own prerequisites and uses plain apt,
# so it runs correctly on a bare 26.04 install. ubuntu-26.04-setup-obs-vst.sh
# also calls it, so the OBS logic lives in exactly one place.
#
# WHY THIS IS NOT JUST THREE COMMANDS
# -----------------------------------------------------------------------------
# The OBS install really is three commands:
#     sudo add-apt-repository ppa:obsproject/obs-studio
#     sudo apt update
#     sudo apt install obs-studio
# Everything else here is the part apt cannot do for you:
#
#   1. The PPA is mandatory, not a preference. Ubuntu builds the VST plugin
#      OUT of its own package (Steinberg VST2 SDK licensing):
#          PPA      obs-studio 32.2.0-0obsproject1~resolute -> SHIPS obs-vst.so
#          universe obs-studio 32.1.0-0ubuntu3              -> NO obs-vst.so
#      Both suites are called "resolute", so a plain `apt install obs-studio`
#      with a dead PPA quietly hands you an OBS with no "VST 2.x Plug-in"
#      filter at all. Section 2 refuses to continue in that case.
#
#   2. The VST payload itself (lsp-plugins-vst) is a separate package.
#      Without it you get the filter with nothing to put in it.
#
#   3. The VST editor window SEGFAULTS on a stock 26.04 desktop. Section 4.
#
#   4. Three OBS plugins exist in NO apt repo and are fetched from GitHub,
#      and two of them will not install on 26.04 as shipped. Section 5.
#
#   5. The NDI runtime (libndi) is not bundled by DistroAV's .deb, unlike its
#      Flatpak. Without it NDI sources silently never appear.
#
# WHY DEB AND NOT FLATPAK
# -----------------------------------------------------------------------------
# The Flatpak OBS hard-sets VST_PATH=/app/extensions/Plugins/vst in its
# manifest, so it scans ONLY that sandbox directory and can never see host VSTs
# in /usr/lib/vst, even with filesystems=host. The deb has no such override and
# scans the normal host paths, so `apt install lsp-plugins-vst` is all it takes.
#
# RE-RUNNING
# -----------------------------------------------------------------------------
# Idempotent by design; re-running is the supported repair path. Failures are
# collected in FAILURES, replayed at the end, and make the script exit 1.
#
# NEVER pipe a producer into `grep -q` in this script. `grep -q` exits on its
# first match, closing the pipe and killing a still-writing producer with
# SIGPIPE (141); under `set -o pipefail` the pipeline then reports 141 even
# though grep matched, so the check answers "no" precisely when the truth is
# "yes". Capture to a variable and match that instead.
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

FAILURES=()
fail()    { echo -e "${RED}✗  $1${RESET}"; FAILURES+=("$1"); }

# See the SIGPIPE note in the header. Neither helper involves a pipeline status.
contains()  { [[ "$1" == *"$2"* ]]; }              # contains "$haystack" needle
ldso_has()  { grep -q "$1" < <(ldconfig -p); }     # ldso_has libndi

if [[ $EUID -eq 0 ]]; then
  echo -e "${RED}Do not run this script with sudo. It calls sudo itself where needed.${RESET}"
  exit 1
fi

# Scratch space for every transient download. Removed on exit, success or
# failure, so an aborted run never leaves a half-written .deb behind.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

OBS_PLUGIN_DIR="/usr/lib/x86_64-linux-gnu/obs-plugins"
LSP_VST_DIR="/usr/lib/vst/lsp-plugins.vst"
RELEASE_CODENAME="$(lsb_release -cs)"

# Section 4 makes OBS launch under XWayland so the VST editor can embed itself.
# Set OBS_VST_FORCE_XCB=0 to skip that (and keep a crashing VST editor).
FORCE_XCB="${OBS_VST_FORCE_XCB:-1}"


# ══════════════════════════════════════════════════════════════════════════════
section "1 · Prerequisites"
# ══════════════════════════════════════════════════════════════════════════════
# Standalone-safe: these are also installed by the base setup script, where this
# is a no-op costing a second or two. dpkg-dev is here for section 5's repack.
sudo apt update
sudo apt install -y \
  wget curl ca-certificates gnupg lsb-release \
  software-properties-common dpkg-dev


# ══════════════════════════════════════════════════════════════════════════════
section "2 · obsproject PPA (hard requirement)"
# ══════════════════════════════════════════════════════════════════════════════
# --no-update defers add-apt-repository's own apt-get update to the single one
# below.
if ! sudo add-apt-repository -y --no-update ppa:obsproject/obs-studio; then
  echo -e "${RED}Could not add ppa:obsproject/obs-studio.${RESET}"
  echo "There is no useful fallback - see the header. Fix network/launchpad"
  echo "access and re-run; this script is cheap to repeat."
  exit 1
fi

sudo apt update || warn "apt update reported errors - verifying the OBS PPA below"

# Do NOT trust the fact that add-apt-repository succeeded. PPAs are per-release:
# it will happily write a sources entry for a suite that does not exist yet, and
# apt then 404s that one suite and carries on. Ask apt where obs-studio would
# actually come from.
OBS_POLICY="$(apt-cache policy obs-studio 2>/dev/null || true)"

if ! contains "$OBS_POLICY" 'obsproject'; then
  echo -e "${RED}The obsproject PPA has no obs-studio build for ${RELEASE_CODENAME}.${RESET}"
  echo
  echo "$OBS_POLICY"
  echo
  echo "Continuing would install the universe OBS, which has NO 'VST 2.x Plug-in'"
  echo "filter at all, so every later section of this script would be pointless."
  echo "Stopping here instead. Check for a build at:"
  echo "  https://launchpad.net/~obsproject/+archive/ubuntu/obs-studio"
  exit 1
fi

OBS_CANDIDATE="$(awk '/Candidate:/{print $2}' <<<"$OBS_POLICY")"
ok "obsproject PPA live for ${RELEASE_CODENAME} - obs-studio candidate ${OBS_CANDIDATE}"


# ══════════════════════════════════════════════════════════════════════════════
section "3 · OBS Studio (deb) + LSP audio plugins (the VST payload)"
# ══════════════════════════════════════════════════════════════════════════════
# lsp-plugins-vst (1.2.27) drops ~195 VST2 .so files into
#     /usr/lib/vst/lsp-plugins.vst/          <- note the ".vst" suffix
# NOT /usr/lib/vst/lsp-plugins/ . Verified with `dpkg -c` on the deb.
#
# Each of those files is a ~19K stub that dlopens the real 14M engine,
# liblsp-plugins-vst2.so, from the same directory. The engine exports no
# VSTPluginMain, so OBS's recursive "*.so" scan correctly skips it rather than
# listing it as a bogus plugin.
#
# obs-vst.so has /usr/lib/vst/ compiled into its search path list and walks it
# with QDirIterator + a "*.so" name filter, i.e. recursively, so the plugins in
# that subdirectory are found with zero configuration. Among them:
#     graph-equalizer-x16-mono.so   ->  "Graphic Equalizer x16 Mono"
#     para-equalizer-x16-*.so       ->  matches obs/parametric equlizer x16.cfg
#
# lsp-plugins-ladspa is not used by OBS itself, but it is what EasyEffects and
# PipeWire filter-chains consume, and it pulls in the same shared DSP core.
sudo apt install -y \
  obs-studio \
  lsp-plugins-vst \
  lsp-plugins-ladspa

obs --version || true

# --- Assert: does THIS OBS build have a VST filter? --------------------------
# This is the check that actually matters. The installed-version string is only
# a proxy for it, so we test the file itself and report the version for context.
OBS_INSTALLED_VER="$(dpkg-query -W -f='${Version}' obs-studio 2>/dev/null || echo '')"

if [[ -f "${OBS_PLUGIN_DIR}/obs-vst.so" ]]; then
  ok "obs-vst.so present - this OBS has the VST 2.x filter (${OBS_INSTALLED_VER})"
else
  fail "No obs-vst.so in ${OBS_PLUGIN_DIR} - this OBS (${OBS_INSTALLED_VER:-not installed}) has no VST 2.x filter."
  warn "You are almost certainly on the universe build. Pin by VERSION, not by"
  warn "suite, since the PPA and the Ubuntu archive both call this release"
  warn "'${RELEASE_CODENAME}':"
  warn "   apt-cache policy obs-studio"
  warn "   sudo apt install -y --allow-downgrades obs-studio=<the ~obsproject version>"
fi

# --- Assert: did the VST payload land where OBS looks? ----------------------
if compgen -G "${LSP_VST_DIR}/graph-equalizer-x16-*.so" > /dev/null; then
  ok "LSP VSTs installed - $(find "$LSP_VST_DIR" -name '*.so' | wc -l) plugins in ${LSP_VST_DIR}"
  info "In OBS: Filters -> + -> VST 2.x Plug-in -> 'Graphic Equalizer x16 Mono'"
else
  fail "Expected LSP VSTs in ${LSP_VST_DIR} but found none."
  warn "Check where the package actually put them:"
  warn "   dpkg -L lsp-plugins-vst | grep '\.so$' | head"
fi

# Belt and braces: OBS also honours VST_PATH, though the packaged location above
# is already on its default search list.
#
# This goes in ~/.config/environment.d/ and NOT ~/.profile. 26.04 is Wayland
# only, and GDM starts gnome-session directly without a login shell, so
# ~/.profile is never sourced for anything launched from Activities - the OBS
# you actually use. systemd's user session does read environment.d/*.conf, so
# this is the placement that has an effect on a Wayland desktop.
# NOTE: environment.d does no shell expansion; the path is written literally.
VST_ENV_DIR="$HOME/.config/environment.d"
VST_ENV_FILE="$VST_ENV_DIR/vst-path.conf"
mkdir -p "$VST_ENV_DIR"
if [[ -f "$VST_ENV_FILE" ]] && contains "$(cat "$VST_ENV_FILE")" 'VST_PATH='; then
  ok "VST_PATH already set in ${VST_ENV_FILE}"
else
  printf 'VST_PATH=/usr/lib/vst:%s/.vst\n' "$HOME" > "$VST_ENV_FILE"
  ok "VST_PATH written to ${VST_ENV_FILE} (takes effect next login)"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "4 · Make the VST editor window survive being opened"
# ══════════════════════════════════════════════════════════════════════════════
# THE BUG THIS FIXES
# -----------------------------------------------------------------------------
# On a stock 26.04 desktop, picking any LSP plugin in the "VST 2.x Plug-in"
# filter kills OBS instantly with SIGSEGV. The plugin LIST populates fine, which
# is what makes this look like a plugin problem when it is not - listing is just
# a directory scan, no UI involved.
#
# Evidence from a real crash on this machine:
#   ~/.config/obs-studio/logs/*.txt
#       Platform: Wayland   /   Using EGL/Wayland
#       User selected new VST plugin: '.../para-equalizer-x16-mono.so'
#       <log ends; next launch logs "Crash or unclean shutdown detected">
#   /var/crash/_usr_bin_obs.1000.crash
#       Signal: 11 / SignalName: SIGSEGV
#       ProcMaps shows qt6/plugins/platforms/libqwayland.so loaded
#   journalctl --user (OBS stderr), 2s after the selection:
#       X Error of failed request:  BadWindow (invalid Window parameter)
#         Major opcode of failed request:  3 (X_GetWindowAttributes)
#   gdb on the core: main thread inside exit(status=1); the faulting thread's
#       PC sits in the unmapped hole where liblsp-plugins-vst2.so used to be
#   nm -D /usr/lib/vst/lsp-plugins.vst/liblsp-plugins-vst2.so
#       U XOpenDisplay   U XCreateWindow   U XReparentWindow
#
# MECHANISM
# -----------------------------------------------------------------------------
# The VST2 editor protocol is X11-only by construction: the host creates a
# window, hands the plugin its NATIVE HANDLE via effEditOpen, and the plugin
# calls XReparentWindow() to graft its own X11 window inside it. LSP's engine
# does exactly that - the three X11 symbols above are the whole story.
#
# When OBS runs on the Qt "wayland" platform plugin, QWidget::winId() returns a
# Wayland surface pointer, not an X11 Window XID. OBS passes it to LSP anyway,
# LSP queries it as an XID on its own XWayland connection, gets BadWindow, and
# Xlib's DEFAULT error handler calls exit(1). The SIGSEGV is collateral: exit()
# unloads the LSP engine while LSP's UI thread is still executing inside it.
#
# Reproduced outside OBS with a ~100-line VST2 host calling effEditOpen on
# graph-equalizer-x16-stereo.so: a heap pointer as parent -> the identical
# BadWindow + exit 1; a real X11 window as parent -> editor opens and closes
# cleanly. So forcing xcb is the complete fix, not a workaround on top of one.
#
# THE FIX
# -----------------------------------------------------------------------------
# Run OBS on Qt's "xcb" platform so it is an XWayland client and winId() is a
# real XID again. This is a launcher change, not a system-wide one: setting
# QT_QPA_PLATFORM globally would drag every other Qt app onto XWayland too.
#
# A ~/.local/share/applications entry of the same name shadows the packaged
# /usr/share/applications one, so this survives obs-studio upgrades instead of
# being reverted by them.
#
# The desktop entry alone is NOT enough. OBS also gets started as plain `obs`
# by a terminal and by Ubuntu's crash dialog ("Relaunch" runs it from
# update-notifier-crash.service), and both of those land back on Wayland and
# crash again on the next editor open. So an `obs` shim also goes in
# ~/.local/bin, which is first on PATH for gnome-shell, the systemd user
# session and login shells alike. The desktop entry stays because it does not
# depend on PATH at all.
#
# Screen capture is unaffected: OBS captures through the xdg-desktop-portal /
# PipeWire path (linux-pipewire.so), which is independent of the Qt platform.
# To undo:  rm ~/.local/share/applications/com.obsproject.Studio.desktop ~/.local/bin/obs
OBS_DESKTOP_SRC="/usr/share/applications/com.obsproject.Studio.desktop"
OBS_DESKTOP_DST="$HOME/.local/share/applications/com.obsproject.Studio.desktop"
OBS_XCB_SHIM="$HOME/.local/bin/obs"

if [[ "$FORCE_XCB" != "1" ]]; then
  warn "OBS_VST_FORCE_XCB=0 - leaving OBS on Wayland."
  warn "The VST editor will SIGSEGV the moment you select a plugin. See section 4."
elif [[ ! -f "$OBS_DESKTOP_SRC" ]]; then
  fail "Cannot apply the VST editor fix: ${OBS_DESKTOP_SRC} not found"
else
  mkdir -p "$(dirname "$OBS_DESKTOP_DST")" "$(dirname "$OBS_XCB_SHIM")"

  # `env` rather than a shell wrapper keeps this a valid Exec= per the desktop
  # entry spec (no shell metacharacters, still a plain argv).
  # -E and a '#' delimiter on purpose: with sed's default '|' delimiter, a '\|'
  # inside the pattern is an escaped DELIMITER (a literal pipe), not alternation,
  # so the rewrite silently matched nothing and left Exec=obs untouched.
  # Matches "Exec=obs", "Exec=obs %U", "Exec=obs --flags"; never "Exec=obsidian".
  sed -E 's#^Exec=obs([[:space:]].*)?$#Exec=env QT_QPA_PLATFORM=xcb obs\1#' \
    "$OBS_DESKTOP_SRC" > "$OBS_DESKTOP_DST"

  if contains "$(cat "$OBS_DESKTOP_DST")" 'QT_QPA_PLATFORM=xcb'; then
    ok "OBS desktop entry overridden to launch under XWayland (VST editor fix)"
  else
    fail "Wrote ${OBS_DESKTOP_DST} but no Exec= line was rewritten"
    warn "Check the packaged entry's Exec= line: grep '^Exec=' ${OBS_DESKTOP_SRC}"
  fi

  update-desktop-database "$(dirname "$OBS_DESKTOP_DST")" 2>/dev/null || true

  # Shadows /usr/bin/obs for every PATH-based launch (terminal, crash
  # relauncher). The absolute /usr/bin/obs is what stops it exec'ing itself.
  cat > "$OBS_XCB_SHIM" <<'SHIM'
#!/usr/bin/env bash
# OBS on Qt's xcb platform (XWayland), so VST 2.x editor windows get a real X11
# parent window instead of a Wayland pointer that kills OBS with BadWindow.
# Installed by obs-vst-setup.sh - see its section 4.
exec env QT_QPA_PLATFORM=xcb /usr/bin/obs "$@"
SHIM
  chmod +x "$OBS_XCB_SHIM"

  # Only worth anything if it actually wins the PATH lookup.
  if [[ "$(PATH="$(systemctl --user show-environment 2>/dev/null \
                   | sed -n 's/^PATH=//p')" command -v obs)" == "$OBS_XCB_SHIM" ]]; then
    ok "obs shim installed and first on the desktop session PATH: ${OBS_XCB_SHIM}"
  else
    warn "obs shim installed at ${OBS_XCB_SHIM}, but ~/.local/bin is not yet first"
    warn "on the session PATH. Log out and back in (Ubuntu's ~/.profile adds it"
    warn "once the directory exists). Until then only Activities launches are fixed."
  fi
fi


# ══════════════════════════════════════════════════════════════════════════════
section "5 · OBS plugins - DistroAV (NDI) · Vertical Canvas · Source Record"
# ══════════════════════════════════════════════════════════════════════════════
# THE BUG THIS FIXES
# -----------------------------------------------------------------------------
# DistroAV and Vertical Canvas ship .debs built on 24.04/25.04, where the 64-bit
# time_t transition had renamed the Qt runtime packages with a "t64" suffix.
# 26.04 renamed two of them BACK, so those builds now depend on package names
# that no longer exist anywhere:
#
#     libqt6gui6t64      -> gone;  libqt6gui6      6.10.2+dfsg-7   is the name
#     libqt6widgets6t64  -> gone;  libqt6widgets6  6.10.2+dfsg-7   is the name
#     libqt6core6t64     -> still exists, unchanged
#     libcurl4t64        -> still exists, unchanged
#
# apt therefore refuses both packages outright:
#     distroav : Depends: libqt6gui6t64 (>= 6.1.2) but it is not installable
#
# This is a metadata problem only. Both binaries link the real sonames
# (libQt6Gui.so.6, libQt6Widgets.so.6, libobs.so.30, libobs-frontend-api.so.30)
# and both resolve completely against 26.04 + OBS 32.2.0 - verified with
# `ldd -r`: zero missing libraries, zero undefined symbols.
#
# THE FIX
# -----------------------------------------------------------------------------
# Rewrite the stale names in the .deb's control file and repack, so apt sees
# dependencies that are both satisfiable AND true. This is strictly better than
# the usual `dpkg -i --force-depends`, which installs the package while leaving
# apt in a permanently unmet-dependency state that breaks later upgrades.
#
# The rewrite is conservative and self-limiting: a "<name>t64" dependency is
# renamed to "<name>" ONLY when <name>t64 is uninstallable on this release and
# <name> is installable. Version constraints are preserved untouched. When
# upstream rebuilds against 26.04, nothing matches and this becomes a no-op.

# Does apt have a real candidate for this package on this release?
pkg_installable() {
  local c
  c="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$c" && "$c" != "(none)" ]]
}

# Rewrites a Depends line. Returns through globals rather than stdout on
# purpose: a $(...) call would run this in a subshell and DEPS_REMAPPED would be
# lost, leaving the caller's log line with an empty list of what it changed.
#   REMAPPED_DEPS  - the rewritten Depends line
#   DEPS_REMAPPED  - human-readable "old -> new" summary of what changed
REMAPPED_DEPS=""
DEPS_REMAPPED=""
remap_t64_deps() {
  local depline="$1" tok name rest newname joined="" oldifs
  local -a out=() toks=()
  REMAPPED_DEPS=""; DEPS_REMAPPED=""

  oldifs="$IFS"; IFS=','; read -ra toks <<< "$depline"; IFS="$oldifs"

  for tok in "${toks[@]}"; do
    tok="${tok#"${tok%%[![:space:]]*}"}"          # ltrim
    tok="${tok%"${tok##*[![:space:]]}"}"          # rtrim
    [[ -z "$tok" ]] && continue

    # Leave alternatives ("a | b") alone; apt can already pick a satisfiable
    # branch, so rewriting one would only narrow its options.
    if [[ "$tok" != *"|"* ]]; then
      name="${tok%% *}"; rest="${tok#"$name"}"
      if [[ "$name" == *t64 ]] && ! pkg_installable "$name"; then
        newname="${name%t64}"
        if pkg_installable "$newname"; then
          tok="${newname}${rest}"
          DEPS_REMAPPED+="${DEPS_REMAPPED:+, }${name} -> ${newname}"
        fi
      fi
    fi
    out+=("$tok")
  done

  for tok in "${out[@]}"; do joined+="${joined:+, }$tok"; done
  REMAPPED_DEPS="$joined"
}

# Sets REPACKED_DEB to the .deb that should actually be handed to apt: the
# original when nothing needed changing, a repacked copy otherwise.
REPACKED_DEB=""
retarget_deb_deps() {
  local deb="$1" label="$2" orig new dir out
  REPACKED_DEB="$deb"

  orig="$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)"
  [[ -z "$orig" ]] && return 0

  remap_t64_deps "$orig"
  new="$REMAPPED_DEPS"
  [[ "$new" == "$orig" ]] && return 0

  dir="${deb%.deb}.rebuild"
  rm -rf "$dir"
  if ! dpkg-deb -R "$deb" "$dir" >/dev/null 2>&1; then
    warn "${label}: could not unpack for dependency retargeting - trying as-is"
    return 0
  fi

  # Replaces the Depends field including any RFC822 continuation lines, then
  # writes it back as one unfolded line (valid either way).
  awk -v newdeps="$new" '
    /^Depends:/ && !seen { print "Depends: " newdeps; seen=1; skip=1; next }
    skip && /^[ \t]/     { next }
                         { skip=0; print }
  ' "$dir/DEBIAN/control" > "$dir/DEBIAN/control.new" \
    && mv "$dir/DEBIAN/control.new" "$dir/DEBIAN/control"

  # --root-owner-group matters: dpkg-deb -R unpacked as us, so without it every
  # file would be installed owned by uid 1000 instead of root.
  out="${deb%.deb}.retargeted.deb"
  if dpkg-deb --root-owner-group -b "$dir" "$out" >/dev/null 2>&1; then
    REPACKED_DEB="$out"
    info "${label}: retargeted stale dependency names (${DEPS_REMAPPED})"
  else
    warn "${label}: repack failed - trying the original deb"
  fi
  return 0
}

#   install_obs_deb <label> <url> <filename>
# A plugin that fails must not take the rest of the run with it, and must not
# pass silently either. Each failure is recorded in FAILURES.
install_obs_deb() {
  local label="$1" url="$2" out="$WORKDIR/$3"

  if ! wget -q --show-progress -O "$out" "$url"; then
    rm -f "$out"
    fail "${label}: download failed - ${url}"
    return 0
  fi

  retarget_deb_deps "$out" "$label"

  # apt treats a path containing "/" as a local file by specified behaviour, and
  # pulls the .deb's dependencies from the repos itself.
  if sudo apt install -y "$REPACKED_DEB"; then
    ok "${label} installed"
  else
    fail "${label}: package install failed"
  fi
  return 0
}

# --- DistroAV (NDI) ----------------------------------------------------------
# DistroAV is the renamed OBS-NDI plugin (since 2024-06). The .deb declares
# `Depends: obs-studio`, so it must come AFTER section 3. It contains exactly
# one binary, obs-plugins/distroav.so, and crucially NO libndi - see section 6.
DISTROAV_VERSION="6.2.1"
install_obs_deb "DistroAV (NDI) ${DISTROAV_VERSION}" \
  "https://github.com/DistroAV/DistroAV/releases/download/${DISTROAV_VERSION}/distroav-${DISTROAV_VERSION}-x86_64-linux-gnu.deb" \
  "distroav-${DISTROAV_VERSION}-x86_64-linux-gnu.deb"

# --- Vertical Canvas (Aitum) -------------------------------------------------
# The 1080x1920 shorts canvas that the vertical workflow in obs-config.md is
# built on. Ships a proper .deb with `Depends: obs-studio`.
VC_VERSION="1.6.4"
install_obs_deb "Vertical Canvas ${VC_VERSION}" \
  "https://github.com/Aitum/obs-vertical-canvas/releases/download/${VC_VERSION}/vertical-canvas-linux-gnu.deb" \
  "vertical-canvas-linux-gnu.deb"

# --- Source Record (Exeldro) -------------------------------------------------
# Drives the "Source Record (youtube)" filter on the webcam - records one source
# to its own file independently of the main recording.
#
# NO .deb exists for Linux; upstream publishes only a portable tarball built on
# Ubuntu 22.04. That is fine here, verified against OBS 32.2.0:
#   - it links ONLY libobs.so.0, libobs-frontend-api.so.0 and libc.so.6
#     (no Qt at all, so none of the t64 trouble above and no Qt ABI risk)
#   - obs-studio 32.2.0 still ships the libobs.so.0 / libobs-frontend-api.so.0
#     compatibility symlinks alongside the current .so.30 sonames
#   - `ldd -r` on the installed file reports zero undefined symbols
#
# CAVEAT: this one is installed outside dpkg, so apt will never update or
# remove it. Uninstalling means deleting these two paths by hand:
#     /usr/lib/x86_64-linux-gnu/obs-plugins/source-record.so
#     /usr/share/obs/obs-plugins/source-record/
SR_VERSION="0.4.8"
SR_TGZ="source-record-${SR_VERSION}-ubuntu-22.04.tar.gz"
SR_URL="https://github.com/exeldro/obs-source-record/releases/download/${SR_VERSION}/${SR_TGZ}"
SR_TMP="$WORKDIR/source-record-unpack"
mkdir -p "$SR_TMP"

if wget -q --show-progress -O "${SR_TMP}/${SR_TGZ}" "$SR_URL"; then
  tar xzf "${SR_TMP}/${SR_TGZ}" -C "$SR_TMP"

  if [[ -f "${SR_TMP}/source-record/bin/64bit/source-record.so" ]]; then
    sudo install -Dm644 \
      "${SR_TMP}/source-record/bin/64bit/source-record.so" \
      "${OBS_PLUGIN_DIR}/source-record.so"
    sudo mkdir -p /usr/share/obs/obs-plugins/source-record
    sudo cp -r "${SR_TMP}/source-record/data/." \
      /usr/share/obs/obs-plugins/source-record/
    ok "Source Record ${SR_VERSION} installed (manual, not dpkg-tracked)"
  else
    fail "Source Record ${SR_VERSION}: tarball had an unexpected layout."
    warn "Expected source-record/bin/64bit/source-record.so. Got:"
    find "$SR_TMP" -name '*.so' | sed 's/^/     /' || true
  fi
else
  fail "Source Record ${SR_VERSION}: download failed - ${SR_URL}"
  warn "Latest: https://github.com/exeldro/obs-source-record/releases"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "6 · NDI host requirements - libndi · Avahi daemon · firewall ports"
# ══════════════════════════════════════════════════════════════════════════════
sudo apt install -y avahi-daemon ffmpeg
sudo systemctl enable --now avahi-daemon

# --- libndi: the NDI runtime -------------------------------------------------
# The Flatpak DistroAV extension bundles the NDI runtime. The .deb does not - it
# ships exactly one file, distroav.so. So we install libndi ourselves using
# DistroAV's own helper, the method their install docs prescribe: it pulls the
# NDI SDK v6 tarball from downloads.ndi.tv, drops the libs into /usr/local/lib,
# runs ldconfig, and symlinks libndi.so.6 -> libndi.so.5 so older plugin builds
# keep working.
#
# HEADS UP: that upstream script runs NewTek's SDK installer as `yes | sh ...`,
# i.e. it accepts the NDI SDK licence on your behalf without showing it to you.
# If you would rather read the EULA first, skip this block and run OBS once -
# DistroAV shows a dialog offering the same download.
#
# We download to a file and run it rather than piping curl into a root shell, so
# you can actually read it before it executes.
if ldso_has 'libndi'; then
  ok "NDI runtime already present on this host - skipping libndi install"
else
  info "Installing the NDI runtime via DistroAV's libndi-get.sh..."
  LIBNDI_GET="$WORKDIR/libndi-get.sh"
  LIBNDI_GET_URL="https://raw.githubusercontent.com/DistroAV/DistroAV/refs/heads/master/CI/libndi-get.sh"

  if curl -fsSL -o "$LIBNDI_GET" "$LIBNDI_GET_URL"; then
    chmod +x "$LIBNDI_GET"
    if sudo "$LIBNDI_GET" install; then
      sudo ldconfig
      if ldso_has 'libndi'; then
        ok "NDI runtime installed: $(ldconfig -p | awk '/libndi/{print $NF; exit}')"
      else
        warn "libndi-get.sh finished but libndi is still not on the linker path."
        warn "Check /usr/local/lib and that it is covered by /etc/ld.so.conf.d/."
      fi
    else
      warn "libndi-get.sh failed (downloads.ndi.tv unreachable, or SDK layout changed)."
      warn "Launch OBS once and accept DistroAV's download prompt instead."
    fi
  else
    warn "Could not fetch libndi-get.sh - NDI sources will not work yet."
    warn "Launch OBS once and accept DistroAV's download prompt, or see:"
    warn "   https://github.com/DistroAV/DistroAV/wiki/1.-Installation"
  fi
fi

# UFW rules for NDI. Only applied if ufw is installed AND active.
if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS="$(sudo ufw status 2>/dev/null || true)"
else
  UFW_STATUS=""
fi

if contains "$UFW_STATUS" "Status: active"; then
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
  info "UFW inactive - skipping firewall rules (NDI works without UFW on home LAN)"
fi

# No `flatpak override --system-talk-name=org.freedesktop.Avahi` here: the deb
# OBS is not sandboxed and talks to the host Avahi directly.
# No custom .desktop entry either beyond section 4's XWayland override, which
# deliberately reuses the packaged entry's name so it shadows rather than
# duplicates it in Activities.


# ══════════════════════════════════════════════════════════════════════════════
section "7 · Conflicting Flatpak OBS check"
# ══════════════════════════════════════════════════════════════════════════════
# If this machine previously ran the Flatpak variant of this setup, having two
# OBS installs is confusing, and the Flatpak one still will not see your VSTs.
if command -v flatpak >/dev/null 2>&1; then
  FLATPAK_APPS="$(flatpak list --app 2>/dev/null || true)"
  if contains "$FLATPAK_APPS" 'com.obsproject.Studio'; then
    warn "A Flatpak OBS is also installed. It cannot see /usr/lib/vst - its"
    warn "manifest pins VST_PATH=/app/extensions/Plugins/vst. To avoid launching"
    warn "the wrong one, consider removing it:"
    warn "   flatpak uninstall com.obsproject.Studio com.obsproject.Studio.Plugin.DistroAV"
  else
    ok "No conflicting Flatpak OBS"
  fi
else
  ok "No conflicting Flatpak OBS (flatpak not installed)"
fi


# ══════════════════════════════════════════════════════════════════════════════
section "8 · Verify the OBS install and every extension"
# ══════════════════════════════════════════════════════════════════════════════
# The per-section asserts run right after their own install, which is where the
# useful diagnostics live. This is the flat roll-up: one line per thing that has
# to be true for the OBS workflow to work, checked after everything has had its
# turn.
for _entry in \
  "obs-vst.so|VST 2.x Plug-in filter (obs-studio, PPA build)" \
  "distroav.so|DistroAV - NDI sources and output" \
  "vertical-canvas.so|Vertical Canvas - 1080x1920 shorts canvas" \
  "source-record.so|Source Record - per-source recording filter"
do
  _so="${_entry%%|*}"; _label="${_entry#*|}"
  if [[ -f "${OBS_PLUGIN_DIR}/${_so}" ]]; then
    ok "${_label}"
  else
    fail "MISSING: ${_label}  (${OBS_PLUGIN_DIR}/${_so})"
  fi
done

# A plugin file that exists but cannot resolve its symbols loads as nothing at
# all, and OBS reports that only deep in its log. Catch it here instead.
#
# The three outcomes are distinguished deliberately. Measured ldd behaviour:
#     healthy .so           -> rc 0, no marker lines
#     undefined symbols     -> rc 0, "undefined symbol: ..." lines
#     truncated / non-ELF   -> rc 1, "not a dynamic executable"
# Testing only for marker strings would score that last case as CLEAN, since a
# file ldd refuses to read produces no complaints about anything.
for _so in distroav.so vertical-canvas.so source-record.so; do
  [[ -f "${OBS_PLUGIN_DIR}/${_so}" ]] || continue

  _ldd_rc=0
  _ldd_out="$(ldd -r "${OBS_PLUGIN_DIR}/${_so}" 2>&1)" || _ldd_rc=$?

  if (( _ldd_rc != 0 )) || contains "$_ldd_out" 'not a dynamic executable'; then
    fail "${_so}: not a loadable shared object (truncated or corrupt download?)"
    warn "   rm ${OBS_PLUGIN_DIR}/${_so} and re-run this script"
  elif contains "$_ldd_out" 'not found'; then
    fail "${_so}: missing shared libraries - OBS will not load it"
    warn "   ldd ${OBS_PLUGIN_DIR}/${_so}"
  elif contains "$_ldd_out" 'undefined symbol'; then
    fail "${_so}: undefined symbols against this OBS - it will not load"
    warn "   ldd -r ${OBS_PLUGIN_DIR}/${_so}"
  else
    ok "${_so} links cleanly against this OBS"
  fi
done

# The NDI runtime is a separate concern from the plugin: distroav.so installs
# fine without it and then simply finds no sources at runtime.
if ldso_has 'libndi'; then
  ok "NDI runtime - $(ldconfig -p | awk '/libndi/{print $NF; exit}')"
else
  fail "MISSING: NDI runtime (libndi) - NDI sources will not appear"
fi

# The VST editor fix from section 4.
if [[ "$FORCE_XCB" != "1" ]]; then
  warn "VST editor fix disabled by OBS_VST_FORCE_XCB=0"
else
  if [[ -f "$OBS_DESKTOP_DST" ]] && contains "$(cat "$OBS_DESKTOP_DST")" 'QT_QPA_PLATFORM=xcb'; then
    ok "VST editor fix - Activities launches OBS under XWayland"
  else
    fail "MISSING: VST editor fix - ${OBS_DESKTOP_DST} does not force QT_QPA_PLATFORM=xcb"
  fi
  if [[ -x "$OBS_XCB_SHIM" ]] && contains "$(cat "$OBS_XCB_SHIM")" 'QT_QPA_PLATFORM=xcb'; then
    ok "VST editor fix - \`obs\` (terminal, crash relaunch) runs under XWayland"
  else
    fail "MISSING: VST editor fix - ${OBS_XCB_SHIM} shim not installed"
  fi
fi


# ══════════════════════════════════════════════════════════════════════════════
section "OBS / VST setup finished"
# ══════════════════════════════════════════════════════════════════════════════
cat <<'SUMMARY'
Installed:
  • OBS Studio (deb, obsproject PPA) - has the VST 2.x Plug-in filter
  • LSP audio plugins (VST2 + LADSPA) - usable as OBS audio filters
  • OBS plugins: DistroAV (NDI) · Vertical Canvas · Source Record
  • NDI host bits: libndi runtime · Avahi · ffmpeg
  • An OBS launcher that runs on XWayland so VST editors can open

VERIFY THE VST FIX (this is the one that needs your eyes):
  1. Fully quit OBS if it is running (an already-running OBS keeps Wayland).
  2. Launch OBS from Activities or with `obs` in a terminal - both are fixed.
  3. Its log should now say  Platform: X11  rather than  Platform: Wayland:
       grep -m1 Platform: "$(ls -t ~/.config/obs-studio/logs/*.txt | head -1)"
  4. Audio source -> Filters -> + -> "VST 2.x Plug-in" ->
     "Graphic Equalizer x16 Mono" -> "Open Plug-in Interface".
     The LSP window should open instead of taking OBS down with it.

If OBS still says "Platform: Wayland":
  - You launched the packaged entry, not the override. Check it exists:
       grep '^Exec=' ~/.local/share/applications/com.obsproject.Studio.desktop
  - From a terminal, `command -v obs` must print ~/.local/bin/obs.
  - GNOME may need a moment or a re-login to pick up a new desktop entry.

If the VST list in OBS is empty:
  - Confirm THIS OBS was built with VST support at all:
       ls /usr/lib/x86_64-linux-gnu/obs-plugins/obs-vst.so
    Missing means you are on the universe OBS, which has no VST filter.
    Check the PPA took:  apt-cache policy obs-studio   (origin: obsproject)
  - Confirm the plugin files exist (note the ".vst" suffix on the dir):
       ls /usr/lib/vst/lsp-plugins.vst/ | head
  - Confirm you launched the DEB OBS, not a leftover Flatpak:
       which obs                    # should be /usr/bin/obs
       flatpak list | grep -i obs   # should be empty

If NDI sources don't appear on the LAN:
  - Confirm libndi is present:  ldconfig -p | grep ndi
    (empty? launch OBS once and accept DistroAV's download prompt)
  - Confirm both machines are on the same subnet
  - Check:  systemctl status avahi-daemon
  - Check:  avahi-browse -a     # should list local services
  Note: libndi-get.sh auto-accepted the NDI SDK EULA on your behalf.
SUMMARY


# ══════════════════════════════════════════════════════════════════════════════
# Did anything actually break?
# ══════════════════════════════════════════════════════════════════════════════
# Every optional step above is best-effort so that one dead download cannot cost
# you the whole run. This is where that bill comes due: without it the script
# ends on a cheerful "finished" whether or not OBS can load a single plugin, and
# you find out mid-stream instead.
if ((${#FAILURES[@]})); then
  echo
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

ok "All OBS/VST post-install checks passed."
