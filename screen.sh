#!/usr/bin/env bash
# =============================================================================
# swapscreen Setup Script
# - Picks a display backend: GNOME (gdctl) or KDE (kscreen-doctor), auto-detected
# - Downloads the prebuilt HTTP server + interactive setup CLI from the Release
#   (or builds them from this checkout with `--local`, for testing engine
#   changes before they're tagged/released)
# - Runs the interactive setup (detect monitors → build monitor/tv/taiko grids,
#   then, on KDE, say which screens are TVs), which generates
#   screen/swapscreen.sh from the engine template; on GNOME it also emits a
#   gdm-monitors.xml for the GDM greeter (primary monitor only). The answers
#   are saved (~/.config/swapscreen-setup) and offered back on the next run.
# - Nothing of the previous install is touched before the setup is confirmed:
#   cancelling it leaves the machine as it was.
# - Installs swapscreen + swapscreen-server to ~/.local/bin and the systemd
#   units (server + a oneshot that forces monitor mode on every login)
# - GNOME: installs the GDM greeter layout (needs sudo). KDE: installs a root
#   helper + sudoers rule for the TV DRM loop workaround, and pins every screen
#   declared as a TV with its captured EDID (needs sudo)
# - The server's auth token survives a re-run (delete server.env to rotate it)
# - Opens the server port in the firewall (ufw)
# - Enables Sunshine (if installed) so it starts with every graphical session
# - amdgpu: writes a ddcutilrc that keeps ddcutil's I2C bus scan serial
#   (ddcutil 3.0.0's parallel scan hangs the GPU at login)
# =============================================================================

set -euo pipefail

# --local: build swapscreen-server/swapscreen-setup from this checkout with the
# Go toolchain instead of downloading the Release assets. For testing engine
# changes before they're tagged/released — see .github/workflows/release.yml
# for the exact build this mirrors.
LOCAL=false
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=true ;;
    *) echo "Unknown option: $arg (supported: --local)" >&2; exit 1 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
  echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"
}

print_ok() {
  echo -e "${GREEN}✓${NC} $1"
}

print_info() {
  echo -e "${CYAN}→${NC} $1"
}

print_warn() {
  echo -e "${YELLOW}!${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

ask() {
  echo -e "${BOLD}$1${NC}"
}

# Install one or more packages, asking for the package manager the first time
# only: most runs need nothing installed and never see the question. Reused by
# the curl / jq / kscreen-doctor prerequisite checks.
PKG_MANAGER=""
install_with_pkg_manager() {  # $@ = packages
  if [ -z "$PKG_MANAGER" ]; then
    ask "Which package manager do you use?"
    echo "  1) pacman"
    echo "  2) paru"
    echo "  3) yay"
    read -rp "Choice [1-3]: " pm_choice

    case $pm_choice in
      1) PKG_MANAGER="sudo pacman -S --noconfirm" ;;
      2) PKG_MANAGER="paru -S --noconfirm" ;;
      3) PKG_MANAGER="yay -S --noconfirm" ;;
      *) print_error "Invalid choice"; exit 1 ;;
    esac
  fi

  print_info "Installing $* with: $PKG_MANAGER"
  $PKG_MANAGER "$@"
}

in_list() {  # $1 = needle, $2.. = haystack
  local needle="$1" x; shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# Primary connector of a profile: first record marked primary=true, else
# the first record's connector. Mirrors profile_primary() in the engine.
profile_primary_connector() {  # $1 = array name -> echoes connector
  local -n arr="$1"
  local rec tok conn is_primary first=""
  for rec in "${arr[@]}"; do
    conn=""; is_primary=false
    for tok in $rec; do
      case "$tok" in
        connector=*)  conn="${tok#connector=}" ;;
        primary=true) is_primary=true ;;
      esac
    done
    [ -z "$first" ] && first="$conn"
    $is_primary && { echo "$conn"; return; }
  done
  echo "$first"
}

# One line per profile for the final summary: "DP-3 2560x1440@165, DP-1 …".
profile_summary() {  # $1 = array name
  local -n arr="$1"
  local rec tok conn mode out=""
  for rec in "${arr[@]}"; do
    conn=""; mode=""
    for tok in $rec; do
      case "$tok" in
        connector=*) conn="${tok#connector=}" ;;
        mode=*)      mode="${tok#mode=}" ;;
      esac
    done
    out+="${out:+, }$conn $mode"
  done
  echo "$out"
}

# Pick the desktop backend: BACKEND env override wins, then $XDG_CURRENT_DESKTOP,
# then whichever control tool is on PATH. Echoes gnome|kde|"" (unknown).
detect_backend() {
  local de="${XDG_CURRENT_DESKTOP:-}"
  de="${de,,}"
  case "$de" in
    *kde*|*plasma*) echo kde ;;
    *gnome*)        echo gnome ;;
    *)
      if command -v gdctl &>/dev/null; then echo gnome
      elif command -v kscreen-doctor &>/dev/null; then echo kde
      fi
      ;;
  esac
}

# --- Release source ---------------------------------------------------------
# Binaries are built by GitHub Actions and downloaded from the Release here, so
# this script needs no Go toolchain and works piped from curl. Override REPO or
# pin RELEASE_TAG via the environment if you fork or want a specific version.
REPO="${REPO:-JiPaix/reinstall}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="swapscreen-server.service"
LOGIN_SERVICE="swapscreen-login.service"
SERVER_PORT=7920   # must match Environment=PORT= in $SERVICE
SUNSHINE_KMS_CACHE="$HOME/.config/sunshine/kms_index_cache"
SUNSHINE_CONFIG="$HOME/.config/sunshine/sunshine.conf"
SUNSHINE_APPS="$HOME/.config/sunshine/apps.json"

# Temp workspace for the downloaded binaries + generated script. Auto-removed.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fetch <asset> <dest> — download one asset from the GitHub Release.
fetch() {
  local asset="$1" dest="$2" url
  if [ "$RELEASE_TAG" = latest ]; then
    url="https://github.com/$REPO/releases/latest/download/$asset"
  else
    url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$asset"
  fi
  curl -fSL --proto '=https' --tlsv1.2 "$url" -o "$dest"
}

# =============================================================================
# Prerequisite — display backend (GNOME/gdctl or KDE/kscreen-doctor)
# =============================================================================
# swapscreen drives the display through gdctl (GNOME, ships with `mutter`) or
# kscreen-doctor (KDE, ships with `libkscreen`). Pick the backend up front so a
# machine without the right tool fails cleanly, and so the rest of the install
# (setup CLI, greeter, Sunshine) can branch on it.
BACKEND="${BACKEND:-$(detect_backend)}"
if [ -z "$BACKEND" ]; then
  print_warn "Could not auto-detect the desktop (no gdctl or kscreen-doctor, and \$XDG_CURRENT_DESKTOP unset)."
  ask "Which desktop are you setting up?"
  echo "  1) GNOME (gdctl)"
  echo "  2) KDE (kscreen-doctor)"
  read -rp "Choice [1-2]: " de_choice
  case $de_choice in
    1) BACKEND=gnome ;;
    2) BACKEND=kde ;;
    *) print_error "Invalid choice"; exit 1 ;;
  esac
fi
print_ok "Display backend: $BACKEND"

case "$BACKEND" in
  gnome)
    if ! command -v gdctl &>/dev/null; then
      print_error "gdctl not found — the GNOME backend requires it."
      print_info  "gdctl ships with GNOME (the 'mutter' package). Use a GNOME session, then retry."
      exit 1
    fi ;;
  kde)
    if ! command -v kscreen-doctor &>/dev/null; then
      print_warn "kscreen-doctor not found — the KDE backend requires it (Arch package: libkscreen)"
      install_with_pkg_manager libkscreen
    fi ;;
  *)
    print_error "Unknown backend '$BACKEND' (expected gnome or kde)"; exit 1 ;;
esac

# =============================================================================
# STEP 1 — Get the binaries: local build (--local) or the GitHub Release
# =============================================================================
if $LOCAL; then
  print_header "Building Binaries Locally"

  if ! command -v go &>/dev/null; then
    print_error "go is not installed — --local needs the Go toolchain to build swapscreen-server/swapscreen-setup."
    exit 1
  fi
  if [ ! -f "$SCRIPT_DIR/screen/go.mod" ]; then
    print_error "$SCRIPT_DIR/screen/go.mod not found — --local must run from a checkout of $REPO."
    exit 1
  fi

  print_info "Building from $SCRIPT_DIR/screen (go $(go version | awk '{print $3}'))"
  ( cd "$SCRIPT_DIR/screen" && go build -o "$WORK/swapscreen-server" . )
  print_ok "Built swapscreen-server"
  ( cd "$SCRIPT_DIR/screen" && go build -o "$WORK/swapscreen-setup" ./setup )
  print_ok "Built swapscreen-setup"

  cp "$SCRIPT_DIR/screen/swapscreen-server.service" "$WORK/swapscreen-server.service"
  cp "$SCRIPT_DIR/screen/swapscreen-login.service"  "$WORK/swapscreen-login.service"
  chmod +x "$WORK/swapscreen-server" "$WORK/swapscreen-setup"
  print_ok "Copied unit files from $SCRIPT_DIR/screen"
else
  print_header "Downloading Binaries"

  if ! command -v curl &>/dev/null; then
    print_warn "curl is not installed"
    install_with_pkg_manager curl
  fi

  print_info "Fetching from $REPO ($RELEASE_TAG)"
  fetch swapscreen-server          "$WORK/swapscreen-server"
  fetch swapscreen-setup           "$WORK/swapscreen-setup"
  fetch swapscreen-server.service  "$WORK/swapscreen-server.service"
  fetch swapscreen-login.service   "$WORK/swapscreen-login.service"
  chmod +x "$WORK/swapscreen-server" "$WORK/swapscreen-setup"
  print_ok "Downloaded swapscreen-server, swapscreen-setup, and unit files"
fi

# =============================================================================
# STEP 2 — KDE TV DRM helper (needs sudo; KDE only)
# =============================================================================
# The KDE TV loop workaround writes /sys/class/drm/card*-<conn>/status, which is
# root-owned. Install a tiny root helper + a scoped NOPASSWD sudoers rule so the
# generated swapscreen can toggle it even when triggered non-interactively (the
# login unit's `swapscreen --monitor`, or a Sunshine/Moonlight-driven --tv).
# Installed BEFORE the interactive setup: if a previous install left the TV's
# connector forced off (or KWin dropped it after a power-cycle), the setup can't
# see the TV until it's redetected — which needs this helper.
if [ "$BACKEND" = kde ]; then
  print_header "KDE TV DRM Helper"

  DRM_HELPER=/usr/local/bin/swapscreen-drm
  SUDOERS_FILE=/etc/sudoers.d/swapscreen-drm

  sudo tee "$DRM_HELPER" >/dev/null <<'DRMEOF'
#!/usr/bin/env bash
# swapscreen-drm <connector> <detect|off|on>
# Writes the DRM connector status to break KDE's TV detect loop (TV off but HDMI
# plugged), then emits a synthetic hotplug uevent on the connector's card.
# The uevent is the load-bearing half: a sysfs status write alone fires no
# hotplug event, and KWin only re-probes connectors on hotplug — without it, a
# connector KWin dropped (TV power-cycled while its status was forced off)
# stays invisible until the session restarts.
# Installed by screen.sh; invoked as: sudo swapscreen-drm HDMI-A-1 off
set -euo pipefail
conn="${1:-}"; status="${2:-}"
[[ "$conn" =~ ^[A-Za-z0-9-]+$ ]] || { echo "invalid connector: $conn" >&2; exit 1; }
case "$status" in detect|off|on) ;; *) echo "invalid status: $status" >&2; exit 1 ;; esac
shopt -s nullglob
wrote=0
for f in /sys/class/drm/card*-"$conn"/status; do
  printf '%s\n' "$status" > "$f" && wrote=1
  card="${f#/sys/class/drm/}"; card="${card%%-*}"   # card1-HDMI-A-1 -> card1
  # Extended synthetic-uevent syntax (kernel >= 4.13) forwards HOTPLUG=1 just
  # like a real hotplug event; older kernels only accept the bare action word.
  echo "change 53776170-5363-7265-656e-000000000001 HOTPLUG=1" > "/sys/class/drm/$card/uevent" 2>/dev/null \
    || echo change > "/sys/class/drm/$card/uevent" || true
done
[ "$wrote" = 1 ] || { echo "no DRM connector matched: $conn" >&2; exit 1; }
DRMEOF
  sudo chmod 0755 "$DRM_HELPER"
  print_ok "Installed $DRM_HELPER"

  # Scoped NOPASSWD rule. Validate before installing — a malformed sudoers file
  # can lock you out of sudo entirely.
  TMP_SUDOERS="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$(id -un)" "$DRM_HELPER" > "$TMP_SUDOERS"
  if sudo visudo -cf "$TMP_SUDOERS" >/dev/null; then
    sudo install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
    print_ok "Installed $SUDOERS_FILE (passwordless $DRM_HELPER for $(id -un))"
  else
    print_error "Generated sudoers rule failed validation — skipping."
    print_warn  "The TV workaround will fall back to a password prompt (and stay silent in services)."
  fi
  rm -f "$TMP_SUDOERS"

  print_info "If a TV is missing from the detection below: turn it on, then run"
  print_info "  sudo $DRM_HELPER <connector> detect    (e.g. HDMI-A-1)"
  print_info "wait ~3 seconds, and re-run this script."
fi

# =============================================================================
# STEP 3 — Interactive setup (generates swapscreen.sh + gdm-monitors.xml)
# =============================================================================
print_header "Interactive Display Setup"

print_info "Detecting monitors and building the monitor/tv/taiko layouts."
print_warn "This needs a graphical session ($(case "$BACKEND" in kde) echo kscreen-doctor;; *) echo gdctl;; esac)) and an interactive terminal."

( cd "$WORK" && ./swapscreen-setup \
    -de       "$BACKEND" \
    -profiles "$WORK/profiles.conf" \
    -out      "$WORK/swapscreen.sh" \
    -gdm      "$WORK/gdm-monitors.xml" )

if [ ! -f "$WORK/swapscreen.sh" ]; then
  print_error "setup did not produce swapscreen.sh — aborting"
  exit 1
fi
# The GDM greeter layout is a mutter-only file; the KDE backend doesn't emit it.
if [ "$BACKEND" = gnome ] && [ ! -f "$WORK/gdm-monitors.xml" ]; then
  print_error "setup did not produce gdm-monitors.xml — aborting"
  exit 1
fi
print_ok "Generated swapscreen.sh"

# This run's profiles (BACKEND, TV_CONNECTORS, the three *_PROFILE arrays).
# shellcheck disable=SC1091
source "$WORK/profiles.conf"

# =============================================================================
# STEP 4 — Cleanup previous install if any
# =============================================================================
# Only now that the setup went through: a failed download or a cancelled wizard
# above leaves the previous install running.
print_header "Cleaning Up Previous Install"

systemctl --user stop    "$SERVICE" 2>/dev/null && print_ok "Stopped $SERVICE"    || true
systemctl --user disable "$SERVICE" 2>/dev/null && print_ok "Disabled $SERVICE"   || true
systemctl --user disable "$LOGIN_SERVICE" 2>/dev/null && print_ok "Disabled $LOGIN_SERVICE" || true

[ -f "$BIN_DIR/swapscreen-server" ] && rm -f "$BIN_DIR/swapscreen-server" && print_ok "Removed previous server binary"
[ -f "$BIN_DIR/swapscreen" ]        && rm -f "$BIN_DIR/swapscreen"        && print_ok "Removed previous swapscreen script"
[ -f "$UNIT_DIR/$SERVICE" ]         && rm -f "$UNIT_DIR/$SERVICE"         && print_ok "Removed previous service unit"
[ -f "$UNIT_DIR/$LOGIN_SERVICE" ]   && rm -f "$UNIT_DIR/$LOGIN_SERVICE"   && print_ok "Removed previous login unit"

# Remove the KDE DRM helper + sudoers rule when re-provisioning under a non-KDE
# backend (under KDE, STEP 2 already replaced them).
if [ "$BACKEND" != kde ] && { [ -f /etc/sudoers.d/swapscreen-drm ] || [ -f /usr/local/bin/swapscreen-drm ]; }; then
  sudo rm -f /etc/sudoers.d/swapscreen-drm /usr/local/bin/swapscreen-drm && print_ok "Removed KDE DRM helper + sudoers rule"
fi
# Same for the KDE TV pin (service + helper + captured EDIDs). The connectors
# stay forced until the next boot.
if [ "$BACKEND" != kde ] && [ -f /etc/systemd/system/swapscreen-pin-tv.service ]; then
  sudo systemctl disable --now swapscreen-pin-tv.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/swapscreen-pin-tv.service /usr/local/bin/swapscreen-pin-tv
  sudo rm -rf /var/lib/swapscreen
  sudo systemctl daemon-reload
  print_ok "Removed KDE TV pin service + helper + captured EDIDs"
fi

# Remove the firewall rule (re-added in STEP 10) so it never stacks/goes stale.
if command -v ufw &>/dev/null; then
  sudo ufw delete allow "$SERVER_PORT/tcp" 2>/dev/null && print_ok "Removed ufw rule $SERVER_PORT/tcp" || true
fi

# Remove the engine's runtime KMS cache (leaves sunshine.conf untouched).
[ -f "$SUNSHINE_KMS_CACHE" ]         && rm -f "$SUNSHINE_KMS_CACHE"         && print_ok "Removed Sunshine KMS cache"

systemctl --user daemon-reload
print_ok "Cleanup done"

# =============================================================================
# STEP 5 — Pin the TV connectors (needs sudo; KDE only)
# =============================================================================
# For every screen the wizard was told is a TV: capture its EDID and pin its
# connector at every boot — EDID override + forced "connected" via amdgpu
# debugfs. The connector then behaves like a permanently-on TV — no detect
# loop, no wake dance, and a switch to it works even with the TV off: the
# signal starts flowing immediately and the TV later boots INTO an
# already-stable signal, the only sequence this class of TV syncs reliably
# (a mode change hitting the TV mid-boot leaves it at "no signal" forever).
# One <connector>.bin per pinned TV in /var/lib/swapscreen/edid: the helper
# pins whatever is there, and the engine reads the same files to know which
# connectors are pinned.
PINNED_TVS=()
if [ "$BACKEND" = kde ]; then
  print_header "TV Connector Pin"

  PIN_HELPER=/usr/local/bin/swapscreen-pin-tv
  PIN_SERVICE=/etc/systemd/system/swapscreen-pin-tv.service
  PIN_DIR=/var/lib/swapscreen/edid
  PIN_LEGACY=/var/lib/swapscreen/tv-edid.bin   # the single EDID of earlier versions

  # A swapscreen-setup from a Release that predates the TV question emits no
  # TV_CONNECTORS, and its engine only knows the single-EDID layout: pin the
  # "tv" profile's primary as before, and keep the legacy path alive for it.
  LEGACY_ENGINE=false
  if ! declare -p TV_CONNECTORS &>/dev/null; then
    LEGACY_ENGINE=true
    TV_CONNECTORS=()
    tv_primary="$(profile_primary_connector TV_PROFILE)"
    if [ -n "$tv_primary" ]; then TV_CONNECTORS=("$tv_primary"); fi
  fi

  sudo tee "$PIN_HELPER" >/dev/null <<'PINEOF'
#!/usr/bin/env bash
# swapscreen-pin-tv                        pin every TV connector
# swapscreen-pin-tv --release <connector>  give one back to normal detection
# Pin: for each /var/lib/swapscreen/edid/<connector>.bin, serve that EDID from
# the kernel and force the connector's status to "connected" (amdgpu debugfs),
# then fire a hotplug so the session picks it up.
# Installed by screen.sh; run at boot by swapscreen-pin-tv.service.
set -euo pipefail
shopt -s nullglob
dir=/var/lib/swapscreen/edid

hotplug() {  # $1 = debugfs connector dir
  if [ -w "$1/trigger_hotplug" ]; then echo 1 > "$1/trigger_hotplug"; fi
}

if [ "${1:-}" = --release ]; then
  conn="${2:?usage: swapscreen-pin-tv --release <connector>}"
  [[ "$conn" =~ ^[A-Za-z0-9-]+$ ]] || { echo "invalid connector: $conn" >&2; exit 1; }
  ok=0
  for d in /sys/kernel/debug/dri/*/"$conn"; do
    [ -d "$d" ] || continue
    echo reset > "$d/edid_override"
    echo unspecified > "$d/force"
    hotplug "$d"
    ok=1
  done
  [ "$ok" = 1 ] || { echo "no debugfs dir for connector $conn" >&2; exit 1; }
  exit 0
fi

edids=( "$dir"/*.bin )
[ "${#edids[@]}" -gt 0 ] || { echo "no captured EDID in $dir" >&2; exit 1; }
failed=0
for edid in "${edids[@]}"; do
  conn="$(basename "$edid" .bin)"
  [ -s "$edid" ] || { echo "empty $edid" >&2; failed=1; continue; }
  # debugfs shows up a moment after amdgpu loads — wait for it at early boot
  # (30 s for the whole run, not per connector).
  while [ "$SECONDS" -lt 30 ]; do
    dirs=( /sys/kernel/debug/dri/*/"$conn" )
    [ "${#dirs[@]}" -gt 0 ] && break
    sleep 1
  done
  ok=0
  for d in /sys/kernel/debug/dri/*/"$conn"; do
    [ -d "$d" ] || continue
    cat "$edid" > "$d/edid_override"
    echo on > "$d/force"
    hotplug "$d"
    ok=1
  done
  [ "$ok" = 1 ] || { echo "no debugfs dir for connector $conn" >&2; failed=1; }
done
exit "$failed"
PINEOF
  sudo chmod 0755 "$PIN_HELPER"
  print_ok "Installed $PIN_HELPER"

  sudo install -d -m 0755 "$PIN_DIR"

  # Earlier versions kept a single EDID, for the connector named in the unit:
  # file it under that connector so a TV that is off right now stays pinned.
  if [ -f "$PIN_LEGACY" ] && [ ! -L "$PIN_LEGACY" ]; then
    old_conn="$(sed -n 's|^ExecStart=.*/swapscreen-pin-tv[[:space:]]\{1,\}\([A-Za-z0-9-]\{1,\}\)[[:space:]]*$|\1|p' "$PIN_SERVICE" 2>/dev/null | head -n1 || true)"
    if [ -n "$old_conn" ] && [ ! -e "$PIN_DIR/$old_conn.bin" ]; then
      sudo mv "$PIN_LEGACY" "$PIN_DIR/$old_conn.bin"
    fi
  fi
  sudo rm -f "$PIN_LEGACY"

  for conn in "${TV_CONNECTORS[@]}"; do
    edid_src=""
    for f in /sys/class/drm/card*-"$conn"/edid; do
      [ -e "$f" ] && [ "$(wc -c < "$f")" -gt 0 ] && { edid_src="$f"; break; }
    done
    if [ -n "$edid_src" ]; then
      sudo install -m 0644 "$edid_src" "$PIN_DIR/$conn.bin"
      print_ok "$conn: captured its EDID ($(wc -c < "$edid_src") bytes)"
    elif [ -s "$PIN_DIR/$conn.bin" ]; then
      print_ok "$conn: no EDID to read right now — kept the one captured by a previous run"
    else
      print_warn "$conn: no readable EDID (TV off?) — not pinned."
      print_warn "The engine falls back to DRM wake/detect for it; re-run with the TV on to pin it."
      continue
    fi
    PINNED_TVS+=("$conn")
  done

  # A connector that was pinned and is no longer a TV: hand it back to normal
  # detection now rather than at the next boot.
  for f in "$PIN_DIR"/*.bin; do
    [ -e "$f" ] || continue
    conn="$(basename "$f" .bin)"
    in_list "$conn" "${PINNED_TVS[@]}" && continue
    sudo rm -f "$f"
    if sudo "$PIN_HELPER" --release "$conn"; then
      print_ok "$conn: no longer a TV — pin released"
    else
      print_warn "$conn: no longer a TV — its pin is removed, but stays applied until the next boot"
    fi
  done

  if [ ${#PINNED_TVS[@]} -gt 0 ]; then
    sudo tee "$PIN_SERVICE" >/dev/null <<PINSVC
[Unit]
Description=Pin the swapscreen TV connectors (${PINNED_TVS[*]}) with their captured EDID
ConditionDirectoryNotEmpty=$PIN_DIR

[Service]
Type=oneshot
ExecStart=$PIN_HELPER

[Install]
WantedBy=multi-user.target
PINSVC
    if $LEGACY_ENGINE; then
      sudo ln -sf "edid/${PINNED_TVS[0]}.bin" "$PIN_LEGACY"
    fi
    sudo systemctl daemon-reload
    sudo systemctl enable swapscreen-pin-tv.service
    sudo systemctl restart swapscreen-pin-tv.service
    print_ok "Enabled swapscreen-pin-tv.service (${PINNED_TVS[*]} pinned now and at every boot)"
  elif [ -f "$PIN_SERVICE" ]; then
    sudo systemctl disable --now swapscreen-pin-tv.service 2>/dev/null || true
    sudo rm -f "$PIN_SERVICE"
    sudo systemctl daemon-reload
    print_ok "No TV left to pin — removed swapscreen-pin-tv.service"
  else
    print_info "No TV to pin."
  fi
fi

# =============================================================================
# STEP 6 — Install directories
# =============================================================================
print_header "Installing Files"

mkdir -p "$BIN_DIR" "$UNIT_DIR"
print_ok "Ensured $BIN_DIR and $UNIT_DIR exist"

# =============================================================================
# STEP 7 — Install server, generated script, and unit
# (swapscreen-setup is a build-time tool — not installed; reconfigure = re-run.)
# =============================================================================
cp "$WORK/swapscreen-server" "$BIN_DIR/swapscreen-server"
chmod +x "$BIN_DIR/swapscreen-server"
print_ok "Installed $BIN_DIR/swapscreen-server"

cp "$WORK/swapscreen.sh" "$BIN_DIR/swapscreen"
chmod +x "$BIN_DIR/swapscreen"
print_ok "Installed $BIN_DIR/swapscreen"

cp "$WORK/$SERVICE" "$UNIT_DIR/$SERVICE"
print_ok "Installed $UNIT_DIR/$SERVICE"

cp "$WORK/$LOGIN_SERVICE" "$UNIT_DIR/$LOGIN_SERVICE"
print_ok "Installed $UNIT_DIR/$LOGIN_SERVICE"

# =============================================================================
# STEP 7b — HTTP server access control (optional)
# =============================================================================
# Neither check is required: an empty ALLOWED_IPS means no IP restriction, and
# the token is only enforced because the server checks it unconditionally once
# present in server.env. Written before the (re)start below so the fresh binary
# picks it up immediately via EnvironmentFile=.
# A token from a previous run is kept: whatever calls the server (a Home
# Assistant automation, …) has it stored, and a new one would lock it out with
# a bare 401. Delete server.env before running this to get a new token.
print_header "HTTP Server Access Control"

SERVER_CONFIG_DIR="$HOME/.config/swapscreen-server"
mkdir -p "$SERVER_CONFIG_DIR"
chmod 700 "$SERVER_CONFIG_DIR"

AUTH_TOKEN=""
if [ -f "$SERVER_CONFIG_DIR/server.env" ]; then
  AUTH_TOKEN="$(sed -n 's/^AUTH_TOKEN=//p' "$SERVER_CONFIG_DIR/server.env" | head -n1)"
fi

ask "Restrict swapscreen-server access by IP?"
print_info "Comma-separated IPs and/or CIDRs, mixed freely (e.g. 192.168.1.3,10.0.0.0/24)."
read -rp "Allowed IPs (blank = no restriction): " ALLOWED_IPS

if [ -n "$AUTH_TOKEN" ]; then
  token_note="Kept the existing auth token"
else
  AUTH_TOKEN="$(head -c 32 /dev/urandom | base64)"
  token_note="Generated auth token"
fi

{
  echo "ALLOWED_IPS=$ALLOWED_IPS"
  echo "AUTH_TOKEN=$AUTH_TOKEN"
} > "$SERVER_CONFIG_DIR/server.env"
chmod 600 "$SERVER_CONFIG_DIR/server.env"

if [ -n "$ALLOWED_IPS" ]; then
  print_ok "Restricting access to: $ALLOWED_IPS"
else
  print_warn "No IP restriction set — reachable from any host that can route to it"
fi
print_ok "$token_note (send it as 'Authorization: Bearer <token>')"

# =============================================================================
# STEP 8 — Enable and (re)start the services
# =============================================================================
print_header "Enabling Services"

# Order matters: daemon-reload so systemd sees the new units, then enable to
# create the graphical-session.target.wants symlinks, then restart so an
# already-running instance picks up the freshly built binary.
systemctl --user daemon-reload
print_ok "Reloaded systemd user units"

systemctl --user enable "$SERVICE"
print_ok "Enabled $SERVICE"

systemctl --user restart "$SERVICE"
print_ok "(Re)started $SERVICE"

systemctl --user enable --now "$LOGIN_SERVICE"
print_ok "Enabled $LOGIN_SERVICE (and applied monitor mode now)"

print_info "Note: both units are WantedBy=graphical-session.target, so they only"
print_info "auto-start inside a graphical login session (not over plain SSH)."

# =============================================================================
# STEP 9 — Greeter layout
# =============================================================================
# GNOME: install a mutter monitors.xml so the GDM greeter shows only the primary
# monitor (rest disabled). KDE (SDDM) has no mutter-style greeter layout, so we
# skip it: SDDM shows login on all connected screens and swapscreen-login.service
# switches to monitor mode right after login.
print_header "Greeter Layout"

if [ "$BACKEND" != gnome ]; then
  print_info "KDE backend — skipping GDM greeter layout."
  print_info "SDDM will show the login prompt on all connected screens; $LOGIN_SERVICE"
  print_info "then forces monitor mode once you're logged in."
else
  GDM_DIR=""
  for d in /var/lib/gdm/seat0/config /var/lib/gdm/.config; do
    [ -d "$d" ] && { GDM_DIR="$d"; break; }
  done

  if [ -z "$GDM_DIR" ]; then
    print_warn "GDM greeter config dir not found — log in via GDM at least once, then re-run ./screen.sh"
  else
    OWNER="$(sudo stat -c '%u:%g' "$GDM_DIR")"
    sudo install -m 0600 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$WORK/gdm-monitors.xml" "$GDM_DIR/monitors.xml"
    print_ok "Installed GDM greeter layout → $GDM_DIR/monitors.xml"
    print_info "Roll back anytime with: sudo rm $GDM_DIR/monitors.xml"
  fi
fi

# =============================================================================
# STEP 10 — Firewall (open the server port)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'swapscreen-server'
  print_ok "Allowed $SERVER_PORT/tcp in ufw"
else
  print_warn "ufw not installed — skipping firewall rule for $SERVER_PORT/tcp"
fi

# =============================================================================
# STEP 11 — Sunshine integration (global_prep_cmd + apps.json)
# =============================================================================
# Sunshine's sunshine.conf has a `global_prep_cmd` setting: a JSON array of
# {do, undo} commands run before/after every streamed app (unless that app
# sets "exclude-global-prep-cmd": true). We use it to bump the TV connector's
# scaling and push the client's HDR capability to both connectors on stream
# start, and revert both on stream end — driven by this run's monitor/tv
# profiles. The commands are backend-specific: GNOME uses the external
# `displayconfig-mutter` helper (assumed on PATH); KDE uses `kscreen-doctor`.
# apps.json just needs the two baseline app entries to exist so Sunshine has
# something to stream.
print_header "Sunshine Integration"

sunshine_installed() {
  systemctl --user cat sunshine.service &>/dev/null \
    || systemctl --user cat app-dev.lizardbyte.app.Sunshine.service &>/dev/null
}

if ! sunshine_installed; then
  print_warn "Sunshine not installed — skipping apps.json/global_prep_cmd setup"
else
  if ! command -v jq &>/dev/null; then
    print_warn "jq is not installed"
    install_with_pkg_manager jq
  fi

  # The unit's real name. Recent packages ship app-dev.lizardbyte.app.Sunshine
  # with `Alias=sunshine.service`, and `systemctl enable` refuses an alias
  # ("Refusing to operate on linked unit file") — so resolve it through Id.
  sunshine_service_name() {
    local id
    id="$(systemctl --user show -p Id --value sunshine.service 2>/dev/null)"
    if [ -n "$id" ] && systemctl --user cat "$id" &>/dev/null; then
      echo "$id"
    else
      echo "app-dev.lizardbyte.app.Sunshine.service"
    fi
  }

  # A specific key's value for a connector within a profile (with a default).
  profile_connector_field() {  # $1=array $2=connector $3=key $4=default
    local -n arr="$1"
    local rec tok conn val
    for rec in "${arr[@]}"; do
      conn=""; val="$4"
      for tok in $rec; do
        case "$tok" in
          connector=*)   conn="${tok#connector=}" ;;
          "$3"=*)        val="${tok#"$3"=}" ;;
        esac
      done
      [ "$conn" = "$2" ] && { echo "$val"; return; }
    done
    echo "$4"
  }

  # kscreen-doctor HDR/WCG ops for a connector given its target HDR state.
  # SDR must disable WCG too: KWin keeps them as separate flags, and HDR off
  # with WCG on still signals BT.2020 colorimetry — the Vestel TV stays in its
  # HDR picture mode on that alone and shows the SDR content with wrong colors.
  kde_hdr_fragment() {  # $1=connector $2=true|false
    if [ "$2" = true ]; then
      printf 'output.%s.hdr.enable output.%s.wcg.enable' "$1" "$1"
    else
      printf 'output.%s.hdr.disable output.%s.wcg.disable' "$1" "$1"
    fi
  }

  TV_PRIMARY="$(profile_primary_connector TV_PROFILE)"
  MON_PRIMARY="$(profile_primary_connector MONITOR_PROFILE)"
  TV_HDR_UNDO=false
  [ "$(profile_connector_field TV_PROFILE "$TV_PRIMARY" color default)" = bt2100 ] && TV_HDR_UNDO=true
  MON_HDR_UNDO=false
  [ "$(profile_connector_field MONITOR_PROFILE "$MON_PRIMARY" color default)" = bt2100 ] && MON_HDR_UNDO=true

  # ${SUNSHINE_CLIENT_HDR} is Sunshine's own env var, evaluated by the `sh -c`
  # below at stream time — kept literal here via a single-quoted printf format
  # so this script's own expansion never touches it.
  if [ "$BACKEND" = kde ]; then
    # KDE: kscreen-doctor. Bump the TV scale during a stream and follow the
    # client's HDR capability on both connectors, restoring the profile's scale
    # and HDR state on stream end. HDR/WCG ops are best-effort (|| true) so an
    # SDR-only display can't break the stream.
    TV_SCALE="$(profile_connector_field TV_PROFILE "$TV_PRIMARY" scale 1)"
    DO_CMD=$(printf 'sh -c "kscreen-doctor output.%s.scale.3 || true; if [ ${SUNSHINE_CLIENT_HDR:-false} = true ]; then kscreen-doctor %s %s || true; else kscreen-doctor %s %s || true; fi"' \
      "$TV_PRIMARY" \
      "$(kde_hdr_fragment "$TV_PRIMARY" true)"  "$(kde_hdr_fragment "$MON_PRIMARY" true)" \
      "$(kde_hdr_fragment "$TV_PRIMARY" false)" "$(kde_hdr_fragment "$MON_PRIMARY" false)")
    UNDO_CMD=$(printf 'sh -c "kscreen-doctor output.%s.scale.%s || true; kscreen-doctor %s || true; kscreen-doctor %s || true"' \
      "$TV_PRIMARY" "$TV_SCALE" \
      "$(kde_hdr_fragment "$TV_PRIMARY" "$TV_HDR_UNDO")" \
      "$(kde_hdr_fragment "$MON_PRIMARY" "$MON_HDR_UNDO")")
  else
    # GNOME: displayconfig-mutter. Scaling literals (300/200) left untouched.
    DO_CMD=$(printf 'sh -c "displayconfig-mutter set --connector %s --scaling 300 --hdr ${SUNSHINE_CLIENT_HDR:-false} || true; displayconfig-mutter set --connector %s --hdr ${SUNSHINE_CLIENT_HDR:-false} || true"' \
      "$TV_PRIMARY" "$MON_PRIMARY")
    UNDO_CMD=$(printf 'sh -c "displayconfig-mutter set --connector %s --scaling 200 --hdr %s || true; displayconfig-mutter set --connector %s --hdr %s || true"' \
      "$TV_PRIMARY" "$TV_HDR_UNDO" "$MON_PRIMARY" "$MON_HDR_UNDO")
  fi

  PREP_ITEM=$(jq -n --arg do "$DO_CMD" --arg undo "$UNDO_CMD" '{do: $do, undo: $undo}')
  print_ok "Computed global prep-cmd ($BACKEND; tv=$TV_PRIMARY, monitor=$MON_PRIMARY)"

  # -- sunshine.conf: upsert the global_prep_cmd line --------------------------
  # sunshine.conf is a flat key = value file, not JSON, so we can't jq the
  # whole file — only this key's value is inline JSON. sed is avoided because
  # the value contains $, {, and " which are unsafe as a sed replacement.
  set_conf_kv() {  # $1=file $2=key $3=value (single line, no newlines)
    local file="$1" key="$2" value="$3" tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v k="$key" '$0 !~ ("^[[:space:]]*" k "[[:space:]]*=")' "$file" > "$tmp"
    printf '%s = %s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
  }
  set_conf_kv "$SUNSHINE_CONFIG" global_prep_cmd "$(jq -c -n --argjson item "$PREP_ITEM" '[$item]')"
  print_ok "Updated $SUNSHINE_CONFIG (global_prep_cmd)"

  # -- apps.json: bootstrap Desktop + Steam Big Picture if missing -------------
  # No prep-cmd on Desktop — that logic now lives in global_prep_cmd above.
  CANONICAL_APPS=$(jq -n '[
    {
      "auto-detach": true,
      "exclude-global-prep-cmd": false,
      "exit-timeout": 5,
      "image-path": "desktop.png",
      "name": "Desktop",
      "wait-all": true
    },
    {
      "detached": ["setsid steam steam://open/bigpicture"],
      "image-path": "steam.png",
      "name": "Steam Big Picture",
      "prep-cmd": [
        { "do": "", "undo": "setsid steam steam://close/bigpicture" }
      ]
    }
  ]')

  mkdir -p "$(dirname "$SUNSHINE_APPS")"
  if [ ! -f "$SUNSHINE_APPS" ]; then
    jq -n --argjson apps "$CANONICAL_APPS" \
      '{apps: $apps, env: {"PATH": "$(PATH):$(HOME)/.local/bin"}}' \
      > "$SUNSHINE_APPS"
    print_ok "Created $SUNSHINE_APPS"
  else
    APPS_JSON_TMP="$(mktemp)"
    jq --argjson newapps "$CANONICAL_APPS" '
      (.apps // []) as $existing
      | .apps = ($existing + [
          $newapps[] | select(.name as $n | ($existing | any(.name == $n)) | not)
        ])
    ' "$SUNSHINE_APPS" > "$APPS_JSON_TMP" && mv "$APPS_JSON_TMP" "$SUNSHINE_APPS"
    print_ok "Updated $SUNSHINE_APPS (added any missing apps by name; existing apps/env untouched)"
  fi

  # The Sunshine package ships its user unit (WantedBy=graphical-session.target)
  # but doesn't enable it, so on a fresh install Sunshine only runs once started
  # by hand and is gone after the next reboot. Enable it, then restart (which
  # also starts it if it wasn't running) so global_prep_cmd applies now.
  SUNSHINE_SERVICE="$(sunshine_service_name)"
  if systemctl --user enable "$SUNSHINE_SERVICE" 2>/dev/null; then
    print_ok "Enabled $SUNSHINE_SERVICE (starts with every graphical session)"
  else
    print_warn "Could not enable $SUNSHINE_SERVICE — enable it manually"
  fi
  if systemctl --user restart "$SUNSHINE_SERVICE" 2>/dev/null; then
    print_ok "(Re)started Sunshine"
  else
    print_warn "Could not (re)start Sunshine — start it manually to apply global_prep_cmd"
  fi
fi

# =============================================================================
# STEP 12 — ddcutil parallel bus-scan workaround (amdgpu)
# =============================================================================
# ddcutil 3.0.0 lowered --i2c-bus-checks-async-min / --i2c-init-async-min from
# 99 to 4 (upstream commit 09263068). amdgpu exposes an I2C bus per connector
# plus one per DisplayPort AUX channel, so most cards reach that threshold and
# get their buses probed from several threads at once — which hangs the GPU
# within seconds ("Fence fallback timer expired" -> "device lost from bus").
# powerdevil runs that scan at every Plasma login, so the session freezes; the
# ddcutil CLI can trigger it too. 99 restores the serial scan of 2.2.x, where
# this file is a no-op. Only written when there is no ddcutilrc already, so a
# hand-made one is never clobbered.
# https://github.com/rockowitz/ddcutil/issues/629
print_header "ddcutil Workaround (amdgpu)"

DDCUTIL_RC="$HOME/.config/ddcutil/ddcutilrc"

amdgpu_bound() {
  local d
  for d in /sys/bus/pci/drivers/amdgpu/0000:*; do
    [ -e "$d" ] && return 0
  done
  return 1
}

write_ddcutilrc() {  # $1 = path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'DDCEOF'
# Written by reinstall/screen.sh (see its "ddcutil Workaround" step).
# ddcutil 3.0.0 scans I2C buses in parallel once there are enough of them
# (threshold 4); on amdgpu that hangs the GPU. 99 keeps the scan serial, as in
# 2.2.x, where this file is a no-op.
# https://github.com/rockowitz/ddcutil/issues/629

[libddcutil]
options = --i2c-bus-checks-async-min 99 --i2c-init-async-min 99

[ddcutil]
options = --i2c-bus-checks-async-min 99 --i2c-init-async-min 99
DDCEOF
}

if ! amdgpu_bound; then
  print_info "No amdgpu device — skipping."
elif [ -f "$DDCUTIL_RC" ]; then
  if grep -q -- '--i2c-bus-checks-async-min' "$DDCUTIL_RC"; then
    print_ok "$DDCUTIL_RC already sets the bus-scan threshold — left untouched"
  else
    print_warn "$DDCUTIL_RC exists — not overwriting it. Add to its [libddcutil] and [ddcutil] sections:"
    print_info "  options = --i2c-bus-checks-async-min 99 --i2c-init-async-min 99"
  fi
else
  write_ddcutilrc "$DDCUTIL_RC"
  print_ok "Wrote $DDCUTIL_RC (serial I2C bus scan)"
fi

print_header "Setup Complete"
if ! systemctl --user is-active -q "$SERVICE"; then
  print_warn "$SERVICE is not running — check: systemctl --user status $SERVICE"
  echo
fi
echo -e "  monitor:      ${CYAN}$(profile_summary MONITOR_PROFILE)${NC}"
echo -e "  tv:           ${CYAN}$(profile_summary TV_PROFILE)${NC}"
echo -e "  taiko:        ${CYAN}$(profile_summary TAIKO_PROFILE)${NC}"
if [ "$BACKEND" = kde ]; then
  tv_line=""
  for conn in "${TV_CONNECTORS[@]}"; do
    if in_list "$conn" "${PINNED_TVS[@]}"; then state=pinned; else state="not pinned"; fi
    tv_line+="${tv_line:+, }$conn ($state)"
  done
  echo -e "  TVs:          ${CYAN}${tv_line:-none}${NC}"
fi
echo -e "  Switch:       ${CYAN}swapscreen --monitor | --tv | --taiko${NC} (no option: toggle; --help)"
echo -e "  Server:       ${CYAN}http://localhost:$SERVER_PORT/mode${NC}"
echo -e "  Access token: ${CYAN}$AUTH_TOKEN${NC}"
echo -e "  Token file:   ${CYAN}$SERVER_CONFIG_DIR/server.env${NC}"
