#!/bin/bash
# =============================================================================
# Poweroff HTTP Server Setup Script
# - Downloads the prebuilt poweroff-server binary from the latest GitHub
#   Release and installs it as a root system service, so a single guarded
#   HTTP endpoint can shut the machine down even with nobody logged in.
# - Unlike screen.sh/audio.sh this installs system-wide (/usr/local/bin,
#   /etc/systemd/system, /etc/poweroff-server), not under $HOME, and needs
#   sudo throughout.
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BIN_DIR="/usr/local/bin"
SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
SERVER_CONFIG_DIR="/etc/poweroff-server"
SERVER_PORT=7922   # must match Environment=PORT= in poweroff-server.service

# --- Release source ---------------------------------------------------------
REPO="${REPO:-JiPaix/reinstall}"
RELEASE_TAG="${RELEASE_TAG:-latest}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# =============================================================================
# STEP 0 — Cleanup previous install if any
# =============================================================================
print_header "Cleaning Up Previous Config"

sudo systemctl stop poweroff-server.service 2>/dev/null && print_ok "Stopped poweroff-server" || true

# =============================================================================
# STEP 1 — Download the prebuilt binary + unit from the GitHub Release
# =============================================================================
print_header "Downloading Binary"

if ! command -v curl &>/dev/null; then
  print_error "curl not found — install it for your distro, then retry."
  exit 1
fi

print_info "Fetching from $REPO ($RELEASE_TAG)"
fetch poweroff-server           "$WORK/poweroff-server"
fetch poweroff-server.service   "$WORK/poweroff-server.service"
chmod +x "$WORK/poweroff-server"
print_ok "Downloaded poweroff-server and unit file"

# =============================================================================
# STEP 2 — HTTP server access control
# =============================================================================
# This service can power the machine off on a bare HTTP request, so unlike
# the optional lockdown on screen/audio, both an allowlist and a token are
# asked for up front rather than left to a blank-is-fine default.
print_header "HTTP Server Access Control"

sudo install -d -m 0700 "$SERVER_CONFIG_DIR"

ask "Restrict poweroff-server access by IP?"
print_info "Comma-separated IPs and/or CIDRs, mixed freely (e.g. whatever IP Home Assistant is on)."
read -rp "Allowed IPs (blank = no restriction): " ALLOWED_IPS

AUTH_TOKEN="$(head -c 32 /dev/urandom | base64)"

{
  echo "ALLOWED_IPS=$ALLOWED_IPS"
  echo "AUTH_TOKEN=$AUTH_TOKEN"
} | sudo tee "$SERVER_CONFIG_DIR/server.env" >/dev/null
sudo chmod 600 "$SERVER_CONFIG_DIR/server.env"
sudo chown root:root "$SERVER_CONFIG_DIR/server.env"

if [ -n "$ALLOWED_IPS" ]; then
  print_ok "Restricting access to: $ALLOWED_IPS"
else
  print_warn "No IP restriction set — reachable from any host that can route to it"
fi
print_ok "Generated auth token (send it as 'Authorization: Bearer <token>')"

# =============================================================================
# STEP 3 — Install and (re)start the poweroff HTTP server
# =============================================================================
print_header "Poweroff HTTP Server"

sudo install -m 0755 "$WORK/poweroff-server" "$BIN_DIR/poweroff-server"
print_ok "Installed $BIN_DIR/poweroff-server"

sudo install -m 0644 "$WORK/poweroff-server.service" "$SYSTEMD_SYSTEM_DIR/poweroff-server.service"
print_ok "Installed $SYSTEMD_SYSTEM_DIR/poweroff-server.service"

sudo systemctl daemon-reload
sudo systemctl enable poweroff-server.service 2>/dev/null && print_ok "Enabled poweroff-server" || true
sudo systemctl restart poweroff-server.service
print_ok "(Re)started poweroff-server (HTTP :$SERVER_PORT), root system service — runs with nobody logged in"

# =============================================================================
# STEP 4 — Firewall (open the server port)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'poweroff-server'
  print_ok "Allowed $SERVER_PORT/tcp in ufw"
else
  print_warn "ufw not installed — skipping firewall rule for $SERVER_PORT/tcp"
fi

# =============================================================================
# Done
# =============================================================================
print_header "Setup Complete"
echo -e "${GREEN}${BOLD}All done!${NC}"
echo ""
echo -e "  Shutdown endpoint: ${CYAN}POST http://<host>:$SERVER_PORT/shutdown${NC}"
echo -e "  Access token:      ${CYAN}$AUTH_TOKEN${NC}"
echo -e "  Token file:        ${CYAN}$SERVER_CONFIG_DIR/server.env${NC}"
