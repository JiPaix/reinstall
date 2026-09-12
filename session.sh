#!/bin/bash
# =============================================================================
# Session Setup Script (KDE Plasma Login Manager)
# - Optional autologin for the current user, so the user-session services the
#   other installers set up (swapscreen-server, soundbar-status-server,
#   Sunshine, ...) come back after an unattended reboot. This is the route taken
#   instead of `loginctl enable-linger` (see CLAUDE.md).
# - With autologin: installs a user unit that starts ksecretd (KDE's Secret
#   Service) with the graphical session, because pam_kwallet5 can't start it
#   without a typed password, and explains the one manual KWallet step.
# - Downloads nothing; needs sudo only to write /etc/plasmalogin.conf.
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

print_header() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
print_ok()     { echo -e "${GREEN}✓${NC} $1"; }
print_info()   { echo -e "${CYAN}→${NC} $1"; }
print_warn()   { echo -e "${YELLOW}!${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1"; }
ask()          { echo -e "${BOLD}$1${NC}"; }

PLASMALOGIN_CONF=/etc/plasmalogin.conf
UNIT_DIR="$HOME/.config/systemd/user"
KSECRETD_UNIT="ksecretd.service"
LOGIN_USER="$(id -un)"

# autologin_value <file> <key> — value of <key>= inside [Autologin], or "".
autologin_value() {
  [ -f "$1" ] || return 0
  awk -v key="$2" '
    /^\[.*\][[:space:]]*$/ { in_al = ($0 ~ /^\[Autologin\]/); next }
    in_al && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); print; exit
    }' "$1"
}

# set_autologin_conf <src> <user|""> <default-session>
# Prints <src> with [Autologin] User=/Session= set right under the section
# header; an empty user drops User= (autologin off). An existing Session= wins
# over the default. Every other line and section is kept as-is.
set_autologin_conf() {
  local src="$1" user="$2" session="$3" existing
  existing="$(autologin_value "$src" Session)"
  [ -n "$existing" ] && session="$existing"
  [ -f "$src" ] || src=/dev/null
  awk -v user="$user" -v session="$session" '
    /^\[.*\][[:space:]]*$/ {
      in_al = ($0 ~ /^\[Autologin\]/); print
      if (in_al) {
        if (user != "") print "User=" user
        print "Session=" session
        seen = 1
      }
      next
    }
    in_al && /^[[:space:]]*(User|Session)[[:space:]]*=/ { next }
    { print }
    END {
      if (!seen) {
        if (NR > 0) print ""
        print "[Autologin]"
        if (user != "") print "User=" user
        print "Session=" session
      }
    }' "$src"
}

# =============================================================================
# Prerequisite — Plasma Login Manager
# =============================================================================
DM_UNIT="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
if [[ "$DM_UNIT" != */plasmalogin.service ]]; then
  print_error "The display manager is not Plasma Login Manager (${DM_UNIT:-none enabled})."
  print_info  "This script only configures plasmalogin ($PLASMALOGIN_CONF)."
  exit 1
fi

DEFAULT_SESSION=""
if [ -f /usr/share/wayland-sessions/plasma.desktop ]; then
  DEFAULT_SESSION=plasma
else
  for f in /usr/share/wayland-sessions/*.desktop; do
    [ -e "$f" ] && { DEFAULT_SESSION="$(basename "$f" .desktop)"; break; }
  done
fi
if [ -z "$DEFAULT_SESSION" ]; then
  print_error "No Wayland session found in /usr/share/wayland-sessions."
  exit 1
fi

# =============================================================================
# STEP 1 — Autologin
# =============================================================================
print_header "Autologin"

CURRENT_USER="$(autologin_value "$PLASMALOGIN_CONF" User)"
if [ -n "$CURRENT_USER" ]; then
  print_info "Currently: autologin as $CURRENT_USER"
else
  print_info "Currently: autologin off"
fi
print_info "Autologin brings the user-session services (swapscreen, soundbar, Sunshine…)"
print_info "back after an unattended reboot, with nobody at the keyboard."
print_warn "Anyone with physical access to the machine gets an unlocked desktop."
ask "Log in $LOGIN_USER automatically at boot? [y/N]"
read -rp "Choice: " autologin_choice
case "${autologin_choice,,}" in
  y|yes) AUTOLOGIN=true ;;
  *)     AUTOLOGIN=false ;;
esac

if ! $AUTOLOGIN && [ -z "$CURRENT_USER" ]; then
  print_ok "Autologin stays off"
else
  TMP_CONF="$(mktemp)"
  trap 'rm -f "$TMP_CONF"' EXIT
  if $AUTOLOGIN; then
    set_autologin_conf "$PLASMALOGIN_CONF" "$LOGIN_USER" "$DEFAULT_SESSION" > "$TMP_CONF"
  else
    set_autologin_conf "$PLASMALOGIN_CONF" "" "$DEFAULT_SESSION" > "$TMP_CONF"
  fi

  if [ -f "$PLASMALOGIN_CONF" ] && cmp -s "$TMP_CONF" "$PLASMALOGIN_CONF"; then
    print_ok "$PLASMALOGIN_CONF already up to date"
  else
    sudo install -m 0644 -o root -g root "$TMP_CONF" "$PLASMALOGIN_CONF"
    print_ok "Wrote $PLASMALOGIN_CONF"
  fi

  if $AUTOLOGIN; then
    print_ok "Autologin: $LOGIN_USER (session: $(autologin_value "$PLASMALOGIN_CONF" Session))"
  else
    print_ok "Autologin: off"
  fi
fi

# =============================================================================
# STEP 2 — Secret Service under autologin (ksecretd)
# =============================================================================
# pam_kwallet5 normally starts ksecretd (KDE's org.freedesktop.secrets provider)
# and unlocks the wallet with the password typed at login. At an autologin
# there is no password: pam_kwallet5 does nothing, and nothing else starts
# ksecretd either (kwallet ships no D-Bus activation file for
# org.freedesktop.secrets), so every app asking for a secret fails.
print_header "Secret Service (ksecretd)"

KSECRETD_PATH="$UNIT_DIR/$KSECRETD_UNIT"
if $AUTOLOGIN; then
  KSECRETD_BIN="$(command -v ksecretd || true)"
  if [ -z "$KSECRETD_BIN" ]; then
    print_warn "ksecretd not found (KWallet older than 6.x?) — skipping its unit."
  else
    mkdir -p "$UNIT_DIR"
    cat > "$KSECRETD_PATH" <<KSEOF
[Unit]
Description=KDE Secret Service daemon (ksecretd)
# At an autologin pam_kwallet5 has no password and doesn't start ksecretd, and
# nothing else would. Bound to the graphical session on purpose: ksecretd is a
# Qt GUI app that aborts without a display, which is why a D-Bus activation file
# for org.freedesktop.secrets is the wrong fix (it gets activated headless, e.g.
# under multi-user.target, and crash-loops). Installed by session.sh.
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$KSECRETD_BIN
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
KSEOF
    systemctl --user daemon-reload
    systemctl --user enable "$KSECRETD_UNIT"
    print_ok "Enabled $KSECRETD_UNIT (starts ksecretd with the graphical session)"
  fi
elif [ -f "$KSECRETD_PATH" ]; then
  systemctl --user disable "$KSECRETD_UNIT" 2>/dev/null || true
  rm -f "$KSECRETD_PATH"
  systemctl --user daemon-reload
  print_ok "Removed $KSECRETD_UNIT (at a password login pam_kwallet5 starts ksecretd)"
else
  print_info "Autologin off — nothing to do (pam_kwallet5 starts ksecretd at login)."
fi

# =============================================================================
# STEP 3 — KWallet (manual, once)
# =============================================================================
if $AUTOLOGIN; then
  print_header "KWallet"
  print_warn "One manual step, once: give the wallet an empty password."
  print_info "Nobody types a password at an autologin, so a protected wallet stays locked"
  print_info "and apps using it (browsers, gh, Nextcloud…) ask for it after every boot."
  print_info "  KWalletManager → kdewallet → Change Password… → leave the new password empty"
  print_warn "The wallet's secrets are then only as protected as your home directory."
fi

# =============================================================================
# Done
# =============================================================================
print_header "Setup Complete"
echo -e "${GREEN}${BOLD}All done!${NC}"
echo ""
if $AUTOLOGIN; then
  echo -e "  Autologin:  ${CYAN}$LOGIN_USER${NC} (takes effect at the next boot)"
else
  echo -e "  Autologin:  ${CYAN}off${NC}"
fi
echo -e "  Config:     ${CYAN}$PLASMALOGIN_CONF${NC}"
