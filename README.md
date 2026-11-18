# Android Debian + KDE Plasma 6 (SteamOS Desktop Mode) 🐧🎮

Automated, idempotent installer and updater for running a full **Debian (Trixie) + KDE Plasma 6** desktop environment on Android — tuned to mirror **SteamOS Desktop Mode** — across **both**:

1. **Termux (`proot-distro`)** — No root required; uses `termux-x11` and `virgl_test_server_android` (Zink / ANGLE / Turnip) for 3D GPU hardware acceleration + PulseAudio over local TCP.
2. **Android's Native Linux Terminal (`native` AVF / pKVM Debian VM)** — Runs directly inside the built-in Debian virtual machine on Android 15 QPR2 / Android 16+, supporting:
   - **TigerVNC X11 Server** (`127.0.0.1:5901`) for instant local phone access via [AVNC](https://f-droid.org/packages/com.gaurav.avnc/) or PC access via `adb forward tcp:5901 tcp:5901`.
   - **Native Terminal Built-in Wayland Display** (Android 16+ GUI mode with Virtio-GPU / VirGL hardware acceleration).
   - **Hybrid Termux:X11 + VirGL GPU Bridge** (combines the true VM speed of Android's Native Linux Terminal with the high-FPS X11 + VirGL display server of Termux:X11).

---

## Quick Start (One-Liner)

Run directly inside **Termux** OR inside **Android's Native Linux Terminal**:

```bash
curl -fsSL https://raw.githubusercontent.com/myndxero/android-debian-steamos-desktop/main/install-debian-kde.sh -o install-debian-kde.sh
chmod +x install-debian-kde.sh
./install-debian-kde.sh
```

> **Note for Termux users:** Install Termux and Termux:X11 from **GitHub Releases** or **F-Droid** (not Google Play):
> - [Termux APK](https://github.com/termux/termux-app/releases)
> - [Termux:X11 APK](https://github.com/termux/termux-x11/releases)

---

## Common Commands & Options

```bash
# Default full SteamOS Desktop Mode install (auto-detects Termux vs Native Terminal)
./install-debian-kde.sh

# Install with the optional ARM64 gaming pack (MangoHud, GameMode, controller tools, setup-gaming.sh)
./install-debian-kde.sh --with-gaming

# Upgrade an Android 15/16 Native Terminal VM from Debian 12 (Bookworm) to Debian 13 (Trixie) for KDE Plasma 6
./install-debian-kde.sh --env native --upgrade-trixie

# Lighter install (plasma-desktop + konsole + dolphin + kate)
./install-debian-kde.sh --minimal

# Preview the entire execution plan without changing anything
./install-debian-kde.sh --dry-run

# Update/upgrade an existing installation (Termux pkgs, Debian apt full-upgrade, Flatpaks, launchers, smoke test)
./install-debian-kde.sh --update
# (or use the generated shortcut: ~/update-debian-kde.sh)
```

### All CLI Flags

| Flag | Description |
| :--- | :--- |
| `--env auto\|termux\|native` | Target environment (default: `auto`) |
| `--update` / `--upgrade` | Update Termux packages, Debian `apt full-upgrade`, Flatpaks, launchers, and run smoke test |
| `--upgrade-trixie` | *(Native VM)* Upgrade Debian 12 (Bookworm) APT sources to Debian 13 (Trixie) for KDE Plasma 6 |
| `--full` / `--minimal` | Full SteamOS-like KDE suite (`--full`, default) or minimal Plasma (`--minimal`) |
| `--steamos` / `--no-steamos` | Enable/disable SteamOS Desktop Mode theme, KWin tuning, and desktop shortcuts (default: on) |
| `--reset-theme` | Re-apply SteamOS Breeze Dark theme configs even if already initialized |
| `--with-flatpak` / `--no-flatpak` | Install Flatpak + Flathub + KDE Discover Flatpak backend (default: on) |
| `--with-gaming` | Install `mangohud`, `gamemode`, controller diagnostics, and `~/setup-gaming.sh` helper |
| `--username NAME` | Non-root Debian user to create/configure (default: `droid` or active non-root user) |
| `--gpu-backend zink\|angle\|turnip` | VirGL backend on Termux (`zink` for Tensor/Mali/Xclipse, `turnip` for Adreno, `angle` for GLES translator) |
| `--no-gpu` | Disable VirGL / GPU acceleration setup |
| `--no-audio` | Disable PulseAudio setup |
| `--with-vnc` / `--no-vnc` | Enable/disable TigerVNC server on `:1` (`5901`; default: on in `native` mode, optional in `termux`) |
| `--with-gdrive` / `--no-gdrive` | Enable/disable Google Drive `rclone` integration (default: on) |
| `--sync-interval-min N` | Periodic Google Drive sync interval in minutes while Plasma runs (default: `30`; `0` = startup only) |
| `--disk-floor-gb N` | Minimum free disk space required before starting fresh install (default: `10` full / `6` minimal) |
| `--dry-run` | Print the execution plan and exit |
| `--smoke-test` | Run only the verification smoke test against an existing installation |
| `-y`, `--yes` | Assume yes for interactive prompts |

---

## SteamOS Desktop Mode Features

- **Breeze Dark by Default**: Pre-configured `kdeglobals` and `plasmarc` with `org.kde.breezedark.desktop`, dark icons, and matching dark GTK theme (`breeze-gtk-theme`, `kde-config-gtk-style`).
- **Mobile KWin & Storage Optimizations**:
  - Disables **KScreenLocker** (`kscreenlockerrc`) so Termux:X11 and VNC sessions never get trapped behind a broken PAM lock screen.
  - Disables **Baloo** background file indexing (`baloofilerc`) to save battery and flash storage I/O.
  - Tunes **KWin** (`kwinrc`) for low-latency OpenGL compositing without heavy blur shaders.
- **Flatpak + Flathub + KDE Discover**: Graphical software center pre-wired to Flathub.
- **Desktop Shortcuts (`~/Desktop/`)**:
  - **Return to Android**: Cleanly logs out of KDE Plasma and stops background X11/VNC/VirGL/sync services (just like SteamOS's *"Return to Gaming Mode"*).
  - **Android Storage**: Opens Android's shared storage (`~/AndroidStorage` → `/mnt/sdcard` on Termux or `/mnt/shared` on Native Terminal) in Dolphin.
  - **Sync Google Drive**: Runs an immediate two-way Google Drive sync with desktop notifications.
  - **GPU Status & Benchmark**: Opens Konsole and runs `~/gpu-status.sh --bench` (`glxinfo`, `vulkaninfo`, and a 10-second `glxgears` test).

---

## Launching the Desktop

### In Termux Mode
1. Run `~/start-plasma.sh` in Termux.
2. Open the **Termux:X11** app on Android.
3. To stop, click **Return to Android** on the Plasma Desktop or run `~/stop-plasma.sh`.

### In Android Native Linux Terminal Mode
- **Option A — VNC Desktop (works on all Android 15/16+ builds)**:
  1. Run `~/start-plasma.sh --vnc`
  2. Connect with **AVNC** on Android to `127.0.0.1:5901` (initial password: `steamdeck`; change anytime with `vncpasswd`).
  3. For audio playback, open [Simple Protocol Player](https://github.com/xlzhen-940218/SimpleProtocolPlayer/releases) on Android and connect to `127.0.0.1` port `12345`.
- **Option B — Built-in Wayland Display (Android 16+)**:
  1. Run `~/start-plasma.sh --wayland`
  2. Tap the **Display** icon in the top-right corner of the Android Terminal app.
- **Option C — Hybrid Termux:X11 + VirGL GPU Bridge**:
  1. In Termux on Android, run: `bash /sdcard/Download/termux-host-bridge.sh`
  2. In Android's Native Linux Terminal, run: `~/start-plasma.sh --bridge`
  3. Open the **Termux:X11** app!

---

## Google Drive Integration

Inside Debian (`~/start-debian.sh` or Konsole):
- `~/setup-gdrive.sh` — One-time interactive OAuth configuration for the `gdrive:` remote.
- `~/gdrive-sync.sh` — Two-way sync (`rclone bisync`) between Google Drive and `~/GoogleDrive`, serialized via `flock` and automatically executed at Plasma startup + every 30 minutes (`~/gdrive-sync-loop.sh`).
- `~/gdrive-mount.sh` — Direct FUSE mount at `~/GoogleDriveMount` (supported inside Android's Native Linux Terminal VM where `/dev/fuse` is available; automatically falls back to `~/gdrive-sync.sh` inside `proot`).
