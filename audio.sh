#!/bin/bash
# =============================================================================
# PipeWire Audio Setup Script
# - Detect/install dependencies, then drive the Go interactive setup CLI
#   (audio/setup → soundbar-setup) which renders all configs from templates
#   straight to their final locations.
# - This script orchestrates: cleanup, package install, binary download, running
#   the wizard, the privileged udev install, service reload, and the firewall.
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

# =============================================================================
# STEP 0 — Cleanup previous install if any
# =============================================================================
print_header "Cleaning Up Previous Config"

systemctl --user stop soundbar-keepalive.service 2>/dev/null && print_ok "Stopped soundbar-keepalive" || true
systemctl --user stop soundbar-loopback.service 2>/dev/null && print_ok "Stopped soundbar-loopback" || true
systemctl --user stop soundbar-status-server.service 2>/dev/null && print_ok "Stopped soundbar-status-server" || true

# Unload any leftover pactl modules (only numeric IDs)
while IFS=$'\t' read -r mod_id mod_name _; do
  if [[ "$mod_id" =~ ^[0-9]+$ ]] && [[ "$mod_name" =~ remap|ladspa|swap|null-sink|loopback ]]; then
    pactl unload-module "$mod_id" 2>/dev/null && print_ok "Unloaded module $mod_name ($mod_id)" || true
  fi
done < <(pactl list short modules 2>/dev/null)

# Remove previous configs so virtual devices are gone before detection
[ -f "$PIPEWIRE_CONF_DIR/soundbar-eq.conf" ] && rm -f "$PIPEWIRE_CONF_DIR/soundbar-eq.conf" && print_ok "Removed previous EQ config"
[ -f "$WIREPLUMBER_CONF_DIR/99-device-priorities.conf" ] && rm -f "$WIREPLUMBER_CONF_DIR/99-device-priorities.conf" && print_ok "Removed previous WirePlumber config"
if [ -f "$UDEV_DIR/99-soundbar-keepalive.rules" ]; then
  sudo rm -f "$UDEV_DIR/99-soundbar-keepalive.rules"
  sudo udevadm control --reload-rules
  print_ok "Removed previous udev rule"
fi

# Remove the firewall rule (re-added in STEP 9) so it never stacks/goes stale.
if command -v ufw &>/dev/null; then
  sudo ufw delete allow "$SERVER_PORT/tcp" 2>/dev/null && print_ok "Removed ufw rule $SERVER_PORT/tcp" || true
fi

rm -rf "$GENERATED_DIR"
rm -f /tmp/soundbar-loopback-modules
rm -f "$HOME/.local/state/wireplumber/default-nodes"

# Restart PipeWire so bt_swap_sink virtual device disappears before we list devices
print_info "Restarting PipeWire to clear virtual devices..."
systemctl --user kill pipewire-pulse wireplumber pipewire 2>/dev/null || true
sleep 2
systemctl --user start pipewire
systemctl --user start wireplumber
systemctl --user start pipewire-pulse
sleep 4
print_ok "Cleanup done"

# =============================================================================
# STEP 1 — Package manager
# =============================================================================
print_header "Package Manager"
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

print_ok "Using: $PKG_MANAGER"

# =============================================================================
# STEP 2 — Check and install packages
# =============================================================================
print_header "Checking Required Packages"

REQUIRED_PACKAGES=(pipewire wireplumber pipewire-pulse ladspa swh-plugins ffmpeg)
MISSING=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if pacman -Q "$pkg" &>/dev/null; then
    print_ok "$pkg already installed"
  else
    print_warn "$pkg missing"
    MISSING+=("$pkg")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  print_info "Installing: ${MISSING[*]}"
  $PKG_MANAGER "${MISSING[@]}"
  print_ok "Packages installed"
else
  print_ok "All packages present"
fi

# Verify mbeq plugin (the Go setup also checks, but fail early with a clear msg)
if ! find /usr/lib/ladspa -name "mbeq_1197.so" &>/dev/null; then
  print_error "mbeq_1197.so not found even after install — check swh-plugins"
  exit 1
fi
print_ok "mbeq plugin present"

# =============================================================================
# STEP 3 — Download prebuilt binaries from the GitHub Release
# =============================================================================
print_header "Downloading Binaries"

if ! command -v curl &>/dev/null; then
  print_warn "curl not installed — installing with: $PKG_MANAGER"
  $PKG_MANAGER curl
fi

print_info "Fetching from $REPO ($RELEASE_TAG)"
fetch soundbar-setup                   "$WORK/soundbar-setup"
fetch soundbar-status-server           "$WORK/soundbar-status-server"
fetch soundbar-status-server.service   "$WORK/soundbar-status-server.service"
chmod +x "$WORK/soundbar-setup" "$WORK/soundbar-status-server"
print_ok "Downloaded soundbar-setup, soundbar-status-server, and unit file"

# =============================================================================
# STEP 5 — Interactive setup (renders all configs from templates)
# =============================================================================
print_header "Interactive Audio Setup"

print_info "Make sure all your devices are connected/paired before continuing."
print_warn "This needs pipewire-pulse running (it is) and an interactive terminal."

( cd "$WORK" && ./soundbar-setup -staging "$GENERATED_DIR" )

if [ ! -f "$GENERATED_DIR/vars.sh" ]; then
  print_error "setup did not produce $GENERATED_DIR/vars.sh — aborting"
  exit 1
fi
# shellcheck source=/dev/null
source "$GENERATED_DIR/vars.sh"
print_ok "Configs generated for: $PRIMARY_DESC"

# Ensure ~/.local/bin is in PATH (the generated scripts live there)
if [[ ":$PATH:" != *":$SCRIPTS_DIR:"* ]]; then
  print_warn "$SCRIPTS_DIR is not in your PATH"
  print_info "Add to your shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# =============================================================================
# STEP 6 — Install the udev rule (Bluetooth only; needs root)
# =============================================================================
if [ "${IS_BT:-false}" = true ] && [ -n "${UDEV_RULE_FILE:-}" ] && [ -f "$UDEV_RULE_FILE" ]; then
  print_header "Installing udev Rule"
  sudo cp "$UDEV_RULE_FILE" "$UDEV_DIR/99-soundbar-keepalive.rules"
  sudo udevadm control --reload-rules
  print_ok "udev rule installed to $UDEV_DIR/99-soundbar-keepalive.rules"
else
  print_warn "Skipping udev rule (not a Bluetooth primary)"
fi

# =============================================================================
# STEP 7 — Reload PipeWire and apply disabled-card profiles
# =============================================================================
print_header "Reloading Services"

systemctl --user daemon-reload
systemctl --user kill pipewire-pulse wireplumber pipewire 2>/dev/null || true
sleep 2
systemctl --user start pipewire
systemctl --user start wireplumber
systemctl --user start pipewire-pulse
sleep 2

for card in "${DISABLED_CARDS[@]}"; do
  pactl set-card-profile "$card" off 2>/dev/null && print_ok "Disabled: $card" || print_warn "Could not disable: $card"
done
print_ok "PipeWire reloaded"

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
# STEP 9 — Firewall (open the status server port)
# =============================================================================
print_header "Firewall"

if command -v ufw &>/dev/null; then
  sudo ufw allow "$SERVER_PORT/tcp" comment 'soundbar-status-server'
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
echo -e "  Primary device: ${CYAN}${PRIMARY_DESC}${NC} (${PRIMARY_SINK})"
echo -e "  Status server:  ${CYAN}http://localhost:$SERVER_PORT/status${NC}"
if [ "${IS_BT:-false}" = true ]; then
  echo ""
  echo -e "${YELLOW}Connect your primary BT device to activate the EQ and keepalive.${NC}"
fi
