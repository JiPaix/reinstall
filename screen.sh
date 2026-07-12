#!/usr/bin/env bash
# =============================================================================
# swapscreen Setup Script
# - Downloads the prebuilt HTTP server + interactive setup CLI from the Release
# - Runs the interactive setup (detect monitors → build monitor/tv/taiko grids),
#   which generates screen/swapscreen.sh from the engine template, plus a
#   gdm-monitors.xml for the GDM greeter (primary monitor only, rest disabled)
# - Installs swapscreen + swapscreen-server to ~/.local/bin and the systemd
#   units (server + a oneshot that forces monitor mode on every login)
# - Installs the GDM greeter layout (needs sudo)
# - Opens the server port in the firewall (ufw)
# =============================================================================

set -euo pipefail

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
# Prerequisite — GNOME (gdctl)
# =============================================================================
# swapscreen drives the display through gdctl, which ships with GNOME's
# compositor (the `mutter` package) and only exists in a GNOME session. Check
# before touching anything so a non-GNOME machine fails cleanly up front.
if ! command -v gdctl &>/dev/null; then
  print_error "gdctl not found — swapscreen requires GNOME."
  print_info  "gdctl ships with GNOME (the 'mutter' package). Use a GNOME session, then retry."
  exit 1
fi

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

# Remove the firewall rule (re-added in STEP 7) so it never stacks/goes stale.
if command -v ufw &>/dev/null; then
  sudo ufw delete allow "$SERVER_PORT/tcp" 2>/dev/null && print_ok "Removed ufw rule $SERVER_PORT/tcp" || true
fi

# Remove the engine's runtime KMS cache (leaves sunshine.conf untouched).
[ -f "$SUNSHINE_KMS_CACHE" ]         && rm -f "$SUNSHINE_KMS_CACHE"         && print_ok "Removed Sunshine KMS cache"

systemctl --user daemon-reload
print_ok "Cleanup done"

# =============================================================================
# STEP 1 — Download prebuilt binaries from the GitHub Release
# =============================================================================
print_header "Downloading Binaries"

if ! command -v curl &>/dev/null; then
  print_warn "curl is not installed"
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

  print_info "Installing curl with: $PKG_MANAGER"
  $PKG_MANAGER curl
fi

print_info "Fetching from $REPO ($RELEASE_TAG)"
fetch swapscreen-server          "$WORK/swapscreen-server"
fetch swapscreen-setup           "$WORK/swapscreen-setup"
fetch swapscreen-server.service  "$WORK/swapscreen-server.service"
fetch swapscreen-login.service   "$WORK/swapscreen-login.service"
chmod +x "$WORK/swapscreen-server" "$WORK/swapscreen-setup"
print_ok "Downloaded swapscreen-server, swapscreen-setup, and unit files"

# =============================================================================
# STEP 3 — Interactive setup (generates swapscreen.sh + gdm-monitors.xml)
# =============================================================================
print_header "Interactive Display Setup"

print_info "Detecting monitors and building the monitor/tv/taiko layouts."
print_warn "This needs a graphical session (gdctl) and an interactive terminal."

( cd "$WORK" && ./swapscreen-setup \
    -profiles "$WORK/profiles.conf" \
    -out      "$WORK/swapscreen.sh" \
    -gdm      "$WORK/gdm-monitors.xml" )

if [ ! -f "$WORK/swapscreen.sh" ]; then
  print_error "setup did not produce swapscreen.sh — aborting"
  exit 1
fi
if [ ! -f "$WORK/gdm-monitors.xml" ]; then
  print_error "setup did not produce gdm-monitors.xml — aborting"
  exit 1
fi
print_ok "Generated swapscreen.sh and gdm-monitors.xml"

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
# STEP 7 — GDM greeter layout (needs sudo; primary monitor only, rest disabled)
# =============================================================================
print_header "GDM Greeter Layout"

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
# profiles, via the external `displayconfig-mutter` helper (not part of this
# repo; assumed on PATH). apps.json just needs the two baseline app entries
# to exist so Sunshine has something to stream.
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

    print_info "Installing jq with: $PKG_MANAGER"
    $PKG_MANAGER jq
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

  # Color mode of a specific connector within a profile (default: "default").
  profile_connector_color() {  # $1 = array name, $2 = connector -> echoes color
    local -n arr="$1"
    local rec tok conn color
    for rec in "${arr[@]}"; do
      conn=""; color="default"
      for tok in $rec; do
        case "$tok" in
          connector=*) conn="${tok#connector=}" ;;
          color=*)     color="${tok#color=}" ;;
        esac
      done
      [ "$conn" = "$2" ] && { echo "$color"; return; }
    done
    echo "default"
  }

  TV_PRIMARY="$(profile_primary_connector TV_PROFILE)"
  MON_PRIMARY="$(profile_primary_connector MONITOR_PROFILE)"
  TV_HDR_UNDO=false
  [ "$(profile_connector_color TV_PROFILE "$TV_PRIMARY")" = bt2100 ] && TV_HDR_UNDO=true
  MON_HDR_UNDO=false
  [ "$(profile_connector_color MONITOR_PROFILE "$MON_PRIMARY")" = bt2100 ] && MON_HDR_UNDO=true

  # ${SUNSHINE_CLIENT_HDR} is Sunshine's own env var, evaluated by the `sh -c`
  # below at stream time — kept literal here via a single-quoted printf
  # format so this script's own expansion never touches it. Scaling literals
  # (300/200) are intentionally left untouched.
  DO_CMD=$(printf 'sh -c "displayconfig-mutter set --connector %s --scaling 300 --hdr ${SUNSHINE_CLIENT_HDR:-false} || true; displayconfig-mutter set --connector %s --hdr ${SUNSHINE_CLIENT_HDR:-false} || true"' \
    "$TV_PRIMARY" "$MON_PRIMARY")
  UNDO_CMD=$(printf 'sh -c "displayconfig-mutter set --connector %s --scaling 200 --hdr %s || true; displayconfig-mutter set --connector %s --hdr %s || true"' \
    "$TV_PRIMARY" "$TV_HDR_UNDO" "$MON_PRIMARY" "$MON_HDR_UNDO")

  PREP_ITEM=$(jq -n --arg do "$DO_CMD" --arg undo "$UNDO_CMD" '{do: $do, undo: $undo}')
  print_ok "Computed global prep-cmd (tv=$TV_PRIMARY, monitor=$MON_PRIMARY)"

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
