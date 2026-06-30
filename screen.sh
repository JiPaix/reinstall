#!/usr/bin/env bash
# =============================================================================
# swapscreen Setup Script
# - Downloads the prebuilt HTTP server + interactive setup CLI from the Release
# - Runs the interactive setup (detect monitors → build monitor/tv/taiko grids),
#   which generates screen/swapscreen.sh from the engine template
# - Installs swapscreen + swapscreen-server to ~/.local/bin and the systemd unit
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
SERVER_PORT=7920   # must match Environment=PORT= in $SERVICE
SUNSHINE_KMS_CACHE="$HOME/.config/sunshine/kms_index_cache"

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

[ -f "$BIN_DIR/swapscreen-server" ] && rm -f "$BIN_DIR/swapscreen-server" && print_ok "Removed previous server binary"
[ -f "$BIN_DIR/swapscreen" ]        && rm -f "$BIN_DIR/swapscreen"        && print_ok "Removed previous swapscreen script"
[ -f "$UNIT_DIR/$SERVICE" ]         && rm -f "$UNIT_DIR/$SERVICE"         && print_ok "Removed previous service unit"

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
chmod +x "$WORK/swapscreen-server" "$WORK/swapscreen-setup"
print_ok "Downloaded swapscreen-server, swapscreen-setup, and unit file"

# =============================================================================
# STEP 3 — Interactive setup (generates swapscreen.sh)
# =============================================================================
print_header "Interactive Display Setup"

print_info "Detecting monitors and building the monitor/tv/taiko layouts."
print_warn "This needs a graphical session (gdctl) and an interactive terminal."

( cd "$WORK" && ./swapscreen-setup -profiles "$WORK/profiles.conf" -out "$WORK/swapscreen.sh" )

if [ ! -f "$WORK/swapscreen.sh" ]; then
  print_error "setup did not produce swapscreen.sh — aborting"
  exit 1
fi
print_ok "Generated swapscreen.sh"

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

# =============================================================================
# STEP 6 — Enable and (re)start the service
# =============================================================================
print_header "Enabling Service"

# Order matters: daemon-reload so systemd sees the new unit, then enable to
# create the graphical-session.target.wants symlink, then restart so an
# already-running instance picks up the freshly built binary.
systemctl --user daemon-reload
print_ok "Reloaded systemd user units"

systemctl --user enable "$SERVICE"
print_ok "Enabled $SERVICE"

systemctl --user restart "$SERVICE"
print_ok "(Re)started $SERVICE"

print_info "Note: the unit is WantedBy=graphical-session.target, so it only"
print_info "auto-starts inside a graphical login session (not over plain SSH)."

# =============================================================================
# STEP 7 — Firewall (open the server port)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'swapscreen-server'
  print_ok "Allowed $SERVER_PORT/tcp in ufw"
else
  print_warn "ufw not installed — skipping firewall rule for $SERVER_PORT/tcp"
fi

echo
systemctl --user --no-pager --full status "$SERVICE" || true
