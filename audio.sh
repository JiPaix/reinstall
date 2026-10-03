#!/bin/bash
# =============================================================================
# PipeWire Audio Setup Script
# - Checks the dependencies, gets the binaries (GitHub Release, or built from
#   this checkout with `--local`), then drives the Go interactive setup CLI
#   (audio/setup → soundbar-setup) which renders all configs from templates
#   straight to their final locations.
# - This script orchestrates: cleanup, running the wizard, service reload, the
#   optional extras below, and the firewall.
# - Each output picks its own extras in the wizard: equalizer, left/right swap
#   (a second, processed output in front of the device, there only while the
#   device is, and ranked in its place; the device itself goes last) and
#   keepalive tone (audio-watch.service, which also hands the default output
#   back to the priority order whenever an output comes or goes).
# - The equalizers are switched on and off together, at any time: `audio-eq
#   on|off`, or POST /eq/on and /eq/off on the status server. Swaps stay.
# - Optional: a root oneshot reconnects every paired Bluetooth device at boot.
# - Optional MPD server on PipeWire, with a generated password.
# - Microphones never suspend (no crackle at the start of a recording; the
#   mic-wake unit opens them once per WirePlumber start), and the one picked in
#   the wizard is pinned as the default source.
# =============================================================================

set -e

# --local: build soundbar-status-server/soundbar-setup from this checkout with
# the Go toolchain instead of downloading the Release assets. For testing
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

WIREPLUMBER_CONF_DIR="$HOME/.config/wireplumber/wireplumber.conf.d"
PIPEWIRE_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SCRIPTS_DIR="$HOME/.local/bin"
UDEV_DIR="/etc/udev/rules.d"

# --- Release source ---------------------------------------------------------
# Binaries are built by GitHub Actions and downloaded from the Release here, so
# this script needs no Go toolchain and works piped from curl. Override REPO or
# pin RELEASE_TAG via the environment if you fork or want a specific version.
REPO="${REPO:-JiPaix/reinstall}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

# Temp workspace for the downloaded binaries + staged config. Auto-removed.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GENERATED_DIR="$WORK/generated"
SERVER_PORT=7921   # must match Environment=PORT= in soundbar-status-server.service

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

print_header() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
print_ok()     { echo -e "${GREEN}✓${NC} $1"; }
print_info()   { echo -e "${CYAN}→${NC} $1"; }
print_warn()   { echo -e "${YELLOW}!${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1"; }
ask()          { echo -e "${BOLD}$1${NC}"; }

# Install one or more packages, asking for the package manager the first time
# only: most runs need nothing installed and never see the question.
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

# Addresses of the Bluetooth devices that have an output or a mic right now.
bt_audio_macs() {
  { pactl list short sinks; pactl list short sources; } 2>/dev/null |
    sed -n 's/^[0-9]*\tbluez_\(output\|input\)\.\(\([0-9A-Fa-f]\{2\}[_:]\)\{5\}[0-9A-Fa-f]\{2\}\).*/\2/p' |
    tr '_' ':' | sort -u
}

bt_has_audio() {  # $1 = address
  bt_audio_macs | grep -qixF -- "$1"
}

# restart_pipewire <settle-seconds>
# Restarting drops the Bluetooth audio devices (WirePlumber holds their audio
# endpoints) and most speakers don't come back on their own: the ones that were
# there are reconnected, so the wizard — and you — find them again.
restart_pipewire() {
  local macs mac name
  macs="$(bt_audio_macs)"

  systemctl --user kill pipewire-pulse wireplumber pipewire 2>/dev/null || true
  sleep 2
  systemctl --user start pipewire
  systemctl --user start wireplumber
  systemctl --user start pipewire-pulse
  sleep "$1"

  [ -n "$macs" ] || return 0
  command -v bluetoothctl &>/dev/null || return 0

  for mac in $macs; do
    name="$(timeout 5 bluetoothctl info "$mac" 2>/dev/null | sed -n 's/^[[:space:]]*Name: //p' | head -n1)" || true
    name="${name:-$mac}"
    # WirePlumber may still be registering its endpoints: a first connect can
    # be refused ("Protocol not available"), hence the retries.
    for _ in 1 2 3 4 5; do
      bt_has_audio "$mac" && break
      timeout 20 bluetoothctl connect "$mac" >/dev/null 2>&1 || true
      sleep 3
    done
    if bt_has_audio "$mac"; then
      print_ok "Bluetooth: $name is back"
    else
      print_warn "Bluetooth: $name did not come back — reconnect it by hand"
    fi
  done
}

# =============================================================================
# STEP 1 — Prerequisites (you install these; we only check)
# =============================================================================
# This configures an existing PipeWire setup; it does not install PipeWire or
# the EQ/processing helpers. Packaging varies by distribution (pre-installed,
# split packages, …), so that is left to you. Everything is checked before the
# cleanup below touches the current setup.
print_header "Checking Prerequisites"

for cmd in pipewire pactl wireplumber; do
  if ! command -v "$cmd" &>/dev/null; then
    print_error "$cmd not found — the PipeWire stack must be installed and running."
    print_info  "Install pipewire, pipewire-pulse and wireplumber for your distro, then retry."
    exit 1
  fi
done

missing=()
command -v ffmpeg &>/dev/null || missing+=("ffmpeg")
# pw-cat plays the keepalive tone; wpctl resets the default output; pw-cli
# switches the equalizers.
command -v pw-cat &>/dev/null || missing+=("pw-cat (pipewire)")
command -v pw-cli &>/dev/null || missing+=("pw-cli (pipewire)")
command -v wpctl &>/dev/null || missing+=("wpctl (wireplumber)")
# mbeq_1197.so comes from swh-plugins and needs the ladspa runtime. find exits 0
# even with no match, so test that it actually printed a path.
[ -n "$(find /usr/lib/ladspa -name 'mbeq_1197.so' 2>/dev/null)" ] || missing+=("ladspa + swh-plugins")

if [ ${#missing[@]} -gt 0 ]; then
  print_error "Missing audio helpers: ${missing[*]}"
  print_info  "Install ladspa, swh-plugins and ffmpeg for your distro, then retry."
  exit 1
fi
print_ok "PipeWire stack and audio helpers present"

# =============================================================================
# STEP 2 — Get the binaries: local build (--local) or the GitHub Release
# =============================================================================
if $LOCAL; then
  print_header "Building Binaries Locally"

  if ! command -v go &>/dev/null; then
    print_error "go is not installed — --local needs the Go toolchain to build soundbar-status-server/soundbar-setup."
    exit 1
  fi
  if [ ! -f "$SCRIPT_DIR/audio/go.mod" ]; then
    print_error "$SCRIPT_DIR/audio/go.mod not found — --local must run from a checkout of $REPO."
    exit 1
  fi

  print_info "Building from $SCRIPT_DIR/audio (go $(go version | awk '{print $3}'))"
  ( cd "$SCRIPT_DIR/audio" && go build -o "$WORK/soundbar-status-server" . )
  print_ok "Built soundbar-status-server"
  ( cd "$SCRIPT_DIR/audio" && go build -o "$WORK/soundbar-setup" ./setup )
  print_ok "Built soundbar-setup"

  cp "$SCRIPT_DIR/audio/soundbar-status-server.service" "$WORK/soundbar-status-server.service"
  print_ok "Copied unit file from $SCRIPT_DIR/audio"
else
  print_header "Downloading Binaries"

  command -v curl &>/dev/null || install_with_pkg_manager curl

  print_info "Fetching from $REPO ($RELEASE_TAG)"
  fetch soundbar-setup                   "$WORK/soundbar-setup"
  fetch soundbar-status-server           "$WORK/soundbar-status-server"
  fetch soundbar-status-server.service   "$WORK/soundbar-status-server.service"
  print_ok "Downloaded soundbar-setup, soundbar-status-server, and unit file"
fi
chmod +x "$WORK/soundbar-setup" "$WORK/soundbar-status-server"

# =============================================================================
# STEP 3 — Cleanup previous install if any
# =============================================================================
print_header "Cleaning Up Previous Config"

for unit in audio-watch soundbar-status-server; do
  systemctl --user stop "$unit.service" 2>/dev/null && print_ok "Stopped $unit" || true
done

# Earlier versions drove the keepalive and the EQ from a udev rule, two units
# and a login catch-up. audio-watch replaces all of it.
restart=false   # PipeWire only restarts when something it loaded was removed
legacy=false
for unit in soundbar-keepalive soundbar-loopback soundbar-keepalive-login; do
  [ -f "$SYSTEMD_USER_DIR/$unit.service" ] || continue
  systemctl --user disable --now "$unit.service" 2>/dev/null || true
  rm -f "$SYSTEMD_USER_DIR/$unit.service"
  legacy=true
done
rm -f "$SCRIPTS_DIR/soundbar-keepalive" "$SCRIPTS_DIR/soundbar-loopback"
systemctl --user reset-failed soundbar-keepalive.service 2>/dev/null || true
if [ -f "$UDEV_DIR/99-soundbar-keepalive.rules" ]; then
  sudo rm -f "$UDEV_DIR/99-soundbar-keepalive.rules"
  sudo udevadm control --reload-rules
  legacy=true
fi
$legacy && print_ok "Removed the previous version's keepalive units and udev rule"

# Unload any leftover pactl modules (only numeric IDs)
while IFS=$'\t' read -r mod_id mod_name _; do
  if [[ "$mod_id" =~ ^[0-9]+$ ]] && [[ "$mod_name" =~ remap|ladspa|swap|null-sink|loopback ]]; then
    pactl unload-module "$mod_id" 2>/dev/null && print_ok "Unloaded module $mod_name ($mod_id)" || true
  fi
done < <(pactl list short modules 2>/dev/null)

# Remove previous configs so hidden devices are back, and the filters gone,
# before detection. The answers themselves are kept (~/.config/soundbar-setup)
# and pre-fill the wizard.
for conf in "$PIPEWIRE_CONF_DIR/soundbar-eq.conf" "$PIPEWIRE_CONF_DIR/audio-filters.conf" \
            "$WIREPLUMBER_CONF_DIR/99-device-priorities.conf"; do
  [ -f "$conf" ] && rm -f "$conf" && restart=true && print_ok "Removed $(basename "$conf")"
done

# Remove the firewall rule (re-added in STEP 9) so it never stacks/goes stale.
if command -v ufw &>/dev/null; then
  sudo ufw delete allow "$SERVER_PORT/tcp" 2>/dev/null && print_ok "Removed ufw rule $SERVER_PORT/tcp" || true
fi

rm -rf "$GENERATED_DIR"
rm -f /tmp/soundbar-loopback-modules
rm -f "$HOME/.local/state/wireplumber/default-nodes"
wpctl clear-default 2>/dev/null || true

# A restart disconnects the Bluetooth devices, so only do it when a removed
# config was hiding devices or loading filters.
if $restart; then
  print_info "Restarting PipeWire to bring every device back..."
  restart_pipewire 4
fi
print_ok "Cleanup done"

# =============================================================================
# STEP 4 — Interactive setup (renders all configs from templates)
# =============================================================================
print_header "Interactive Audio Setup"

print_info "Connect the devices you want to set up: a Bluetooth output that is off"
print_info "can only be offered if a previous run already knew it."

( cd "$WORK" && ./soundbar-setup -staging "$GENERATED_DIR" )

if [ ! -f "$GENERATED_DIR/vars.sh" ]; then
  print_error "setup did not produce $GENERATED_DIR/vars.sh — aborting"
  exit 1
fi
# shellcheck source=/dev/null
source "$GENERATED_DIR/vars.sh"
print_ok "Configs generated for ${#OUTPUT_SUMMARY[@]} output(s)"

# Ensure ~/.local/bin is in PATH (the generated scripts live there)
if [[ ":$PATH:" != *":$SCRIPTS_DIR:"* ]]; then
  print_warn "$SCRIPTS_DIR is not in your PATH"
  print_info "Add to your shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# =============================================================================
# STEP 5 — Bluetooth auto-connect at boot (optional; needs root)
# =============================================================================
# A Bluetooth speaker usually won't reconnect on its own, so after a reboot it
# stays silent until someone connects it. This installs a root oneshot that
# retries connecting every device BlueZ has paired, at every boot. It keeps no
# device list of its own: whatever is paired when it runs is tried, so a device
# paired after this install is picked up too.
# System unit, not --user: it must run before anyone logs in; once a device is
# connected, audio-watch takes over.
BT_HELPER=/usr/local/bin/bt-autoconnect
BT_SERVICE=/etc/systemd/system/bt-autoconnect.service
bt_auto=n

if command -v bluetoothctl &>/dev/null; then
  print_header "Bluetooth Auto-Connect"
  # Enter keeps what is there: a re-run must not drop the unit by accident.
  bt_hint="y/N"
  [ -f "$BT_SERVICE" ] && bt_auto=y && bt_hint="Y/n"
  ask "Reconnect paired Bluetooth devices automatically at boot? [$bt_hint]"
  [ "${HAS_BT:-false}" = true ] && print_info "Recommended: one of your outputs is Bluetooth."
  read -rp "Choice: " bt_answer
  bt_auto="${bt_answer:-$bt_auto}"
fi

case "${bt_auto,,}" in
  y|yes)
    sudo tee "$BT_HELPER" >/dev/null <<'BTEOF'
#!/bin/bash
# bt-autoconnect — try to connect every device BlueZ already knows about,
# retrying for a bounded window so devices that power on slowly still get
# picked up. Keeps no device list of its own: the set comes from BlueZ's paired
# registry, so pairing something new is enough for it to be picked up next boot.
# Installed by audio.sh; run at boot by bt-autoconnect.service. Optional
# tunables come from /etc/bt-autoconnect/bt-autoconnect.env.

set -u

ATTEMPTS="${BT_AUTOCONNECT_ATTEMPTS:-12}"
INTERVAL="${BT_AUTOCONNECT_INTERVAL:-10}"
SKIP="${BT_AUTOCONNECT_SKIP:-}"   # space-separated MACs to leave alone
# Whole-run limit in seconds. An unreachable device costs ~5s per attempt, so
# with a few of them off the attempts alone outlast the unit's TimeoutStartSec
# and systemd kills the run as failed. Keep this below that timeout.
BUDGET="${BT_AUTOCONNECT_BUDGET:-240}"
CALL_TIMEOUT="${BT_AUTOCONNECT_CALL_TIMEOUT:-20}"

# bluetoothctl has no timeout of its own: a connect that never gets an answer
# (seen with a phone) would hold the whole run until systemd kills it.
bt() { timeout "$CALL_TIMEOUT" bluetoothctl "$@"; }

out_of_time() { [ "$SECONDS" -ge "$BUDGET" ]; }

give_up() {
  echo "giving up after ${SECONDS}s; some devices stayed unreachable"
  exit 0
}

skipped() {
  local mac=$1 s
  for s in $SKIP; do [ "${s^^}" = "${mac^^}" ] && return 0; done
  return 1
}

# bluetoothd may still be enumerating the adapter when we start.
for _ in $(seq 1 30); do
  bt show >/dev/null 2>&1 && break
  out_of_time && give_up
  sleep 1
done

bt power on >/dev/null 2>&1

for attempt in $(seq 1 "$ATTEMPTS"); do
  mapfile -t paired < <(bt devices Paired 2>/dev/null | awk '{print $2}')

  if [ "${#paired[@]}" -eq 0 ]; then
    echo "no paired devices known to BlueZ; nothing to do"
    exit 0
  fi

  pending=0
  for mac in "${paired[@]}"; do
    skipped "$mac" && continue

    info=$(bt info "$mac" 2>/dev/null)
    case $info in *"Connected: yes"*) continue ;; esac

    pending=1
    out_of_time && give_up
    name=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Name: //p' | head -1)
    if bt connect "$mac" >/dev/null 2>&1; then
      echo "connected ${name:-unknown} ($mac)"
    else
      echo "attempt $attempt/$ATTEMPTS: ${name:-unknown} ($mac) not reachable"
    fi
  done

  if [ "$pending" -eq 0 ]; then
    echo "all known devices connected"
    exit 0
  fi

  out_of_time && give_up
  [ "$attempt" -lt "$ATTEMPTS" ] && sleep "$INTERVAL"
done

give_up
BTEOF
    sudo chmod 0755 "$BT_HELPER"
    print_ok "Installed $BT_HELPER"

    sudo tee "$BT_SERVICE" >/dev/null <<'BTSVC'
[Unit]
Description=Connect all BlueZ-known Bluetooth devices at boot
# System unit, not a --user one: bluetoothd is system-wide and the soundbar
# should come up whether or not a session has started yet (same reasoning as
# poweroff-server). The helper also waits for the adapter to be enumerated.
# Installed by audio.sh.
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bt-autoconnect
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# Optional tuning: BT_AUTOCONNECT_ATTEMPTS / _INTERVAL / _SKIP. Leading "-" so
# the unit still starts when the file was never created.
EnvironmentFile=-/etc/bt-autoconnect/bt-autoconnect.env
# Backstop only: the helper stops itself after BT_AUTOCONNECT_BUDGET (240s) and
# puts a timeout on every bluetoothctl call. Keep this above the budget, or a
# boot with the devices off ends with the unit killed and marked failed.
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
BTSVC
    sudo systemctl daemon-reload
    sudo systemctl enable bt-autoconnect.service
    # --no-block: the first pass can retry for ~2 minutes; don't hold the install.
    sudo systemctl start --no-block bt-autoconnect.service
    print_ok "Enabled bt-autoconnect.service (connecting paired devices now and at every boot)"
    print_info "Optional tuning in /etc/bt-autoconnect/bt-autoconnect.env: BT_AUTOCONNECT_ATTEMPTS, BT_AUTOCONNECT_INTERVAL, BT_AUTOCONNECT_BUDGET, BT_AUTOCONNECT_SKIP (MACs)"
    ;;
  *)
    if [ -f "$BT_SERVICE" ] || [ -f "$BT_HELPER" ]; then
      sudo systemctl disable --now bt-autoconnect.service 2>/dev/null || true
      sudo rm -f "$BT_SERVICE" "$BT_HELPER"
      sudo systemctl daemon-reload
      print_ok "Removed bt-autoconnect service + helper"
    fi
    ;;
esac

# =============================================================================
# STEP 6 — Reload PipeWire and apply disabled-card profiles
# =============================================================================
print_header "Reloading Services"

systemctl --user daemon-reload
restart_pipewire 2

for card in "${DISABLED_CARDS[@]}"; do
  pactl set-card-profile "$card" off 2>/dev/null && print_ok "Disabled: $card" || print_warn "Could not disable: $card"
done
print_ok "PipeWire reloaded"

# The WirePlumber config sets session.suspend-timeout-seconds = 0 on every ALSA
# mic, but that only stops an *idle* node from being suspended — nodes still
# start out suspended, so the first recording after each boot would crackle.
# mic-wake opens every mic once whenever WirePlumber starts, leaving them idle.
cat > "$SCRIPTS_DIR/mic-wake" <<'EOF'
#!/bin/bash
# mic-wake — open every ALSA mic for a moment so it leaves the "suspended"
# state; with the suspend timeout at 0 it then stays idle, and a recording no
# longer starts with the mic waking up. Installed by audio.sh; run by
# mic-wake.service each time WirePlumber starts.

list_mics() {
  pactl list short sources 2>/dev/null | awk '$2 ~ /^alsa_input\./ {print $2}'
}

# WirePlumber has just started: wait for the first mic, then give the others
# a moment to be enumerated too.
for _ in $(seq 1 20); do
  [ -n "$(list_mics)" ] && break
  sleep 1
done
sleep 2

list_mics | while read -r mic; do
  timeout 1 pw-record --target "$mic" /dev/null 2>/dev/null
  echo "woke $mic"
done
exit 0
EOF
chmod +x "$SCRIPTS_DIR/mic-wake"

cat > "$SYSTEMD_USER_DIR/mic-wake.service" <<'EOF'
[Unit]
Description=Wake the microphones once so they never start a recording suspended
# WantedBy=wireplumber.service: rerun on every WirePlumber (re)start, which is
# when its nodes come back suspended. Generated by audio.sh.
After=wireplumber.service pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=oneshot
ExecStart=%h/.local/bin/mic-wake

[Install]
WantedBy=wireplumber.service
EOF
systemctl --user daemon-reload
systemctl --user enable mic-wake.service 2>/dev/null && print_ok "Enabled mic-wake (mics stay awake after every WirePlumber start)" || print_warn "Could not enable mic-wake"
systemctl --user start mic-wake.service 2>/dev/null || true

# audio-watch: keepalive tone on the outputs that asked for one, and the default
# output handed back to the priority order when an output comes or goes.
systemctl --user enable audio-watch.service 2>/dev/null && print_ok "Enabled audio-watch (keepalive tone, output priority)" || print_warn "Could not enable audio-watch"
systemctl --user restart audio-watch.service

# =============================================================================
# STEP 7 — HTTP server access control (optional)
# =============================================================================
# Neither check is required: an empty ALLOWED_IPS means no IP restriction, and
# the token is only enforced because the server checks it unconditionally once
# present in server.env. Written before the (re)start below so the fresh binary
# picks it up immediately via EnvironmentFile=.
# A token from a previous run is kept: whatever calls the server (a Home
# Assistant automation, …) has it stored, and a new one would lock it out with
# a bare 401. Delete server.env before running this to get a new token.
print_header "HTTP Server Access Control"

SERVER_CONFIG_DIR="$HOME/.config/soundbar-status-server"
mkdir -p "$SERVER_CONFIG_DIR"
chmod 700 "$SERVER_CONFIG_DIR"

AUTH_TOKEN=""
if [ -f "$SERVER_CONFIG_DIR/server.env" ]; then
  AUTH_TOKEN="$(sed -n 's/^AUTH_TOKEN=//p' "$SERVER_CONFIG_DIR/server.env" | head -n1)"
fi

ask "Restrict soundbar-status-server access by IP?"
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
# STEP 8 — Install and (re)start the status HTTP server
# =============================================================================
print_header "Soundbar Status HTTP Server"

cp "$WORK/soundbar-status-server" "$SCRIPTS_DIR/soundbar-status-server"
chmod +x "$SCRIPTS_DIR/soundbar-status-server"
print_ok "Installed $SCRIPTS_DIR/soundbar-status-server"

cp "$WORK/soundbar-status-server.service" "$SYSTEMD_USER_DIR/soundbar-status-server.service"
print_ok "Installed $SYSTEMD_USER_DIR/soundbar-status-server.service"

systemctl --user daemon-reload
systemctl --user enable soundbar-status-server.service 2>/dev/null && print_ok "Enabled soundbar-status-server" || true
systemctl --user restart soundbar-status-server.service
print_ok "(Re)started soundbar-status-server (HTTP :$SERVER_PORT)"

# =============================================================================
# STEP 8b — MPD music server (optional)
# =============================================================================
# Plays through PipeWire as the logged-in user (--user unit, so it's up after
# login — see session.sh for unattended reboots) and listens on every interface
# for remote clients. Anonymous clients get no permissions at all; everything
# goes through a password generated here. A re-run keeps the password already in
# mpd.conf, so the clients that have it stay in; delete the file for a new one.
MPD_CONF_DIR="$HOME/.config/mpd"
MPD_CONF="$MPD_CONF_DIR/mpd.conf"
MPD_PORT=6600
MPD_MARKER="# Generated by audio.sh"
MPD_ENABLED=false

print_header "MPD Music Server"
# Enter keeps what is there: a re-run must not drop the server by accident.
mpd_choice=n
mpd_hint="y/N"
if [ -f "$MPD_CONF" ] && systemctl --user is-enabled -q mpd.service 2>/dev/null; then
  mpd_choice=y
  mpd_hint="Y/n"
fi
ask "Install and enable an MPD server (port $MPD_PORT, password-protected)? [$mpd_hint]"
read -rp "Choice: " mpd_answer
mpd_choice="${mpd_answer:-$mpd_choice}"

case "${mpd_choice,,}" in
  y|yes)
    mpd_pkgs=()
    command -v mpd &>/dev/null || mpd_pkgs+=(mpd)
    command -v mpc &>/dev/null || mpd_pkgs+=(mpc)
    [ ${#mpd_pkgs[@]} -gt 0 ] && install_with_pkg_manager "${mpd_pkgs[@]}"

    # Keep the password of an existing config; only a first install, or a
    # password this script could not have written, gets a new one.
    # Alphanumeric only: mpd.conf takes the value between double quotes and
    # splits "password@permissions" on '@'.
    MPD_PASSWORD=""
    if [ -f "$MPD_CONF" ]; then
      MPD_PASSWORD="$(sed -n 's/^password[[:space:]]*"\([A-Za-z0-9]\{1,\}\)@.*/\1/p' "$MPD_CONF" | head -n1)"
    fi
    if [ -n "$MPD_PASSWORD" ]; then
      mpd_note="kept the existing password"
    else
      MPD_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
      mpd_note="new password"
    fi

    mkdir -p "$MPD_CONF_DIR"
    cat > "$MPD_CONF" <<EOF
$MPD_MARKER — re-running it rewrites this file and keeps the password.
bind_to_address     "0.0.0.0"
port                "$MPD_PORT"

password            "$MPD_PASSWORD@read,add,control"
default_permissions ""

audio_output {
    type  "pipewire"
    name  "PipeWire"
}
EOF
    chmod 600 "$MPD_CONF"
    print_ok "Wrote $MPD_CONF ($mpd_note)"

    systemctl --user daemon-reload
    systemctl --user enable mpd.service 2>/dev/null && print_ok "Enabled mpd" || true
    systemctl --user restart mpd.service
    print_ok "(Re)started mpd (port $MPD_PORT)"
    MPD_ENABLED=true
    ;;
  *)
    # Undo a server this script set up. A config without the marker may be
    # hand-written (or predate the marker): ask before touching its server.
    mpd_undo=false
    if [ -f "$MPD_CONF" ] && head -n1 "$MPD_CONF" | grep -qF "$MPD_MARKER"; then
      mpd_undo=true
    elif [ -f "$MPD_CONF" ] && systemctl --user is-enabled -q mpd.service 2>/dev/null; then
      ask "An MPD server is enabled, with a config this script didn't mark as its own. Stop and disable it? [y/N]"
      read -rp "Choice: " mpd_stop
      case "${mpd_stop,,}" in y|yes) mpd_undo=true ;; esac
    fi
    if $mpd_undo; then
      systemctl --user disable --now mpd.service 2>/dev/null || true
      if command -v ufw &>/dev/null; then
        sudo ufw delete allow "$MPD_PORT/tcp" 2>/dev/null || true
      fi
      print_ok "Stopped and disabled the MPD server ($MPD_CONF kept)"
    fi
    ;;
esac

# =============================================================================
# STEP 9 — Firewall (open the status server port, and MPD's if enabled)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'soundbar-status-server'
  print_ok "Allowed $SERVER_PORT/tcp in ufw"
  if [ "$MPD_ENABLED" = true ]; then
    sudo ufw allow "$MPD_PORT/tcp" comment 'mpd'
    print_ok "Allowed $MPD_PORT/tcp in ufw"
  fi
else
  print_warn "ufw not installed — skipping firewall rules"
fi

# =============================================================================
# Done
# =============================================================================
print_header "Setup Complete"
echo -e "${GREEN}${BOLD}All done!${NC}"
echo ""
echo -e "  Outputs, preferred first:"
for line in "${OUTPUT_SUMMARY[@]}"; do
  echo -e "    ${CYAN}${line}${NC}"
done
if [ -n "${DEFAULT_SOURCE:-}" ]; then
  echo -e "  Default mic:    ${CYAN}${DEFAULT_SOURCE_DESC}${NC} (${DEFAULT_SOURCE})"
fi
if [ "${HAS_EQ:-false}" = true ]; then
  eq_state=on
  case "$("$SCRIPTS_DIR/audio-eq" status 2>/dev/null)" in *false*) eq_state=off ;; esac
  echo -e "  Equalizer:      ${CYAN}${eq_state}${NC} (switch: audio-eq on|off, or POST /eq/on and /eq/off)"
fi
echo -e "  Status server:  ${CYAN}http://localhost:$SERVER_PORT/status${NC} (reports on ${STATUS_DESC})"
echo -e "  Access token:   ${CYAN}$AUTH_TOKEN${NC}"
echo -e "  Token file:     ${CYAN}$SERVER_CONFIG_DIR/server.env${NC}"
if [ "$MPD_ENABLED" = true ]; then
  echo -e "  MPD server:     ${CYAN}port $MPD_PORT${NC} (try: mpc -h '<password>@localhost' status)"
  echo -e "  MPD password:   ${CYAN}$MPD_PASSWORD${NC}"
fi
if [ "${HAS_BT:-false}" = true ]; then
  echo ""
  echo -e "${YELLOW}Bluetooth outputs get their extras as soon as they connect.${NC}"
fi
