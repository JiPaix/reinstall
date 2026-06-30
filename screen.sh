#!/usr/bin/env bash
# =============================================================================
# swapscreen Setup Script
# - Builds the Go HTTP server + the interactive setup CLI in screen/
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

# Paths — resolved relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/screen"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="swapscreen-server.service"
SERVER_PORT=7920   # must match Environment=PORT= in $SERVICE
SUNSHINE_KMS_CACHE="$HOME/.config/sunshine/kms_index_cache"

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

# Remove generated artifacts so the run regenerates them from fresh choices.
[ -f "$SRC/swapscreen.sh" ]          && rm -f "$SRC/swapscreen.sh"          && print_ok "Removed generated swapscreen.sh"
[ -f "$SRC/setup/profiles.conf" ]    && rm -f "$SRC/setup/profiles.conf"    && print_ok "Removed generated profiles.conf"

# Remove the engine's runtime KMS cache (leaves sunshine.conf untouched).
[ -f "$SUNSHINE_KMS_CACHE" ]         && rm -f "$SUNSHINE_KMS_CACHE"         && print_ok "Removed Sunshine KMS cache"

systemctl --user daemon-reload
print_ok "Cleanup done"

# =============================================================================
# STEP 1 — Toolchain (Go)
# =============================================================================
print_header "Checking Go Toolchain"

if ! command -v go &>/dev/null; then
  print_warn "go is not installed"
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

  print_info "Installing go with: $PKG_MANAGER"
  $PKG_MANAGER go

  if ! command -v go &>/dev/null; then
    print_error "go still not found after install — aborting"
    exit 1
  fi
fi
print_ok "go available: $(go version)"

# =============================================================================
# STEP 2 — Build the server and the interactive setup CLI
# =============================================================================
print_header "Building Go Binaries"

# Build into the source tree first so a failed build never clobbers a working
# install (the cleanup step already removed the old binary, the new ones only
# reach ~/.local/bin in STEP 5). vendor/ makes this build offline.
( cd "$SRC" && go build -o swapscreen-server . )
print_ok "Built $SRC/swapscreen-server"
( cd "$SRC" && go build -o swapscreen-setup ./setup )
print_ok "Built $SRC/swapscreen-setup"

# =============================================================================
# STEP 3 — Interactive setup (generates swapscreen.sh)
# =============================================================================
print_header "Interactive Display Setup"

print_info "Detecting monitors and building the monitor/tv/taiko layouts."
print_warn "This needs a graphical session (gdctl) and an interactive terminal."

( cd "$SRC" && ./swapscreen-setup )

if [ ! -f "$SRC/swapscreen.sh" ]; then
  print_error "setup did not produce $SRC/swapscreen.sh — aborting"
  exit 1
fi
print_ok "Generated $SRC/swapscreen.sh"

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
cp "$SRC/swapscreen-server" "$BIN_DIR/swapscreen-server"
chmod +x "$BIN_DIR/swapscreen-server"
print_ok "Installed $BIN_DIR/swapscreen-server"

cp "$SRC/swapscreen.sh" "$BIN_DIR/swapscreen"
chmod +x "$BIN_DIR/swapscreen"
print_ok "Installed $BIN_DIR/swapscreen"

cp "$SRC/$SERVICE" "$UNIT_DIR/$SERVICE"
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
