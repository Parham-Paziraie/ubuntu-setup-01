# OBS Studio - captured configuration

Snapshot of the working OBS setup on **x13-ThinkPad-X13-Yoga-Gen-4** (Ubuntu 26.04),
taken 2026-08-28 immediately before wiping OBS for a clean reinstall.

`ubuntu-26.04-setup.sh` already covers *installing* OBS. This file covers the part
the script never captured: the runtime configuration built up by hand afterwards,
plus the two plugins the script does not install.

Rebuild with `./obs-restore.sh`, or by hand from the tables below.

- **Config backup:** `~/obs-backup-2026-08-28/obs-config-final.tar.gz` (mode 600)
- **Backup contents:** the whole `~/.var/app/com.obsproject.Studio/{config,data}` tree, minus `cache`
- **Contains live secrets** - see [Secrets](#secrets). Do not commit it, do not move it into this repo.

---

## 1. Packages

OBS itself is a Flatpak. Nothing OBS-related came from apt or snap.

| Flatpak ref | Version | Scope | Installed by |
|---|---|---|---|
| `com.obsproject.Studio` | 32.1.2 | **system** | `ubuntu-26.04-setup.sh` §7 |
| `com.obsproject.Studio.Plugin.DistroAV` | 6.2.1 | **system** | `ubuntu-26.04-setup.sh` §7 |
| `com.obsproject.Studio.Plugin.SourceRecord` | 0.4.8 | **user** | added manually later |
| `com.obsproject.Studio.Plugin.VerticalCanvas` | 1.6.4 | **user** | added manually later |

> **Scope gotcha.** The two manual plugins landed in the `--user` installation while OBS
> and DistroAV live in the system one. Flatpak does resolve extensions across both
> installations, so it worked, but it is fragile: `flatpak update` on one scope will not
> touch the other, and a system-scope OBS uninstall leaves the user-scope plugins orphaned.
> `obs-restore.sh` puts all four in the **system** scope on purpose.

Both `flathub` remotes exist (system and user).

## 2. Host prerequisites

Beyond the packages, three host-side things make this setup work:

```bash
# 1. Avahi access for the Flatpak sandbox - REQUIRED for NDI discovery since OBS 32.
#    Without it, DistroAV loads but finds zero sources.
sudo flatpak override com.obsproject.Studio --system-talk-name=org.freedesktop.Avahi

# 2. The host mDNS daemon itself. The override only opens the sandbox door.
sudo apt install -y avahi-daemon && sudo systemctl enable --now avahi-daemon

# 3. VAAPI hardware encoding runs on the Intel iGPU render node:
#      /dev/dri/by-path/pci-0000:00:02.0-render
#    This exact path is baked into two encoder configs. Re-check it after any
#    hardware change - on a hybrid-GPU machine it will differ.
```

The system override file is a single stanza:

```ini
# /var/lib/flatpak/overrides/com.obsproject.Studio
[System Bus Policy]
org.freedesktop.Avahi=talk
```

A cosmetic launcher also existed at `~/.local/share/applications/obs-studio-ndi.desktop`
("OBS Studio (with NDI)"), created by `ubuntu-26.04-setup.sh` §9. It just runs
`flatpak run com.obsproject.Studio`.

## 3. Profile: `Untitled`

Output mode is **Advanced**, not Simple.

### Video

| Setting | Value |
|---|---|
| Base (canvas) | 1920x1080 |
| Output (scaled) | 1536x864 |
| Downscale filter | Bicubic |
| FPS | 30 |
| Color | NV12 / 709 / Partial, SDR white 300 nits |
| Renderer | OpenGL (`global.ini`) |

### Recording

| Setting | Value |
|---|---|
| Path | `/home/x13/Videos` |
| Format | `mkv` |
| Video encoder | `hevc_ffmpeg_vaapi_tex` (HEVC via VAAPI) |
| VAAPI device | `/dev/dri/by-path/pci-0000:00:02.0-render` |
| Rate control | VBR @ 1000 kbps, profile 1 |
| Audio encoder | `libfdk_aac` @ 160 kbps, track 1 |
| Split files | every 15 min (2048 MB cap) |
| Replay buffer | on, 20 s / 512 MB |
| Filename format | `%CCYY-%MM-%DD %hh-%mm-%ss` |

### Streaming

| Setting | Value |
|---|---|
| Service | YouTube - RTMPS (`rtmps://a.rtmps.youtube.com:443/live2`) |
| Auth | OAuth, linked to channel **Parham Paziraie** |
| Encoder | `obs_x264`, rate control CRF |
| Multitrack video | disabled |
| Reconnect | on, 2 s delay, 25 retries |

### Audio

48 kHz stereo, monitoring device = default.

| Mixer channel | Source | Level |
|---|---|---|
| Desktop Audio | `pulse_output_capture` (default) | 0.344 |
| Mic/Aux | `pulse_input_capture` (default) | 0.0 (silenced) |

> Mic/Aux carries a `vst_filter` ("VST 2.x Plug-in") with **empty** `chunk_data` and
> `chunk_hash` - no plugin was ever actually loaded into it. It is a no-op placeholder.
> `obs-restore.sh` does not recreate it.

## 4. Scene collection: `Untitled`

Canvas 1920x1080. Default transition Fade @ 300 ms. Startup scene: `Scene`.

An **Aitum Vertical** canvas (from the Vertical Canvas plugin) is registered alongside
the main one.

### Sources

| Source | Type | Settings |
|---|---|---|
| `Video Capture Device (V4L2)` | `v4l2_input` | `/dev/video0`, input 0 |
| `Screen Capture (PipeWire)` | `pipewire-screen-capture-source` | cursor shown, portal restore token |

### Scenes

| Scene | Contents |
|---|---|
| **Scene** (main) | Screen Capture at (96, 0) scaled 0.90; webcam PiP at (96, 775) scaled 0.42 |
| **youtube** | Webcam only, at (96, 0) scaled 0.5625, bounds 1728x1080 (scale-to-bounds) |
| **Vertical Scene** | empty |
| **Vertical Scene 1** | Webcam at (-1145, 0) scaled 2.67 - cropped to fill the 1080x1920 vertical canvas |

Only `Scene` and `youtube` appear in the main scene list; the two Vertical scenes belong
to the vertical canvas.

### Filters

One filter in the whole collection, on the webcam source:

| Filter | Type | Settings |
|---|---|---|
| `Source Record (youtube)` | `source_record_filter` | VAAPI `/dev/dri/by-path/pci-0000:00:02.0-render`, 2000 kbps VBR, scale_type 3, stream_mode 0 |

This is the Source Record plugin recording the webcam to its own file, independent of the
main recording.

### Output timer

Stream and record timers both set to 30 s, auto-start off, pause-record-timer on.

## 5. Plugin settings

### Vertical Canvas (Aitum)

The vertical/shorts setup, and the main thing worth keeping.

| Setting | Value |
|---|---|
| Canvas | **1080x1920** |
| Current scene | `Vertical Scene 1` |
| Backtrack (replay buffer) | on, 20 s, to `/home/x13/Videos` |
| Record video bitrate | 1000 kbps |
| Transition | Fade |
| Match main stream/recording | off for both |
| Virtual camera mode | 0 |
| Hotkeys | none bound |
| Stream outputs | none configured (no vertical simulcast target) |

### DistroAV (NDI)

Installed and enabled, but **idle** - no NDI source or output is used by any scene.

| Setting | Value |
|---|---|
| Main output | disabled (name would be `OBS PGM`) |
| Preview output | disabled (name would be `OBS Preview`) |
| Tally program / preview | both enabled |

If NDI is not actually needed on the next install, dropping DistroAV also drops the
Avahi override and the avahi-daemon dependency.

### obs-websocket (built in)

| Setting | Value |
|---|---|
| Server | **disabled** |
| Port | 4455 |
| Auth required | yes |
| Password | stored in backup, see below |
| Alerts | off |

### Enabled modules

`plugin_manager/modules.json` lists all three third-party modules as enabled:
`distroav`, `source-record`, `vertical-canvas`.

## 6. Secrets

**Not reproduced in this file. All of these live only in the backup tarball.**

| Secret | Location inside the backup |
|---|---|
| YouTube OAuth refresh + access token | `config/obs-studio/basic/profiles/Untitled/basic.ini`, `[YouTube]` |
| obs-websocket server password | `config/obs-studio/plugin_config/obs-websocket/config.json` |
| PulseAudio cookie | `config/pulse/cookie` |

The YouTube **refresh token is long-lived and still valid**. Two consequences:

- Keep the tarball at mode 600 and out of git, cloud sync, and this repo.
- If you would rather not carry it forward, revoke it at
  <https://myaccount.google.com/permissions> and just re-link YouTube in the new OBS.
  Re-linking is a single click and takes less time than restoring the token.

The stream key itself is empty - OAuth handles it, so nothing to rotate there.

## 7. What will NOT survive a reinstall

Even with a full config restore, these need a manual redo:

1. **PipeWire screen-capture restore token.** The portal token is bound to the app
   instance. The Screen Capture source will prompt you to re-pick the display or window
   on first use. Unavoidable.
2. **YouTube OAuth**, if you restore selectively or revoke the token. Re-link in
   Settings > Stream.
3. **The VST filter placeholder** on Mic/Aux, if you care to have an empty one back.
4. **Window/dock layout** rides along in `user.ini` `DockState`, but OBS will happily
   rebuild it if the restore is skipped.

## 8. Restoring

### Onto a deb OBS (current direction)

`ubuntu-26.04-setup-obs-vst.sh` replaced the Flatpak with a deb OBS from the obsproject
PPA, so that script installs the packages and `obs-restore.sh --deb` only moves the
config into place:

```bash
./ubuntu-26.04-setup-obs-vst.sh
./obs-restore.sh --deb --restore-config ./obs-backup-2026-08-28/obs-config-final.tar.gz
```

**Order matters.** Run the setup script first. The scene collection references
`source_record_filter` and the Aitum vertical canvas; if those plugins are not installed
when OBS loads the restored collection, OBS drops them silently and re-saves without
them. `--deb` warns you if either `.so` is missing.

The two packagings read config from different places, which is the only thing `--deb`
changes:

| Packaging | Config location |
|---|---|
| Flatpak | `~/.var/app/com.obsproject.Studio/config/obs-studio` |
| deb | `~/.config/obs-studio` |

Only `config/obs-studio` is restored out of the tarball. The PulseAudio cookie and the
empty `data/` dir are per-install and are deliberately left alone.

### Back onto a Flatpak OBS

```bash
./obs-restore.sh --restore-config ./obs-backup-2026-08-28/obs-config-final.tar.gz
./obs-restore.sh                  # packages + host prereqs only
./obs-restore.sh --no-ndi         # skip DistroAV and Avahi entirely
```

### Backup location warning

The tarball now lives at `obs-backup-2026-08-28/` **inside this repo**, and it is the
only copy. It is covered by `.gitignore` so it cannot be committed to this public repo -
but that also means `git clean -xdf` **will delete it**. Keep a copy elsewhere if it
still matters to you.
