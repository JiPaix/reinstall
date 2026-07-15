#!/usr/bin/env bash
# =============================================================================
# swapscreen Setup Script
# - Picks a display backend: GNOME (gdctl) or KDE (kscreen-doctor), auto-detected
# - Downloads the prebuilt HTTP server + interactive setup CLI from the Release
#   (or builds them from this checkout with `--local`, for testing engine
#   changes before they're tagged/released)
# - Runs the interactive setup (detect monitors → build monitor/tv/taiko grids),
#   which generates screen/swapscreen.sh from the engine template; on GNOME it
#   also emits a gdm-monitors.xml for the GDM greeter (primary monitor only)
# - Installs swapscreen + swapscreen-server to ~/.local/bin and the systemd
#   units (server + a oneshot that forces monitor mode on every login)
# - GNOME: installs the GDM greeter layout (needs sudo). KDE: installs a root
#   helper + sudoers rule for the TV DRM loop workaround (needs sudo)
# - Opens the server port in the firewall (ufw)
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

# Prompt for the package manager and install one or more packages. Reused by the
# curl / jq / kscreen-doctor prerequisite checks.
install_with_pkg_manager() {  # $@ = packages
  ask "Which package manager do you use?"
  echo "  1) pacman"
  echo "  2) paru"
  echo "  3) yay"
  read -rp "Choice [1-3]: " pm_choice

  local pm
  case $pm_choice in
    1) pm="sudo pacman -S --noconfirm" ;;
    2) pm="paru -S --noconfirm" ;;
    3) pm="yay -S --noconfirm" ;;
    *) print_error "Invalid choice"; exit 1 ;;
  esac

  print_info "Installing $* with: $pm"
  $pm "$@"
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
# STEP 0 — Cleanup previous install if any
# =============================================================================
print_header "Cleaning Up Previous Install"

systemctl --user stop    "$SERVICE" 2>/dev/null && print_ok "Stopped $SERVICE"    || true
systemctl --user disable "$SERVICE" 2>/dev/null && print_ok "Disabled $SERVICE"   || true
systemctl --user disable "$LOGIN_SERVICE" 2>/dev/null && print_ok "Disabled $LOGIN_SERVICE" || true

[ -f "$BIN_DIR/swapscreen-server" ] && rm -f "$BIN_DIR/swapscreen-server" && print_ok "Removed previous server binary"
[ -f "$BIN_DIR/swapscreen" ]        && rm -f "$BIN_DIR/swapscreen"        && print_ok "Removed previous swapscreen script"
[ -f "$UNIT_DIR/$SERVICE" ]         && rm -f "$UNIT_DIR/$SERVICE"         && print_ok "Removed previous service unit"
[ -f "$UNIT_DIR/$LOGIN_SERVICE" ]   && rm -f "$UNIT_DIR/$LOGIN_SERVICE"   && print_ok "Removed previous login unit"

# Remove the KDE DRM helper + sudoers rule only when re-provisioning under a
# non-KDE backend. Under KDE they are kept (STEP 2 overwrites them) so the TV
# connector can still be redetected between this cleanup and the interactive
# setup — removing them here once left a mid-install machine with a forced-off
# TV and no way to wake it.
if [ "$BACKEND" != kde ] && { [ -f /etc/sudoers.d/swapscreen-drm ] || [ -f /usr/local/bin/swapscreen-drm ]; }; then
  sudo rm -f /etc/sudoers.d/swapscreen-drm /usr/local/bin/swapscreen-drm && print_ok "Removed KDE DRM helper + sudoers rule"
fi
# Same for the KDE TV pin (service + helper + captured EDID).
if [ "$BACKEND" != kde ] && [ -f /etc/systemd/system/swapscreen-pin-tv.service ]; then
  sudo systemctl disable --now swapscreen-pin-tv.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/swapscreen-pin-tv.service /usr/local/bin/swapscreen-pin-tv /var/lib/swapscreen/tv-edid.bin
  sudo systemctl daemon-reload
  print_ok "Removed KDE TV pin service + helper + captured EDID"
fi

# Remove the firewall rule (re-added in STEP 7) so it never stacks/goes stale.
if command -v ufw &>/dev/null; then
  sudo ufw delete allow "$SERVER_PORT/tcp" 2>/dev/null && print_ok "Removed ufw rule $SERVER_PORT/tcp" || true
fi

# Remove the engine's runtime KMS cache (leaves sunshine.conf untouched).
[ -f "$SUNSHINE_KMS_CACHE" ]         && rm -f "$SUNSHINE_KMS_CACHE"         && print_ok "Removed Sunshine KMS cache"

systemctl --user daemon-reload
print_ok "Cleanup done"

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

# =============================================================================
# STEP 3b — Pin the TV connector (needs sudo; KDE only)
# =============================================================================
# Capture the TV's EDID now (the setup just required the TV to be detected)
# and pin the connector at every boot: EDID override + forced "connected" via
# amdgpu debugfs. The connector then behaves like a permanently-on TV — no
# detect loop, no wake dance, and `swapscreen --tv` works even with the TV
# off: the signal starts flowing immediately and the TV later boots INTO an
# already-stable signal, the only sequence this class of TV syncs reliably
# (a mode change hitting the TV mid-boot leaves it at "no signal" forever).
if [ "$BACKEND" = kde ]; then
  print_header "TV Connector Pin"

  # Primary connector of TV_PROFILE from this run's profiles.
  # shellcheck disable=SC1091
  source "$WORK/profiles.conf"
  TV_CONN=""
  for rec in "${TV_PROFILE[@]}"; do
    conn=""; prim=false
    for tok in $rec; do
      case "$tok" in
        connector=*)  conn="${tok#connector=}" ;;
        primary=true) prim=true ;;
      esac
    done
    [ -z "$TV_CONN" ] && TV_CONN="$conn"
    if $prim; then TV_CONN="$conn"; break; fi
  done

  EDID_SRC=""
  for f in /sys/class/drm/card*-"$TV_CONN"/edid; do
    [ -e "$f" ] && [ "$(wc -c < "$f")" -gt 0 ] && { EDID_SRC="$f"; break; }
  done

  if [ -z "$TV_CONN" ]; then
    print_warn "No TV connector in TV_PROFILE — skipping pin."
  elif [ -z "$EDID_SRC" ]; then
    print_warn "No readable EDID for $TV_CONN (TV off?) — skipping pin."
    print_warn "The engine falls back to DRM wake/detect; re-run with the TV on to enable the pin."
  else
    PIN_HELPER=/usr/local/bin/swapscreen-pin-tv
    PIN_SERVICE=/etc/systemd/system/swapscreen-pin-tv.service
    PIN_EDID=/var/lib/swapscreen/tv-edid.bin

    sudo install -d -m 0755 /var/lib/swapscreen
    sudo install -m 0644 "$EDID_SRC" "$PIN_EDID"
    print_ok "Captured $TV_CONN EDID → $PIN_EDID ($(wc -c < "$EDID_SRC") bytes)"

    sudo tee "$PIN_HELPER" >/dev/null <<'PINEOF'
#!/usr/bin/env bash
# swapscreen-pin-tv <connector>
# Pin the TV connector: serve the captured EDID from the kernel and force the
# status to "connected" (amdgpu debugfs), then fire a hotplug so the session
# picks it up. Installed by screen.sh; run at boot by swapscreen-pin-tv.service.
set -euo pipefail
shopt -s nullglob
conn="${1:?usage: swapscreen-pin-tv <connector>}"
edid=/var/lib/swapscreen/tv-edid.bin
[ -s "$edid" ] || { echo "missing or empty $edid" >&2; exit 1; }
# debugfs shows up a moment after amdgpu loads — wait for it at early boot.
for _ in $(seq 1 30); do
  dirs=( /sys/kernel/debug/dri/*/"$conn" )
  [ "${#dirs[@]}" -gt 0 ] && break
  sleep 1
done
ok=0
for d in /sys/kernel/debug/dri/*/"$conn"; do
  [ -d "$d" ] || continue
  cat "$edid" > "$d/edid_override"
  echo on > "$d/force"
  if [ -w "$d/trigger_hotplug" ]; then echo 1 > "$d/trigger_hotplug"; fi
  ok=1
done
[ "$ok" = 1 ] || { echo "no debugfs dir for connector $conn" >&2; exit 1; }
PINEOF
    sudo chmod 0755 "$PIN_HELPER"
    print_ok "Installed $PIN_HELPER"

    sudo tee "$PIN_SERVICE" >/dev/null <<PINSVC
[Unit]
Description=Pin the swapscreen TV connector ($TV_CONN) with its captured EDID
ConditionPathExists=/var/lib/swapscreen/tv-edid.bin

[Service]
Type=oneshot
ExecStart=$PIN_HELPER $TV_CONN

[Install]
WantedBy=multi-user.target
PINSVC
    sudo systemctl daemon-reload
    sudo systemctl enable --now swapscreen-pin-tv.service
    print_ok "Enabled swapscreen-pin-tv.service (pin applied now and at every boot)"
  fi
fi

# =============================================================================
# STEP 4 — Install directories
# =============================================================================
print_header "Installing Files"

mkdir -p "$BIN_DIR" "$UNIT_DIR"
print_ok "Ensured $BIN_DIR and $UNIT_DIR exist"

# =============================================================================
# STEP 5 — Install server, generated script, and unit
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
# STEP 6 — Enable and (re)start the services
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
# STEP 7 — Greeter layout
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
# STEP 8 — Firewall (open the server port)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'swapscreen-server'
  print_ok "Allowed $SERVER_PORT/tcp in ufw"
else
  print_warn "ufw not installed — skipping firewall rule for $SERVER_PORT/tcp"
fi

# =============================================================================
# STEP 9 — Sunshine integration (global_prep_cmd + apps.json)
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

  sunshine_service_name() {
    if systemctl --user cat sunshine.service &>/dev/null; then
      echo "sunshine.service"
    else
      echo "app-dev.lizardbyte.app.Sunshine.service"
    fi
  }

  # This run's profiles, produced by swapscreen-setup in STEP 3.
  # shellcheck disable=SC1091
  source "$WORK/profiles.conf"

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
  kde_hdr_fragment() {  # $1=connector $2=true|false
    if [ "$2" = true ]; then
      printf 'output.%s.hdr.enable output.%s.wcg.enable' "$1" "$1"
    else
      printf 'output.%s.hdr.disable' "$1"
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

  if systemctl --user try-restart "$(sunshine_service_name)" 2>/dev/null; then
    print_ok "Restarted Sunshine"
  else
    print_warn "Could not restart Sunshine — restart it manually to apply global_prep_cmd"
  fi
fi

echo
systemctl --user --no-pager --full status "$SERVICE" || true
