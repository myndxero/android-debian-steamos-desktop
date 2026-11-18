#!/data/data/com.termux/files/usr/bin/bash
#
# install-debian-kde.sh — Full Debian + KDE Plasma 6 desktop on Android, via Termux.
#
# What it does, start to finish:
#   1. Preflight: Termux sanity, aarch64, Android version, free disk, network.
#   2. Termux bootstrap: x11-repo, termux-x11-nightly, pulseaudio, proot-distro,
#      virglrenderer-android (GPU acceleration), wget.
#   3. proot-distro: installs Debian (trixie) rootfs — skipped if already present.
#   4. Debian base: sudo, curl, ca-certificates, dbus-x11, non-root user w/ sudo.
#   5. KDE Plasma 6: kde-plasma-desktop (full) or plasma-desktop (minimal).
#   6. GPU acceleration: VirGL server (Zink/Vulkan path) on the Termux side,
#      virpipe client driver inside Debian. Best-effort on Tensor G5.
#   7. Audio: PulseAudio on Termux side, PULSE_SERVER wired into the session.
#   8. Launchers: ~/start-plasma.sh, ~/stop-plasma.sh, ~/start-debian.sh,
#      ~/start-virgl.sh (+ optional VNC fallback).
#   9. Google Drive: rclone two-way sync (~/GoogleDrive), auto-synced at every
#      Plasma startup after a one-time OAuth authorization, plus a periodic
#      re-sync every N minutes (configurable, default 30) while Plasma runs.
#  10. Smoke test: verifies the whole stack actually works.
#
# Idempotent: every phase checks real state first (dpkg-query, rootfs dir,
# user existence, binaries, rclone remote) and skips work that's already done.
# Safe to re-run.
#
# NOTE on "mounting" Drive: true FUSE mounts are impossible inside proot on
# Android (no /dev/fuse without root), so the script uses automated two-way
# sync instead — your files still live at ~/GoogleDrive in the Debian home.
#
# Usage:
#   bash install-debian-kde.sh [options]
#
# Options:
#   --minimal            Install plasma-desktop + konsole + dolphin instead of
#                        the full kde-plasma-desktop meta-package (much smaller).
#   --full               Full kde-plasma-desktop + extras (default).
#   --username NAME      Debian user to create/use (default: droid).
#   --no-gpu             Skip VirGL GPU acceleration setup.
#   --no-audio           Skip PulseAudio setup.
#   --with-vnc           Also set up TigerVNC as a fallback display path.
#   --with-gdrive        Set up Google Drive auto-sync (default: on).
#   --no-gdrive          Skip Google Drive setup.
#   --sync-interval-min N
#                        Re-sync Drive every N minutes while Plasma runs
#                        (default: 30; 0 = sync only at Plasma startup).
#   --disk-floor-gb N    Require N GB free before starting (default: 10).
#   --dry-run            Print the full plan and exit without changing anything.
#   --smoke-test         Only run the smoke test against an existing install.
#   -y, --yes            Assume yes for interactive prompts (fully unattended
#                        except the Termux:X11 APK tap + one-time Drive OAuth).
#   -h, --help           Show this help.
#
# After the script finishes you still need, once, by hand:
#   * Termux:X11 APK installed from https://github.com/termux/termux-x11/releases
#     (the `termux-x11` Termux package alone is NOT enough — the APK is the
#     actual display server). Then just run ~/start-plasma.sh and open the
#     Termux:X11 app.
#
# Logs: ~/.linux-install/install.log (rotated, keeps last 5).

set -euo pipefail

# ---------------------------------------------------------------- config ------
SCRIPT_VERSION="1.1.0"
PROFILE="full"                 # full | minimal
USERNAME="droid"
WITH_GPU=1
WITH_AUDIO=1
WITH_VNC=0
WITH_GDRIVE=1
SYNC_INTERVAL_MIN=30           # Drive re-sync cadence while Plasma runs; 0 = startup only
DISK_FLOOR_GB=10
DRY_RUN=0
SMOKE_ONLY=0
ASSUME_YES=0

STATE_DIR="${HOME}/.linux-install"
LOG_FILE="${STATE_DIR}/install.log"
STATE_FILE="${STATE_DIR}/state"

DEBIAN_ROOTFS="${PREFIX:-}/var/lib/proot-distro/installed-rootfs/debian"

# Termux-side packages we need
TERMUX_PKGS=(x11-repo termux-x11-nightly pulseaudio proot-distro virglrenderer-android wget dbus)
# Debian base packages (always)
DEBIAN_BASE_PKGS=(sudo curl ca-certificates dbus-x11 nano gnupg locales rclone)
# Plasma profiles
PLASMA_FULL_PKGS=(kde-plasma-desktop)
PLASMA_FULL_EXTRA=(firefox-esr kate ark gwenview okular spectacle pavucontrol-qt)
PLASMA_MINIMAL_PKGS=(plasma-desktop konsole dolphin kate)
VNC_PKGS=(tigervnc-standalone-server)

# ------------------------------------------------------------------ usage ------
usage() {
  sed -n '2,/^# Logs/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ------------------------------------------------------------------- args ------
while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)       PROFILE="minimal"; shift ;;
    --full)          PROFILE="full"; shift ;;
    --username)      USERNAME="$2"; shift 2 ;;
    --username=*)    USERNAME="${1#*=}"; shift ;;
    --no-gpu)        WITH_GPU=0; shift ;;
    --no-audio)      WITH_AUDIO=0; shift ;;
    --with-vnc)      WITH_VNC=1; shift ;;
    --with-gdrive)   WITH_GDRIVE=1; shift ;;
    --no-gdrive)     WITH_GDRIVE=0; shift ;;
    --sync-interval-min) SYNC_INTERVAL_MIN="$2"; shift 2 ;;
    --sync-interval-min=*) SYNC_INTERVAL_MIN="${1#*=}"; shift ;;
    --disk-floor-gb) DISK_FLOOR_GB="$2"; shift 2 ;;
    --disk-floor-gb=*) DISK_FLOOR_GB="${1#*=}"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --smoke-test)    SMOKE_ONLY=1; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# Validate username (Linux username rules, keeps proot-distro --user happy)
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "ERROR: --username '$USERNAME' is not a valid Linux username." >&2
  exit 2
fi

# Validate sync interval (non-negative integer minutes)
if ! [[ "$SYNC_INTERVAL_MIN" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --sync-interval-min must be a non-negative integer (got '$SYNC_INTERVAL_MIN')." >&2
  exit 2
fi

# ----------------------------------------------------------------- logging -----
mkdir -p "$STATE_DIR"
# rotate logs, keep last 5
if [ -f "$LOG_FILE" ]; then
  for i in 4 3 2 1; do
    [ -f "${LOG_FILE}.${i}" ] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1"
fi
: > "$LOG_FILE"
# everything to console AND log
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
info()  { echo "[$(ts)] [INFO]  $*"; }
warn()  { echo "[$(ts)] [WARN]  $*" >&2; }
err()   { echo "[$(ts)] [ERROR] $*" >&2; }
step()  { echo ""; echo "[$(ts)] ===== $* ====="; }

# ------------------------------------------------------------------ traps ------
trap 'rc=$?; err "FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"; err "See ${LOG_FILE} for details."; exit ${rc}' ERR
trap 'rc=$?; if [ $rc -eq 0 ]; then info "Script finished OK."; else err "Script exited with code ${rc}."; fi' EXIT

# ----------------------------------------------------------------- helpers -----
# retry <tries> <command...>: exponential backoff, for network-ish operations
retry() {
  local tries="$1"; shift
  local n=0 delay=5
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$tries" ]; then
      err "Command failed after ${tries} attempts: $*"
      return 1
    fi
    warn "Attempt ${n}/${tries} failed, retrying in ${delay}s: $*"
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# run <command...>: honors --dry-run
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would run: $*"
    return 0
  fi
  info "run: $*"
  "$@"
}

phase_done()  { [ "$DRY_RUN" -eq 1 ] && return 0; grep -qx "PHASE:$1" "$STATE_FILE" 2>/dev/null; }
mark_phase()  { [ "$DRY_RUN" -eq 1 ] && return 0; grep -qx "PHASE:$1" "$STATE_FILE" 2>/dev/null || echo "PHASE:$1" >> "$STATE_FILE"; touch "$STATE_FILE"; }

termux_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

debian_rootfs_present() { [ -d "$DEBIAN_ROOTFS" ] && [ -f "$DEBIAN_ROOTFS/etc/debian_version" ]; }

# din: run a command inside Debian as root. din_user: as $USERNAME.
din()      { proot-distro login debian -- "$@"; }
din_user() { proot-distro login --user "$USERNAME" debian -- "$@"; }

debian_pkg_installed() {
  debian_rootfs_present || return 1
  din dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

debian_user_exists() {
  debian_rootfs_present || return 1
  din id -u "$USERNAME" >/dev/null 2>&1
}

confirm() {
  # confirm <prompt>: yes if --yes or user answers y
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- dry-run -----
print_plan() {
  cat <<EOF
install-debian-kde.sh v${SCRIPT_VERSION} — DRY RUN PLAN
=====================================================
Profile          : ${PROFILE}
Debian user      : ${USERNAME}
GPU accel (VirGL): $([ "$WITH_GPU" -eq 1 ] && echo yes || echo no)
Audio (Pulse)    : $([ "$WITH_AUDIO" -eq 1 ] && echo yes || echo no)
VNC fallback     : $([ "$WITH_VNC" -eq 1 ] && echo yes || echo no)
Google Drive     : $([ "$WITH_GDRIVE" -eq 1 ] && echo "auto-sync via rclone (re-sync every ${SYNC_INTERVAL_MIN} min)" || echo no)
Disk floor       : ${DISK_FLOOR_GB} GB free required

Phases:
  [10] preflight        Termux env, aarch64, Android SDK, disk, network,
                       Termux:X11 companion package presence
  [20] termux-bootstrap pkg update + install:
                         ${TERMUX_PKGS[*]}
  [30] debian-rootfs    proot-distro install debian (~350 MB download)
  [40] debian-base      apt update + install:
                         ${DEBIAN_BASE_PKGS[*]}
                       + create user '${USERNAME}' with passwordless sudo
  [50] plasma           apt install:
EOF
  if [ "$PROFILE" = "full" ]; then
    echo "                         ${PLASMA_FULL_PKGS[*]} ${PLASMA_FULL_EXTRA[*]}"
    echo "                       (~2-4 GB download, ~6-9 GB on disk)"
  else
    echo "                         ${PLASMA_MINIMAL_PKGS[*]}"
    echo "                       (~1-1.5 GB download, ~3-4 GB on disk)"
  fi
  cat <<EOF
  [60] gpu              ~/start-virgl.sh (VirGL/Zink server launcher)
                       + virpipe client env in the Plasma session script
  [70] audio            PulseAudio TCP module on Termux side,
                       PULSE_SERVER=127.0.0.1 in the session script
  [80] launchers        ~/start-plasma.sh  (pulse -> virgl -> termux-x11 -> plasma)
                       ~/stop-plasma.sh
                       ~/start-debian.sh  (plain proot shell as ${USERNAME})
                       ~/.launch-plasma.sh inside Debian (the X session)
  [85] vnc (optional)  tigervnc server + ~/.vnc/xstartup + ~/start-plasma-vnc.sh
  [82] gdrive           rclone two-way sync -> ~/GoogleDrive, auto-run at every
                       Plasma startup (one-time OAuth via ~/setup-gdrive.sh),
                       plus a periodic re-sync every ${SYNC_INTERVAL_MIN} min
                       while Plasma runs (~/gdrive-sync-loop.sh; 0 = startup
                       only). Overlapping syncs serialize via flock.
  [90] smoke-test       verify: proot boots, startplasma-x11 exists, dbus works,
                       termux-x11/virgl/pulseaudio binaries present

Manual step afterwards (cannot be scripted — needs your tap):
  * Install the Termux:X11 APK from https://github.com/termux/termux-x11/releases
    then run:  ~/start-plasma.sh
    and open the Termux:X11 app.

Every phase is idempotent: already-installed packages, the existing rootfs,
the existing user and existing launchers are detected and skipped.
EOF
}

# ---------------------------------------------------------------- preflight ----
phase_preflight() {
  step "Phase 10/90 — preflight"

  # Must run inside Termux
  if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *"com.termux"* ]]; then
    err "This script must run inside Termux on Android (PREFIX=$PREFIX)."
    err "Install Termux from GitHub/F-Droid — NOT the Play Store build, it is"
    err "outdated and will break: https://github.com/termux/termux-app/releases"
    exit 1
  fi
  info "Running inside Termux: PREFIX=$PREFIX"

  # Architecture: proot-distro Debian needs aarch64 for this recipe
  local arch
  arch="$(uname -m)"
  info "Architecture: $arch"
  if [ "$arch" != "aarch64" ]; then
    warn "This recipe is tuned for aarch64 (Pixel 10 Pro XL). Continuing anyway,"
    warn "but proot-distro package availability may differ on $arch."
  fi

  # Android version
  local sdk=0
  if command -v getprop >/dev/null 2>&1; then
    sdk="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
  fi
  info "Android SDK: $sdk"
  if [ "$sdk" -gt 0 ] && [ "$sdk" -lt 29 ]; then
    warn "Android 10 (SDK 29)+ recommended for Termux:X11. Older versions may work with VNC."
  fi
  if [ "$sdk" -gt 0 ] && [ "$sdk" -lt 31 ]; then
    warn "Android 12 (SDK 31)+ recommended for the best Termux:X11 experience."
  fi

  # Play Store Termux warning (can't detect reliably, so always say it once)
  warn "Make sure Termux itself came from GitHub or F-Droid, NOT Google Play."
  warn "The Play Store build is ancient and this script will fail on it."

  # Disk space
  local free_kb need_kb
  free_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
  need_kb=$((DISK_FLOOR_GB * 1024 * 1024))
  info "Free space on \$HOME: $((free_kb / 1024 / 1024)) GB (need >= ${DISK_FLOOR_GB} GB)"
  if [ "$free_kb" -lt "$need_kb" ]; then
    err "Not enough free space: have $((free_kb/1024/1024)) GB, need ${DISK_FLOOR_GB} GB."
    err "Free up space or re-run with --disk-floor-gb <lower> (at your own risk)."
    exit 1
  fi

  # Network
  info "Checking network reachability..."
  retry 3 curl -sSI --max-time 20 -o /dev/null https://deb.debian.org/debian/ \
    || { err "No usable network to deb.debian.org — connect and re-run."; exit 1; }
  retry 3 curl -sSI --max-time 20 -o /dev/null https://grimler.se/termux/ \
    || warn "Termux package mirror not reachable; pkg may fail — will retry inside bootstrap."

  # Termux:X11 companion package hint (the APK itself can't be detected w/o root)
  if ! termux_pkg_installed termux-x11-nightly && [ "$DRY_RUN" -eq 0 ]; then
    warn "The Termux:X11 *APK* (the display server app) cannot be auto-detected."
    warn "After this script, install it once from:"
    warn "  https://github.com/termux/termux-x11/releases"
  fi

  # Battery-friendly: nothing to do here, just log
  info "Preflight OK."
  mark_phase preflight
}

# ------------------------------------------------------- termux bootstrap -----
phase_termux_bootstrap() {
  step "Phase 20/90 — Termux bootstrap"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: pkg update; pkg install -y ${TERMUX_PKGS[*]}"
    return 0
  fi

  info "Updating Termux package lists..."
  retry 3 pkg update -y

  # x11-repo must be installed (and lists refreshed) before its packages resolve
  if ! termux_pkg_installed x11-repo; then
    info "Installing x11-repo..."
    retry 3 pkg install -y x11-repo
    retry 3 pkg update -y
  else
    info "x11-repo already installed, skipping."
  fi

  local pkg
  for pkg in "${TERMUX_PKGS[@]}"; do
    [ "$pkg" = "x11-repo" ] && continue
    if termux_pkg_installed "$pkg"; then
      info "Termux package '$pkg' already installed, skipping."
    else
      info "Installing Termux package '$pkg'..."
      retry 3 pkg install -y "$pkg"
      termux_pkg_installed "$pkg" \
        || { err "Package '$pkg' still not installed after retries."; exit 1; }
    fi
  done

  command -v proot-distro >/dev/null \
    || { err "proot-distro binary missing after install — aborting."; exit 1; }
  info "Termux bootstrap OK."
  mark_phase termux-bootstrap
}

# ---------------------------------------------------------- debian rootfs -----
phase_debian_rootfs() {
  step "Phase 30/90 — Debian rootfs via proot-distro"

  if debian_rootfs_present; then
    info "Debian rootfs already installed at $DEBIAN_ROOTFS — skipping download."
    info "Debian version: $(din cat /etc/debian_version 2>/dev/null || echo unknown)"
    mark_phase debian-rootfs
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: proot-distro install debian"
    return 0
  fi

  info "Installing Debian rootfs (a few hundred MB download, several minutes)..."
  retry 2 proot-distro install debian
  debian_rootfs_present \
    || { err "Debian rootfs install reported success but rootfs not found."; exit 1; }
  info "Debian $(din cat /etc/debian_version) rootfs installed."
  mark_phase debian-rootfs
}

# ----------------------------------------------------------- debian base ------
phase_debian_base() {
  step "Phase 40/90 — Debian base packages + user"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: apt-get update; apt-get install -y ${DEBIAN_BASE_PKGS[*]}; create user '${USERNAME}'"
    return 0
  fi

  info "Refreshing Debian package lists..."
  retry 3 din env DEBIAN_FRONTEND=noninteractive apt-get update

  local pkg missing=()
  for pkg in "${DEBIAN_BASE_PKGS[@]}"; do
    if debian_pkg_installed "$pkg"; then
      info "Debian package '$pkg' already installed, skipping."
    else
      missing+=("$pkg")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Installing Debian base packages: ${missing[*]}"
    retry 2 din env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    for pkg in "${missing[@]}"; do
      debian_pkg_installed "$pkg" \
        || { err "Debian package '$pkg' missing after install."; exit 1; }
    done
  fi

  # Locale: make sure C.UTF-8-ish sanity (proot default is usually fine)
  if ! din locale -a 2>/dev/null | grep -qi "utf"; then
    warn "No UTF-8 locale found; generating en_US.UTF-8..."
    din sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
    din locale-gen en_US.UTF-8 || warn "locale-gen failed, continuing with C.UTF-8."
  fi

  # Non-root user (KDE apps misbehave as root)
  if debian_user_exists; then
    info "User '$USERNAME' already exists, skipping creation."
  else
    info "Creating user '$USERNAME'..."
    din useradd -m -s /bin/bash "$USERNAME"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" | din tee "/etc/sudoers.d/$USERNAME" >/dev/null
    din chmod 440 "/etc/sudoers.d/$USERNAME"
    din_user sudo -n true \
      || { err "Passwordless sudo check failed for $USERNAME."; exit 1; }
    info "User '$USERNAME' created with passwordless sudo."
  fi

  info "Debian base OK."
  mark_phase debian-base
}

# ----------------------------------------------------------------- plasma -----
phase_plasma() {
  step "Phase 50/90 — KDE Plasma 6 (${PROFILE} profile)"

  local -a pkgs
  if [ "$PROFILE" = "full" ]; then
    pkgs=("${PLASMA_FULL_PKGS[@]}" "${PLASMA_FULL_EXTRA[@]}")
  else
    pkgs=("${PLASMA_MINIMAL_PKGS[@]}")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: apt-get install -y ${pkgs[*]}"
    return 0
  fi

  # Already installed? Check the session binary — the thing we actually need.
  if din test -x /usr/bin/startplasma-x11 2>/dev/null; then
    info "startplasma-x11 already present — Plasma looks installed."
  else
    info "This is the big one: downloading KDE Plasma (~2-4 GB, 20-60 min on Wi-Fi)."
    info "Keep Termux in the foreground; Android may kill background apps."
    confirm "Start the Plasma download now?" || { warn "Plasma install declined — re-run later to continue."; exit 0; }

    local pkg missing=()
    for pkg in "${pkgs[@]}"; do
      if debian_pkg_installed "$pkg"; then
        info "Debian package '$pkg' already installed, skipping."
      else
        missing+=("$pkg")
      fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      info "Installing: ${missing[*]}"
      # --fix-missing + retries: phone networks drop; apt resumes where it can
      retry 2 din env DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing "${missing[@]}"
    fi
    din test -x /usr/bin/startplasma-x11 \
      || { err "startplasma-x11 not found after install — Plasma install incomplete."; exit 1; }
  fi

  # Per-package verification of the requested set (cheap, catches partial states)
  local pkg bad=0
  for pkg in "${pkgs[@]}"; do
    debian_pkg_installed "$pkg" || { warn "Package '$pkg' not installed."; bad=1; }
  done
  [ "$bad" -eq 0 ] || { err "Some Plasma packages are missing — re-run to retry."; exit 1; }

  info "KDE Plasma install verified: $(din dpkg-query -W -f='${Version}' plasma-workspace 2>/dev/null || echo unknown)"
  mark_phase plasma
}

# -------------------------------------------------------------------- gpu -----
phase_gpu() {
  step "Phase 60/90 — GPU acceleration (VirGL/Zink)"

  if [ "$WITH_GPU" -eq 0 ]; then
    info "--no-gpu: skipping VirGL setup (software rendering will be used)."
    mark_phase gpu
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: write ~/start-virgl.sh; wire virpipe env into the session"
    return 0
  fi

  command -v virgl_test_server_android >/dev/null \
    || { err "virgl_test_server_android not found — was virglrenderer-android installed?"; exit 1; }

  cat > "$HOME/start-virgl.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Starts the VirGL 3D acceleration server for Termux:X11 sessions.
# Run once per boot before start-plasma.sh (or let start-plasma.sh do it).
set -euo pipefail
if pgrep -f virgl_test_server_android >/dev/null 2>&1; then
  echo "VirGL server already running."
  exit 0
fi
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.3COMPAT
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export ZINK_DESCRIPTORS=lazy
# Tensor G5 / Mali / Imagination GPUs go through Zink (Vulkan) here.
# Adreno devices could use Turnip instead — out of scope for this script.
nohup virgl_test_server_android --use-egl-surfaceless --use-gles \
  > "$HOME/.linux-install/virgl.log" 2>&1 &
echo "VirGL server started (log: ~/.linux-install/virgl.log)."
EOF
  chmod +x "$HOME/start-virgl.sh"
  info "Wrote ~/start-virgl.sh"

  # Best-effort note: VirGL on Tensor G5 is not guaranteed to beat software GL
  # for every app; the session still works fine if virgl isn't running.
  warn "Note: VirGL/Zink acceleration is best-effort on Tensor G5. If an app"
  warn "renders wrong, stop VirGL (pkill -f virgl_test_server_android) and the"
  warn "session falls back to software rendering automatically."

  mark_phase gpu
}

# ------------------------------------------------------------------ audio -----
phase_audio() {
  step "Phase 70/90 — Audio (PulseAudio)"

  if [ "$WITH_AUDIO" -eq 0 ]; then
    info "--no-audio: skipping PulseAudio setup."
    mark_phase audio
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: configure PulseAudio TCP module; set PULSE_SERVER in session"
    return 0
  fi

  command -v pulseaudio >/dev/null \
    || { err "pulseaudio not found on Termux side."; exit 1; }
  info "PulseAudio present on Termux side; TCP module will be loaded by the launcher."
  mark_phase audio
}

# --------------------------------------------------------------- launchers ----
phase_launchers() {
  step "Phase 80/90 — launcher scripts"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would write: ~/start-plasma.sh ~/stop-plasma.sh ~/start-debian.sh + Debian ~/.launch-plasma.sh"
    return 0
  fi

  # ---- Debian-side X session script (runs as $USERNAME inside proot) ----
  din tee "/home/$USERNAME/.launch-plasma.sh" > /dev/null <<EOF
#!/bin/bash
# KDE Plasma X11 session for Termux:X11. Launched via ~/start-plasma.sh.
set -u
export DISPLAY=:0
export PULSE_SERVER=127.0.0.1
export XDG_RUNTIME_DIR="/tmp/runtime-$USERNAME"
mkdir -p "\$XDG_RUNTIME_DIR" && chmod 700 "\$XDG_RUNTIME_DIR"
EOF
  if [ "$WITH_GPU" -eq 1 ]; then
    din tee -a "/home/$USERNAME/.launch-plasma.sh" > /dev/null <<'EOF'
# VirGL client driver (talks to virgl_test_server_android on the Termux side).
# If VirGL isn't running this is ignored and software GL is used.
export GALLIUM_DRIVER=virpipe
EOF
  fi
  din tee -a "/home/$USERNAME/.launch-plasma.sh" > /dev/null <<'EOF'
# Google Drive auto-sync (non-blocking; logs to ~/.gdrive-sync.log).
# True FUSE mounts don't work inside proot, so this is a two-way sync —
# your files still live at ~/GoogleDrive either way.
if [ -x "$HOME/gdrive-sync.sh" ]; then
  "$HOME/gdrive-sync.sh" >>"$HOME/.gdrive-sync.log" 2>&1 &
fi
EOF
  din tee -a "/home/$USERNAME/.launch-plasma.sh" > /dev/null <<EOF
# Periodic Drive re-sync while the session is alive (every ${SYNC_INTERVAL_MIN}
# min; stopped by ~/stop-plasma.sh via ~/.gdrive-sync-loop.pid).
# Install with --sync-interval-min 0 to keep startup-only syncs.
if [ "${SYNC_INTERVAL_MIN}" -gt 0 ] && [ -x "\$HOME/gdrive-sync-loop.sh" ]; then
  "\$HOME/gdrive-sync-loop.sh" "${SYNC_INTERVAL_MIN}" >>"\$HOME/.gdrive-sync.log" 2>&1 &
fi
EOF
  din tee -a "/home/$USERNAME/.launch-plasma.sh" > /dev/null <<'EOF'
# D-Bus session bus is required by Plasma; --exit-with-session tears the
# session down cleanly when Plasma exits.
exec dbus-launch --exit-with-session startplasma-x11
EOF
  din chmod +x "/home/$USERNAME/.launch-plasma.sh"
  din chown "$USERNAME:$USERNAME" "/home/$USERNAME/.launch-plasma.sh"
  info "Wrote Debian-side ~/.launch-plasma.sh"

  # ---- Termux-side: full Plasma launcher ----
  cat > "$HOME/start-plasma.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Starts the whole stack: audio -> GPU -> X server -> KDE Plasma.
# Then open the Termux:X11 app on your phone.
set -euo pipefail

# Kill stale X server instances (but not this script)
pkill -f "termux-x11 :0" 2>/dev/null || true
sleep 1

# Audio
pulseaudio --start \
  --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
  --exit-idle-time=-1 2>/dev/null || echo "PulseAudio already running or failed to start."
EOF
  if [ "$WITH_GPU" -eq 1 ]; then
    cat >> "$HOME/start-plasma.sh" <<'EOF'

# GPU acceleration (best-effort)
"$HOME/start-virgl.sh"
EOF
  fi
  cat >> "$HOME/start-plasma.sh" <<EOF

# X server (the Termux:X11 *app* must be installed for this to show anything)
termux-x11 :0 >"\$HOME/.linux-install/x11.log" 2>&1 &
sleep 2

# KDE Plasma inside Debian, as $USERNAME (absolute proot-side path — $HOME here
# would be Termux's home, not /home/$USERNAME inside the proot)
echo "Launching KDE Plasma — now open the Termux:X11 app."
proot-distro login --user "$USERNAME" debian -- "/home/$USERNAME/.launch-plasma.sh"
echo "Plasma session ended."
EOF
  # NOTE: inside the heredoc above, \$HOME must expand at *launcher* runtime to
  # the Debian user's home (/home/droid), which is what the quoted \$HOME does.
  chmod +x "$HOME/start-plasma.sh"
  info "Wrote ~/start-plasma.sh"

  cat > "$HOME/stop-plasma.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Stops the Plasma stack.
pkill -f "termux-x11 :0" 2>/dev/null || true
pkill -f virgl_test_server_android 2>/dev/null || true
pulseaudio --kill 2>/dev/null || true
echo "Plasma stack stopped."
EOF
  cat >> "$HOME/stop-plasma.sh" <<EOF
# Stop the Drive periodic re-sync loop inside Debian (it records its PID in
# ~/.gdrive-sync-loop.pid; the loop also removes it on a clean TERM).
proot-distro login --user "${USERNAME}" debian -- bash -c \
  'p=\$(cat ~/.gdrive-sync-loop.pid 2>/dev/null); [ -n "\$p" ] && kill "\$p" 2>/dev/null; rm -f ~/.gdrive-sync-loop.pid' \
  2>/dev/null || true
EOF
  chmod +x "$HOME/stop-plasma.sh"
  info "Wrote ~/stop-plasma.sh"

  cat > "$HOME/start-debian.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Plain Debian shell (no GUI) as $USERNAME.
proot-distro login --user "$USERNAME" debian
EOF
  chmod +x "$HOME/start-debian.sh"
  info "Wrote ~/start-debian.sh"

  mark_phase launchers
}

# -------------------------------------------------------------- gdrive ------
phase_gdrive() {
  step "Phase 82/90 — Google Drive auto-sync (rclone)"

  if [ "$WITH_GDRIVE" -eq 0 ]; then
    info "--no-gdrive: skipping Google Drive setup."
    mark_phase gdrive
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: one-time OAuth if needed; write ~/gdrive-sync.sh + ~/gdrive-sync-loop.sh + ~/setup-gdrive.sh; hook startup + periodic (every ${SYNC_INTERVAL_MIN} min) sync into Plasma startup"
    return 0
  fi

  debian_pkg_installed rclone \
    || { err "rclone not installed in Debian (should have come with the base packages)."; exit 1; }

  # One-time interactive OAuth helper
  din tee "/home/$USERNAME/setup-gdrive.sh" > /dev/null <<'SETUPEOF'
#!/bin/bash
# One-time Google Drive authorization. Run once inside Debian:
#   ~/setup-gdrive.sh
set -euo pipefail
if rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
  echo "Remote 'gdrive' already configured — nothing to do."
  exit 0
fi
cat <<'HELP'
Creates an rclone remote named 'gdrive'.
  * "Storage": choose Google Drive (pick the number listed for it)
  * client_id / client_secret: leave blank (just press Enter)
  * scope: 1 (full access — needed for two-way sync)
  * "Use auto config?": answer n
      -> rclone prints a URL: open it in your Android browser,
         sign in with your Google account, authorize, and paste
         the verification code back here.
HELP
rclone config
if rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
  echo "OK: 'gdrive' remote ready. It will now sync automatically at every Plasma startup."
fi
SETUPEOF
  din chmod +x "/home/$USERNAME/setup-gdrive.sh"
  din chown "$USERNAME:$USERNAME" "/home/$USERNAME/setup-gdrive.sh"

  # The sync script itself — runs at every Plasma startup, non-blocking
  din tee "/home/$USERNAME/gdrive-sync.sh" > /dev/null <<'SYNCEOF'
#!/bin/bash
# Two-way sync between Google Drive and ~/GoogleDrive (rclone bisync).
# Runs automatically at Plasma startup; safe to run by hand any time.
set -u
REMOTE="gdrive:"
LOCAL="$HOME/GoogleDrive"
LOG="$HOME/.gdrive-sync.log"
INIT_FLAG="$HOME/.gdrive-initialized"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Serialize: startup sync, periodic loop and manual runs must never overlap —
# two bisync passes at once can corrupt the sync state. A run that finds the
# lock held simply skips (flock is in util-linux, always present on Debian).
if command -v flock >/dev/null 2>&1; then
  exec 9>"$HOME/.gdrive-sync.lock"
  flock -n 9 || { log "Another sync is already running — skipping this run."; exit 0; }
fi

mkdir -p "$LOCAL"
if ! rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
  log "No 'gdrive' remote yet — run ~/setup-gdrive.sh once to authorize."
  exit 0
fi

if [ ! -f "$INIT_FLAG" ]; then
  log "First sync (bisync --resync) starting — may take a while on big Drives."
  if rclone bisync "$REMOTE" "$LOCAL" --resync --verbose >> "$LOG" 2>&1; then
    touch "$INIT_FLAG"
    log "First sync complete."
  else
    log "First sync hit issues — will retry on next run."
  fi
else
  if rclone bisync "$REMOTE" "$LOCAL" >> "$LOG" 2>&1; then
    log "Sync OK."
  else
    log "Sync reported issues (possible conflict) — inspect $LOG."
  fi
fi
SYNCEOF
  din chmod +x "/home/$USERNAME/gdrive-sync.sh"
  din chown "$USERNAME:$USERNAME" "/home/$USERNAME/gdrive-sync.sh"
  info "Wrote ~/gdrive-sync.sh and ~/setup-gdrive.sh inside Debian."

  # Periodic re-sync loop — started by ~/.launch-plasma.sh at Plasma startup,
  # stopped by ~/stop-plasma.sh. Safe to run by hand: gdrive-sync-loop.sh [minutes]
  din tee "/home/$USERNAME/gdrive-sync-loop.sh" > /dev/null <<'LOOPEOF'
#!/bin/bash
# Periodic Google Drive re-sync. Runs gdrive-sync.sh every N minutes for as
# long as the Plasma session is alive. Overlapping rounds are impossible:
# gdrive-sync.sh serializes itself with flock, so a slow round just means the
# next one skips cleanly.
# Usage: gdrive-sync-loop.sh [minutes]   (default: 30)
set -u
INTERVAL_MIN="${1:-30}"
if ! [[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || [ "$INTERVAL_MIN" -lt 1 ]; then
  echo "Usage: $0 <minutes, >= 1>" >&2
  exit 2
fi
PID_FILE="$HOME/.gdrive-sync-loop.pid"
LOG="$HOME/.gdrive-sync.log"

log() { echo "[$(date '+%F %T')] [sync-loop] $*" >> "$LOG"; }

# Idempotent start: stop any previous loop from an older session first.
if [ -f "$PID_FILE" ]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && kill -0 "$old_pid" 2>/dev/null; then
    log "Stopping previous loop (pid $old_pid)."
    kill "$old_pid" 2>/dev/null || true
    sleep 1
  fi
fi
echo "$$" > "$PID_FILE"

cleanup() {
  log "Periodic re-sync stopped."
  rm -f "$PID_FILE"
  exit 0
}
trap cleanup TERM INT

log "Periodic re-sync started (every ${INTERVAL_MIN} min)."
while true; do
  # Backgrounded sleep + wait: TERM/INT interrupts the wait immediately so
  # ~/stop-plasma.sh (or a newer loop) stops us promptly instead of waiting
  # out the full interval.
  sleep "$((INTERVAL_MIN * 60))" & wait $!
  "$HOME/gdrive-sync.sh" >>"$LOG" 2>&1 || log "Round finished with issues — inspect $LOG."
done
LOOPEOF
  din chmod +x "/home/$USERNAME/gdrive-sync-loop.sh"
  din chown "$USERNAME:$USERNAME" "/home/$USERNAME/gdrive-sync-loop.sh"
  info "Wrote ~/gdrive-sync-loop.sh inside Debian."

  # Remote already configured?
  if din_user rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
    info "rclone remote 'gdrive' already configured — validating it..."
    if din_user rclone lsd gdrive: --max-depth 1 2>&1 | head -5; then
      info "Google Drive remote works."
    else
      warn "Remote exists but a listing failed — the token may be expired."
      warn "If sync fails, re-run ~/setup-gdrive.sh inside Debian."
    fi
  else
    if [ "$ASSUME_YES" -eq 1 ]; then
      warn "--yes: skipping interactive Google Drive OAuth (it needs one manual step)."
      warn "After install, run once inside Debian:  ~/setup-gdrive.sh"
      warn "From then on Drive syncs automatically at every Plasma startup."
    else
      info "One-time Google Drive authorization (one manual step, then fully automatic)."
      if confirm "Authorize Google Drive now?"; then
        din_user "/home/$USERNAME/setup-gdrive.sh"
      else
        warn "Skipped — run ~/setup-gdrive.sh inside Debian whenever you're ready."
      fi
    fi
  fi

  mark_phase gdrive
}

# -------------------------------------------------------------------- vnc -----
phase_vnc() {
  step "Phase 85/90 — VNC fallback (optional)"

  if [ "$WITH_VNC" -eq 0 ]; then
    info "VNC fallback not requested (use --with-vnc to enable)."
    mark_phase vnc
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would: apt-get install -y ${VNC_PKGS[*]}; write ~/.vnc/xstartup; write ~/start-plasma-vnc.sh"
    return 0
  fi

  if ! debian_pkg_installed tigervnc-standalone-server; then
    info "Installing TigerVNC server in Debian..."
    retry 2 din env DEBIAN_FRONTEND=noninteractive apt-get install -y "${VNC_PKGS[@]}"
  else
    info "TigerVNC already installed, skipping."
  fi

  din_user mkdir -p "/home/$USERNAME/.vnc"
  din tee "/home/$USERNAME/.vnc/xstartup" > /dev/null <<'EOF'
#!/bin/bash
export PULSE_SERVER=127.0.0.1
export XDG_RUNTIME_DIR="/tmp/runtime-vnc"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
exec dbus-launch --exit-with-session startplasma-x11
EOF
  din chmod +x "/home/$USERNAME/.vnc/xstartup"
  din chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.vnc"

  cat > "$HOME/start-plasma-vnc.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# VNC fallback: start the VNC server, then connect with any VNC viewer app
# to 127.0.0.1:5901. Set the VNC password first with:  proot-distro login --user $USERNAME debian -- vncpasswd
set -euo pipefail
pulseaudio --start --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" --exit-idle-time=-1 2>/dev/null || true
proot-distro login --user "$USERNAME" debian -- vncserver :1 -geometry 2400x1080 -depth 24
echo "VNC server on 127.0.0.1:5901 — connect with a VNC viewer app."
echo "Stop with: proot-distro login --user $USERNAME debian -- vncserver -kill :1"
EOF
  chmod +x "$HOME/start-plasma-vnc.sh"
  info "Wrote ~/start-plasma-vnc.sh (set VNC password first: proot-distro login --user $USERNAME debian -- vncpasswd)"
  mark_phase vnc
}

# -------------------------------------------------------------- smoke test ----
phase_smoke_test() {
  step "Phase 90/90 — smoke test"

  local fail=0
  check() { # check <description> <command...>
    local desc="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would check: $desc"; return 0; fi
    if "$@" >/dev/null 2>&1; then info "OK: $desc"; else err "FAIL: $desc"; fail=1; fi
  }

  check "Debian proot boots" din true
  check "startplasma-x11 binary exists" din test -x /usr/bin/startplasma-x11
  check "dbus-daemon available" din sh -c "command -v dbus-daemon && command -v dbus-launch"
  check "Debian user '$USERNAME' can sudo" din_user sudo -n true
  check "termux-x11 companion installed" command -v termux-x11
  [ "$WITH_GPU" -eq 1 ] && check "virgl_test_server_android present" command -v virgl_test_server_android
  [ "$WITH_AUDIO" -eq 1 ] && check "pulseaudio present" command -v pulseaudio
  check "launcher ~/start-plasma.sh executable" test -x "$HOME/start-plasma.sh"
  check "launcher ~/start-debian.sh executable" test -x "$HOME/start-debian.sh"
  check "Debian session script present" din test -x "/home/$USERNAME/.launch-plasma.sh"
  if [ "$WITH_GDRIVE" -eq 1 ]; then
    check "Debian gdrive-sync.sh present" din test -x "/home/$USERNAME/gdrive-sync.sh"
    check "Debian gdrive-sync-loop.sh present" din test -x "/home/$USERNAME/gdrive-sync-loop.sh"
    check "Debian setup-gdrive.sh present" din test -x "/home/$USERNAME/setup-gdrive.sh"
    check "rclone installed in Debian" din sh -c "command -v rclone"
  fi

  # Functional: can we start a D-Bus session bus inside the proot? (Plasma needs this)
  if [ "$DRY_RUN" -eq 0 ]; then
    if din_user dbus-launch --exit-with-session true 2>/dev/null; then
      info "OK: D-Bus session bus starts inside proot"
    else
      err "FAIL: D-Bus session bus won't start inside proot (Plasma needs this)"
      fail=1
    fi
  fi

  if [ "$fail" -ne 0 ]; then
    err "Smoke test FAILED — see messages above. Re-run the script to retry failed phases."
    exit 1
  fi
  info "Smoke test PASSED. The stack is installed and coherent."

  warn "Reminder: the Termux:X11 APK (display server app) is a manual install:"
  warn "  https://github.com/termux/termux-x11/releases"
  warn "Without it, ~/start-plasma.sh has nowhere to draw."
  mark_phase smoke-test
}

# ------------------------------------------------------------------ summary ---
print_summary() {
  local used
  used="$(du -sh "$DEBIAN_ROOTFS" 2>/dev/null | cut -f1 || echo ?)"
  cat <<EOF

================================================================
 Debian + KDE Plasma install complete 🐧
================================================================
 Debian version : $(din cat /etc/debian_version 2>/dev/null || echo ?)
 Plasma         : $(din dpkg-query -W -f='${Version}' plasma-workspace 2>/dev/null || echo ?)
 Profile        : ${PROFILE}
 Debian user    : ${USERNAME} (passwordless sudo)
 Rootfs size    : ${used} at ${DEBIAN_ROOTFS}
 GPU accel      : $([ "$WITH_GPU" -eq 1 ] && echo "VirGL/Zink (best-effort on Tensor G5)" || echo "disabled")
 Audio          : $([ "$WITH_AUDIO" -eq 1 ] && echo "PulseAudio" || echo "disabled")
 Log            : ${LOG_FILE}

 TO FINISH (one-time, needs your tap):
   1. Install the Termux:X11 APK:
        https://github.com/termux/termux-x11/releases
      (get app-universal-release.apk; the Termux *package* alone is not enough)
   2. In Termux, run:   ~/start-plasma.sh
   3. Open the Termux:X11 app — Plasma should appear.

 USEFUL COMMANDS:
   ~/start-plasma.sh      full stack: audio -> virgl -> X -> Plasma (+Drive sync)
   ~/stop-plasma.sh       stop everything
   ~/start-debian.sh      plain Debian terminal as ${USERNAME}
   ~/start-virgl.sh       VirGL server alone (auto-run by start-plasma.sh)
$([ "$WITH_VNC" -eq 1 ] && echo "   ~/start-plasma-vnc.sh  VNC fallback on 127.0.0.1:5901")
   proot-distro login --user ${USERNAME} debian     manual proot shell

 INSIDE DEBIAN (as ${USERNAME}):
   ~/gdrive-sync.sh       sync Google Drive <-> ~/GoogleDrive right now
   ~/gdrive-sync-loop.sh [N]  periodic re-sync loop, every N min (auto-started
                          by Plasma, auto-stopped by ~/stop-plasma.sh)
   ~/setup-gdrive.sh      one-time Google Drive authorization (if skipped)
   ~/.gdrive-sync.log     sync log

 TIPS:
   * Google Drive syncs automatically (two-way) at every Plasma startup
     once authorized, then re-syncs every ${SYNC_INTERVAL_MIN} minutes while
     Plasma runs (~/gdrive-sync-loop.sh). Overlapping syncs serialize via
     flock, so a slow round just skips cleanly. Re-run the installer with
     --sync-interval-min N to change the cadence (0 = startup only).
     True FUSE mounts are impossible inside proot, so this is a sync, not
     a mount — files live at ~/GoogleDrive either way.
   * First Plasma launch takes a while (shader/config cache) — be patient.
   * If Android kills Termux in the background: run 'termux-wake-lock'
     (needs the Termux:API app) before long sessions.
   * Plasma is heavy for a phone. If it feels sluggish, re-run with
     --minimal for a lighter desktop, or disable compositing in
     System Settings > Display > Compositor.
   * Re-running this script is safe — finished phases are skipped.
================================================================
EOF
}

# -------------------------------------------------------------------- main ----
main() {
  info "install-debian-kde.sh v${SCRIPT_VERSION} starting (profile=${PROFILE}, user=${USERNAME})"

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    exit 0
  fi

  if [ "$SMOKE_ONLY" -eq 1 ]; then
    debian_rootfs_present || { err "No Debian rootfs found — nothing to smoke-test."; exit 1; }
    phase_smoke_test
    exit 0
  fi

  phase_preflight
  phase_termux_bootstrap
  phase_debian_rootfs
  phase_debian_base
  phase_plasma
  phase_gpu
  phase_audio
  phase_launchers
  phase_gdrive
  phase_vnc
  phase_smoke_test
  print_summary
}

main "$@"
