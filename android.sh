#!/bin/bash
# =============================================================================
# Android Tablet Audio Player Setup Script
# - Turns an Android tablet (adb debugging on, no root) into a network audio
#   player: Termux + Termux:Boot from F-Droid, squeezelite started at boot
#   towards a Lyrion / Music Assistant server, and the tablet's PulseAudio
#   opened on TCP so a PC can use the tablet as an audio output.
# - Then makes the tablet an output of THIS PC: a small PipeWire client
#   (tablet-sink@<name>.service) holding a PulseAudio tunnel to it.
# - The output gets no priority here: audio.sh, when used, ranks these network
#   outputs under every local device.
# - Downloads nothing from the GitHub Release and has no Go side: adb and ssh
#   do the work. adb is only needed for the first install and the Android
#   settings; once Termux has sshd, a re-run works over SSH alone (adb over
#   Wi-Fi does not survive a tablet reboot, SSH does).
# - SSH: this PC's public key (~/.ssh/id_ed25519.pub, else id_rsa.pub) is
#   authorized in Termux by the first-install step, whenever SSH doesn't
#   answer yet — including on a tablet another PC set up.
# - `--add-pc`: for another PC, on a tablet that is already set up: asks which
#   addresses to add to the tablet's allowlist (duplicates ignored, nothing
#   else on the tablet is touched), then makes it an output of this PC.
# - `--rename`: rename installed tablets, on this PC and/or as squeezelite
#   players — from a menu, or in one go without a terminal:
#   --rename <tablet IP or current name> <local|player|both> <new name>.
# - `--pc-only`: don't touch the tablet at all (this PC must already be
#   allowed), only make it an output of this PC.
# =============================================================================

set -e

PC_ONLY=false
ADD_PC=false
RENAME=false
RENAME_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pc-only) PC_ONLY=true ;;
    --add-pc) ADD_PC=true ;;
    --rename) RENAME=true; shift; RENAME_ARGS=("$@"); break ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SINK_CONFIG_DIR="$HOME/.config/tablet-sink"
ADB_PORT="${ADB_PORT:-5555}"
SSH_PORT=8022     # Termux's sshd default
PULSE_PORT=4713   # module-native-protocol-tcp default
# End-to-end buffer the tunnel aims for. 20 ms played clean on Wi-Fi in a short
# test; 40 leaves some margin. Raise it if the sound crackles.
TUNNEL_LATENCY_MS="${TUNNEL_LATENCY_MS:-40}"

TERMUX_PREFIX=/data/data/com.termux/files/usr
BOOTSTRAP_SCRIPT=/sdcard/Download/reinstall-bootstrap.sh
BOOTSTRAP_DONE=/sdcard/Download/reinstall-bootstrap.done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

print_header() { echo -e "\n${BOLD}${BLUE}=== $1 ===${NC}\n"; }
print_ok()     { echo -e "${GREEN}✓${NC} $1"; }
print_info()   { echo -e "${CYAN}→${NC} $1"; }
print_warn()   { echo -e "${YELLOW}!${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1"; }
ask()          { echo -e "${BOLD}$1${NC}"; }

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

ask_default() {  # $1 = prompt, $2 = default (may be empty) → answer on stdout
  local answer
  if [ -n "$2" ]; then
    read -rp "$1 [$2]: " answer
    echo "${answer:-$2}"
  else
    read -rp "$1: " answer
    echo "$answer"
  fi
}

adb_() { adb -s "$TABLET_IP:$ADB_PORT" "$@"; }
# -n: these run inside `while read` loops and must not eat their stdin.
adb_sh() { adb_ shell -n "$@"; }
# tablet_ssh never reads stdin (it would swallow the answers typed ahead);
# tablet_ssh_in is for the calls that are fed a file.
tablet_ssh() { tablet_ssh_in -n "$@"; }
tablet_ssh_in() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    -p "$SSH_PORT" "$TABLET_IP" "$@"
}

# Apps disabled per tablet model (`pm disable-user`: reversible with `pm enable`,
# data kept). Preloads plus apps their owner doesn't use there; a package that
# isn't on the tablet is skipped. Add a model: one more case.
debloat_list() {  # $1 = ro.product.model
  case "$1" in
    "Lenovo TB128FU") cat <<'EOF'
com.alibaba.aliexpresshd
com.amazon.kindle
com.amazon.mShop.android.shopping
com.aura.oobe.lenovo
com.caf.fmradio
com.discord
com.facebook.lite
com.google.android.apps.books
com.google.android.apps.chromecast.app
com.google.android.apps.docs
com.google.android.apps.docs.editors.docs
com.google.android.apps.docs.editors.sheets
com.google.android.apps.docs.editors.slides
com.google.android.apps.fitness
com.google.android.apps.googleassistant
com.google.android.apps.kids.home
com.google.android.apps.magazines
com.google.android.apps.maps
com.google.android.apps.messaging
com.google.android.apps.photos
com.google.android.apps.safetyhub
com.google.android.apps.subscriptions.red
com.google.android.apps.tachyon
com.google.android.apps.walletnfcrel
com.google.android.calendar
com.google.android.googlequicksearchbox
com.google.android.play.games
com.google.android.videos
com.google.android.youtube
com.google.ar.core
com.hubup.livemapnativewrapper
com.lenovo.hec.lenovoextend
com.lenovo.hecplatform.hecagent
com.lenovo.tab_m10_plus_2023
com.lenovo.udcplatform
com.microsoft.copilot
com.microsoft.office.word
com.motorola.demo
com.netflix.partner.activation
com.patreon.android
com.tblenovo.center
com.tblenovo.lenovowhatsnew
com.tblenovo.soundrecorder
com.tblenovo.tabpushout
com.twitter.android
com.ubercab.eats
com.valvesoftware.android.steam.community
com.valvesoftware.steamlink
com.whatsapp
com.zui.notes
com.zzkko
fr.creditagricole.androidapp
fr.meteo
org.telegram.messenger
EOF
      ;;
  esac
}

# Connects adb and sets HAVE_ADB. A PC the tablet has never seen comes up
# "unauthorized" until the dialog on the tablet's screen is accepted: wait for
# that instead of failing, whatever the route (first install or --add-pc).
adb_state() { adb devices | awk -v d="$1" '$1 == d { print $2 }'; }

connect_adb() {
  local target="$TABLET_IP:$ADB_PORT" state waited=0 port
  adb connect "$target" &>/dev/null || true
  state="$(adb_state "$target")"

  # Nothing on the fixed port: after a tablet reboot only Android's "Wireless
  # debugging" may be on, and it listens on a random port each time. Look for
  # it among the open high ports (a few seconds), then use it to put adb back
  # on the fixed port.
  if [ "$state" != device ] && [ "$state" != unauthorized ]; then
    adb disconnect "$target" &>/dev/null || true
    # A tablet that is off would cost over a minute of connection timeouts.
    ping -c 1 -W 2 "$TABLET_IP" &>/dev/null || return
    print_info "adb doesn't answer on port $ADB_PORT — looking for Wireless debugging…"
    for port in $(seq 30000 60999 | xargs -P 200 -I{} bash -c \
        "timeout 0.5 bash -c '</dev/tcp/$TABLET_IP/{}' 2>/dev/null && echo {}"); do
      timeout 10 adb connect "$TABLET_IP:$port" &>/dev/null || true
      state="$(adb_state "$TABLET_IP:$port")"
      if [ "$state" = device ] || [ "$state" = unauthorized ]; then
        target="$TABLET_IP:$port"
        print_ok "Wireless debugging found on port $port"
        break
      fi
      adb disconnect "$TABLET_IP:$port" &>/dev/null || true
    done
  fi

  while :; do
    state="$(adb_state "$target")"
    case "$state" in
      device) break ;;
      unauthorized) ;;
      *) return ;;
    esac
    if [ "$waited" -eq 0 ]; then
      print_warn "The tablet doesn't know this PC yet"
      print_info "On its screen: tick 'Always allow from this computer', then Allow. Waiting…"
    elif [ "$waited" -ge 120 ]; then
      print_warn "Not authorized after 2 minutes"
      return
    elif [ $((waited % 30)) -eq 0 ]; then
      # The dialog went away (screen off, timeout): a new connection shows it again.
      adb disconnect "$target" &>/dev/null || true
      adb connect "$target" &>/dev/null || true
    fi
    sleep 3
    waited=$((waited + 3))
  done

  if [ "$target" != "$TABLET_IP:$ADB_PORT" ]; then
    adb -s "$target" tcpip "$ADB_PORT" &>/dev/null || true
    sleep 3
    adb disconnect "$target" &>/dev/null || true
    adb connect "$TABLET_IP:$ADB_PORT" &>/dev/null || true
    if [ "$(adb_state "$TABLET_IP:$ADB_PORT")" != device ]; then
      print_warn "Couldn't move adb to port $ADB_PORT"
      return
    fi
  fi
  HAVE_ADB=true
}

# Shows what is already installed for this tablet, on this PC and — as far as
# the route can see — on the tablet, then asks whether to redo it or stop.
#   SSH:        the tablet's files (player, allowlist) and processes
#   adb only:   installed apps and processes; Termux's files are private
#   --pc-only:  nothing but whether the audio port lets this PC in
# Nothing is removed here: the old pieces go right before the new ones are
# written (STEP 7 and 8), so stopping at any later prompt leaves things working.
detect_existing() {
  print_header "Existing Install"

  EXISTING_NAME=""   # the output's name on this PC, offered back by --pc-only
  local found=false conf slug desc state info line choice
  conf="$(grep -l "pulse.server.address = \"tcp:$TABLET_IP:" "$SINK_CONFIG_DIR"/*.conf 2>/dev/null | head -n1 || true)"
  if [ -n "$conf" ]; then
    slug="$(basename "$conf" .conf)"
    desc="$(sed -n 's/.*node\.description = "\(.*\)"/\1/p' "$conf")"
    state="$(systemctl --user is-active "tablet-sink@$slug.service" 2>/dev/null || true)"
    EXISTING_NAME="$desc"
    print_info "This PC: output '$desc' (tablet-sink@$slug.service, ${state:-unknown})"
    found=true
  else
    print_info "This PC: no output for this tablet"
  fi

  if [ "$PC_ONLY" = true ]; then
    if timeout 5 pactl -s "tcp:$TABLET_IP:$PULSE_PORT" info &>/dev/null; then
      print_info "Tablet: audio port $PULSE_PORT answers and lets this PC in"
    else
      print_warn "Tablet: audio port $PULSE_PORT doesn't let this PC in (tablet off, not set up, or this PC not allowed — see --add-pc)"
    fi
  elif [ "$HAVE_SSH" = true ]; then
    info="$(tablet_ssh "
      grep -m1 '^ *squeezelite ' ~/.termux/boot/start-squeezelite 2>/dev/null | sed 's/^ */player=/'
      grep -q 'Written by android.sh' ~/.termux/boot/start-squeezelite 2>/dev/null && echo ours=yes
      sed -n 's/^load-module module-native-protocol-tcp.*auth-ip-acl=\([^ ]*\).*/acl=\1/p; s/^load-module module-native-protocol-tcp.*auth-anonymous.*/acl=any/p' $TERMUX_PREFIX/etc/pulse/default.pa.d/50-reinstall.pa 2>/dev/null
      pgrep -x squeezelite >/dev/null && echo run_squeezelite=yes
      pgrep -x pulseaudio >/dev/null && echo run_pulseaudio=yes
    " || true)"
    line="$(sed -n 's/^player=//p' <<<"$info")"
    if [ -n "$line" ]; then
      desc="$(sed -n 's/.* -n "\([^"]*\)".*/\1/p' <<<"$line")"
      print_info "Tablet: player '$desc' → $(sed -n 's/.* -s \([^ ]*\).*/\1/p' <<<"$line"), started at boot$(grep -q '^ours=yes' <<<"$info" || echo ' (not written by android.sh)')"
      found=true
    else
      print_info "Tablet: no player boot script"
    fi
    line="$(sed -n 's/^acl=//p' <<<"$info")"
    case "$line" in
      "")  print_info "Tablet: network audio not set up" ;;
      any) print_info "Tablet: network audio open to any address"; found=true ;;
      *)   print_info "Tablet: network audio allowed for ${line//;/, }"; found=true ;;
    esac
    grep -q '^run_squeezelite=yes' <<<"$info" && state=running || state=stopped
    print_info "Tablet: squeezelite $state, PulseAudio $(grep -q '^run_pulseaudio=yes' <<<"$info" && echo running || echo stopped)"
  elif [ "$HAVE_ADB" = true ]; then
    # SSH doesn't answer (new tablet, or one that only knows another PC's key).
    info="$(adb_sh 'pm list packages com.termux; ps -A -o ARGS' | tr -d '\r')"
    for line in com.termux com.termux.boot; do
      grep -qx "package:$line" <<<"$info" && print_info "Tablet: $line installed" || print_info "Tablet: $line not installed"
    done
    if grep -q '^squeezelite ' <<<"$info"; then
      desc="$(sed -n 's/^squeezelite -n \(.*\) -o .*/\1/p' <<<"$info" | head -n1)"
      print_info "Tablet: a player '$desc' is running (set up from another PC — its files can't be read before SSH works)"
      found=true
    else
      print_info "Tablet: no player running"
    fi
  fi

  [ "$found" = true ] || return 0
  echo ""
  ask "This tablet is already installed. What now?"
  if [ "$PC_ONLY" = true ] || [ "$ADD_PC" = true ]; then
    echo "  1) Reconfigure — remove its output from this PC and add it again"
  else
    echo "  1) Reconfigure — remove its output from this PC and its player from the tablet, then set both up again"
  fi
  echo "  2) Stop — change nothing"
  read -rp "Choice [1-2]: " choice
  case $choice in
    1) ;;
    2) print_info "Nothing changed."; exit 0 ;;
    *) print_error "Invalid choice"; exit 1 ;;
  esac
}

# --rename: the tablets installed on this PC, by config file.
RENAME_CONFS=()
rename_list() {
  RENAME_CONFS=()
  local conf
  for conf in "$SINK_CONFIG_DIR"/*.conf; do
    [ -f "$conf" ] && RENAME_CONFS+=("$conf")
  done
}
conf_name() { sed -n 's/.*node\.description = "\(.*\)"/\1/p' "$1"; }
conf_ip()   { sed -n 's/.*pulse\.server\.address = "tcp:\([^:"]*\).*/\1/p' "$1"; }

# rename_apply <conf> <local|player|both> <new name> — returns 1 (after saying
# why) when nothing or only part of it could be done.
rename_apply() {
  local conf="$1" scope="$2" new="$3"
  local old_slug new_slug new_conf
  if ! [[ "$new" =~ ^[A-Za-z0-9][A-Za-z0-9\ _-]*$ ]]; then
    print_error "Use letters, digits, spaces, - and _ only."
    return 1
  fi
  TABLET_IP="$(conf_ip "$conf")"

  if [ "$scope" = player ] || [ "$scope" = both ]; then
    # The name is on the squeezelite line of the boot script, which the running
    # loop has already read: the script is restarted, not just squeezelite.
    # PulseAudio stays up, so the PCs playing on the tablet aren't cut.
    if ! tablet_ssh 'grep -q "^ *squeezelite.* -n \"" ~/.termux/boot/start-squeezelite' 2>/dev/null; then
      print_error "Can't reach the player on $TABLET_IP over SSH (tablet off, or this PC's key not authorized there: --add-pc)."
      return 1
    fi
    tablet_ssh "sed -i 's/^\( *squeezelite.* -n \"\)[^\"]*\"/\1$new\"/' ~/.termux/boot/start-squeezelite"
    tablet_ssh 'pkill -f "boot/[s]tart-squeezelite"; pkill -x squeezelite' || true
    tablet_ssh 'setsid nohup ~/.termux/boot/start-squeezelite >/dev/null 2>&1 &'
    print_ok "Player renamed to '$new'"
  fi

  if [ "$scope" = local ] || [ "$scope" = both ]; then
    old_slug="$(basename "$conf" .conf)"
    new_slug="$(tr '[:upper:] ' '[:lower:]_' <<<"$new" | tr -cd 'a-z0-9_')"
    new_conf="$SINK_CONFIG_DIR/$new_slug.conf"
    if [ "$new_slug" != "$old_slug" ] && [ -e "$new_conf" ]; then
      print_error "'$new' is already the output of another tablet on this PC."
      return 1
    fi
    sed -e "s/node\.name = \"tablet_$old_slug\"/node.name = \"tablet_$new_slug\"/" \
        -e "s/node\.description = \".*\"/node.description = \"$new\"/" \
        -e "s/tablet-sink@$old_slug\.service/tablet-sink@$new_slug.service/" "$conf" > "$WORK/renamed.conf"
    systemctl --user disable --now "tablet-sink@$old_slug.service" 2>/dev/null || true
    rm -f "$conf"
    mv "$WORK/renamed.conf" "$new_conf"
    systemctl --user enable "tablet-sink@$new_slug.service" 2>/dev/null || true
    systemctl --user restart "tablet-sink@$new_slug.service"
    print_ok "Output on this PC renamed to '$new' (tablet-sink@$new_slug.service)"
  fi
}

# Without arguments: pick a tablet, what to rename and the new name, then back
# to the list until "Exit". With <tablet> <local|player|both> <new name>: one
# rename and no question — <tablet> is its IP or its current name on this PC.
rename_main() {
  local conf choice scope new i
  rename_list
  if [ "${#RENAME_CONFS[@]}" -eq 0 ]; then
    print_error "No tablet is installed on this PC."
    exit 1
  fi

  if [ "${#RENAME_ARGS[@]}" -gt 0 ]; then
    if [ "${#RENAME_ARGS[@]}" -ne 3 ] || ! [[ "${RENAME_ARGS[1]}" =~ ^(local|player|both)$ ]]; then
      print_error "Usage: android.sh --rename [<tablet IP or current name> <local|player|both> <new name>]"
      exit 1
    fi
    for conf in "${RENAME_CONFS[@]}"; do
      if [ "$(conf_ip "$conf")" = "${RENAME_ARGS[0]}" ] || [ "$(conf_name "$conf")" = "${RENAME_ARGS[0]}" ]; then
        rename_apply "$conf" "${RENAME_ARGS[1]}" "${RENAME_ARGS[2]}" || exit 1
        return
      fi
    done
    print_error "No tablet '${RENAME_ARGS[0]}' on this PC."
    exit 1
  fi

  while :; do
    print_header "Rename a Tablet"
    i=0
    for conf in "${RENAME_CONFS[@]}"; do
      i=$((i + 1))
      echo "  $i) $(conf_name "$conf") ($(conf_ip "$conf"))"
    done
    echo "  0) Exit"
    read -rp "Choice [0-$i]: " choice || exit 0
    [ "$choice" = 0 ] && break
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt "$i" ]; then
      print_error "Invalid choice"
      continue
    fi
    conf="${RENAME_CONFS[$((choice - 1))]}"

    ask "What should be renamed?"
    echo "  1) The output on this PC"
    echo "  2) The player in squeezelite (the name the music server shows)"
    echo "  3) Both"
    read -rp "Choice [1-3]: " scope || exit 0
    case $scope in
      1) scope=local ;;
      2) scope=player ;;
      3) scope=both ;;
      *) print_error "Invalid choice"; continue ;;
    esac
    read -rp "New name: " new || exit 0
    rename_apply "$conf" "$scope" "$new" || true
    rename_list
  done
}

# --add-pc: the tablet is already set up; only extend its allowlist. The rest
# of its config, the player and the Android settings are left alone.
add_allowed_ips() {
  print_header "Network Audio Access Control"

  local pa_conf="$TERMUX_PREFIX/etc/pulse/default.pa.d/50-reinstall.pa"
  local tcp_line cur_line acl add_ips ip added=""
  tcp_line="$(tablet_ssh "grep -m1 '^load-module module-native-protocol-tcp' $pa_conf 2>/dev/null" || true)"
  if [ -z "$tcp_line" ]; then
    print_error "This tablet wasn't set up by android.sh — run it without --add-pc first."
    exit 1
  fi
  cur_line="$(tablet_ssh 'grep -m1 "^ *squeezelite " ~/.termux/boot/start-squeezelite 2>/dev/null' || true)"
  PLAYER_NAME="$(sed -n 's/.* -n "\([^"]*\)".*/\1/p' <<<"$cur_line")"
  PLAYER_NAME="${PLAYER_NAME:-Tablet}"

  acl="$(sed -n 's/.*auth-ip-acl=\([^ ]*\).*/\1/p' <<<"$tcp_line")"
  if [ -z "$acl" ]; then
    print_ok "'$PLAYER_NAME' has no IP restriction — nothing to add"
    return
  fi
  print_info "Allowed on '$PLAYER_NAME' now: ${acl//;/, }"
  ask "Which addresses should also be allowed to play on it? (this PC's, typically)"
  print_info "Comma-separated IPs and/or CIDRs; the ones already allowed are ignored."
  read -rp "IPs to add (blank = none): " add_ips
  add_ips="${add_ips// /}"
  if ! [[ "$add_ips" =~ ^[0-9A-Fa-f.:/,]*$ ]]; then
    print_error "Only IPs and CIDRs, comma-separated."
    exit 1
  fi
  for ip in ${add_ips//,/ }; do
    case ";$acl;" in *";$ip;"*) continue ;; esac
    acl="$acl;$ip"
    added="$added $ip"
  done
  if [ -z "$added" ]; then
    print_ok "Nothing new to allow"
    return
  fi

  # The module is reloaded rather than the daemon restarted: the music keeps
  # playing, and the PCs already connected come back by themselves in seconds.
  tablet_ssh "sed -i 's|^load-module module-native-protocol-tcp.*|load-module module-native-protocol-tcp port=$PULSE_PORT auth-ip-acl=$acl|' $pa_conf
timeout 10 pactl unload-module module-native-protocol-tcp
timeout 10 pactl load-module module-native-protocol-tcp port=$PULSE_PORT 'auth-ip-acl=$acl' >/dev/null"
  print_ok "Added:$added"
}

# STEPS 5 to 7 of a full run (everything but --add-pc and --pc-only).
setup_player() {
  # ===========================================================================
  # STEP 5 — Player settings
  # ===========================================================================
  print_header "Player"

  # Defaults come from the boot script already on the tablet, if any.
  cur_line="$(tablet_ssh 'grep -m1 "^ *squeezelite " ~/.termux/boot/start-squeezelite 2>/dev/null' || true)"
  cur_name="$(sed -n 's/.* -n "\([^"]*\)".*/\1/p' <<<"$cur_line")"
  cur_server="$(sed -n 's/.* -s \([^ ]*\).*/\1/p' <<<"$cur_line")"
  cur_mac="$(sed -n 's/.* -m \([^ ]*\).*/\1/p' <<<"$cur_line")"
  # Android hides the real MAC and the server keys the player on it, so each
  # tablet gets a fixed made-up one (02: = locally administered).
  [ -n "$cur_mac" ] || cur_mac="$(od -An -N5 -tx1 /dev/urandom | sed 's/^ */02:/; s/ /:/g')"

  PLAYER_NAME="$(ask_default "Player name" "${cur_name:-Tablet}")"
  if ! [[ "$PLAYER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ _-]*$ ]]; then
    print_error "Use letters, digits, spaces, - and _ only."
    exit 1
  fi
  print_info "The Lyrion / Music Assistant host (Music Assistant: its Squeezelite provider must be enabled)."
  SERVER="$(ask_default "Music server address" "$cur_server")"
  if ! [[ "$SERVER" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    print_error "Not a host name or address: '$SERVER'"
    exit 1
  fi
  PLAYER_MAC="$(ask_default "Player MAC" "$cur_mac")"
  if ! [[ "$PLAYER_MAC" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
    print_error "Not a MAC address: '$PLAYER_MAC'"
    exit 1
  fi

  # ===========================================================================
  # STEP 6 — Network audio access control
  # ===========================================================================
  print_header "Network Audio Access Control"

  ask "Restrict who can play on the tablet (PulseAudio, TCP $PULSE_PORT) by IP?"
  print_info "Comma-separated IPs and/or CIDRs — every PC that will use the tablet as an output."
  read -rp "Allowed IPs (blank = no restriction): " ALLOWED_IPS
  ALLOWED_IPS="${ALLOWED_IPS// /}"
  if ! [[ "$ALLOWED_IPS" =~ ^[0-9A-Fa-f.:/,]*$ ]]; then
    print_error "Only IPs and CIDRs, comma-separated."
    exit 1
  fi
  if [ -n "$ALLOWED_IPS" ]; then
    TCP_AUTH="auth-ip-acl=127.0.0.1;${ALLOWED_IPS//,/;}"
    print_ok "Restricting access to: $ALLOWED_IPS"
  else
    TCP_AUTH="auth-anonymous=1"
    print_warn "No IP restriction set — any host that can reach the tablet can play on it"
  fi

  # ===========================================================================
  # STEP 7 — Tablet: PulseAudio config, boot script, (re)start
  # ===========================================================================
  print_header "Configuring the Tablet"

  # The previous player goes first (two calls: see the [s] note below).
  tablet_ssh 'pkill -f "boot/[s]tart-squeezelite"; pkill -x squeezelite; pkill -9 -x pulseaudio' || true
  tablet_ssh "rm -f ~/.termux/boot/start-squeezelite $TERMUX_PREFIX/etc/pulse/default.pa.d/50-reinstall.pa"

  tablet_ssh 'for p in pulseaudio squeezelite; do command -v $p >/dev/null || pkg install -y $p; done'

  # Stock default.pa includes default.pa.d/ and only offers the OpenSL ES sink.
  # AAudio is Android's low-latency path (~20 ms of buffer against ~150).
  # Suspend-on-idle has to go: the AAudio sink sometimes deadlocks the whole
  # daemon while suspending after 5 s of silence.
  tablet_ssh_in "mkdir -p $TERMUX_PREFIX/etc/pulse/default.pa.d && cat > $TERMUX_PREFIX/etc/pulse/default.pa.d/50-reinstall.pa" <<EOF
# Written by android.sh (reinstall) — rewritten at every run.
load-module module-aaudio-sink sink_name=tablet
unload-module module-suspend-on-idle
load-module module-native-protocol-tcp port=$PULSE_PORT $TCP_AUTH
EOF
  print_ok "PulseAudio: AAudio sink 'tablet', TCP $PULSE_PORT"

  tablet_ssh_in 'mkdir -p ~/.termux/boot && cat > ~/.termux/boot/start-squeezelite && chmod 700 ~/.termux/boot/start-squeezelite' <<EOF
#!$TERMUX_PREFIX/bin/sh
# Written by android.sh (reinstall). Termux:Boot runs this once at boot. The
# wake lock keeps Android from suspending Termux; the loop restarts squeezelite
# if it exits. android.sh reads the squeezelite line back: keep its shape.
termux-wake-lock
pulseaudio --start --exit-idle-time=-1

# A PulseAudio that stopped answering takes the player and the network output
# with it: replace it, and squeezelite with it (the loop below restarts it).
# Each replacement is logged: that file is how the hang is counted afterwards.
while sleep 30; do
    timeout 10 pactl info >/dev/null 2>&1 && continue
    echo "\$(date '+%F %T') PulseAudio stopped answering: replaced" >> ~/audio-watchdog.log
    pkill -9 -x pulseaudio
    pulseaudio --start --exit-idle-time=-1
    pkill -x squeezelite
done &

while true; do
    squeezelite -n "$PLAYER_NAME" -o tablet -s $SERVER -m $PLAYER_MAC
    sleep 5
done
EOF
  print_ok "Boot script ~/.termux/boot/start-squeezelite"

  # [s]: keeps pkill -f from matching the shell that runs this very command —
  # hence two calls, the second one has the script's name on its command line.
  tablet_ssh 'pkill -f "boot/[s]tart-squeezelite"; pkill -x squeezelite; pkill -9 -x pulseaudio; sleep 1' || true
  tablet_ssh 'setsid nohup ~/.termux/boot/start-squeezelite >/dev/null 2>&1 &'
  sleep 6
  if tablet_ssh 'timeout 10 pactl list short sinks | grep -q "tablet.*aaudio" && pgrep -x squeezelite >/dev/null'; then
    print_ok "PulseAudio and squeezelite running — '$PLAYER_NAME' should appear on $SERVER"
  else
    print_error "PulseAudio or squeezelite didn't come up — check on the tablet: pactl list short sinks"
    exit 1
  fi
}

if [ "$RENAME" = true ]; then
  rename_main
  exit 0
fi

# =============================================================================
# STEP 0 — What to do on the tablet first
# =============================================================================
if [ "$PC_ONLY" = false ] && [ "$ADD_PC" = false ]; then
  print_header "Before You Start"
  echo "On the tablet (a first install only — skip what is already done):"
  echo ""
  echo "  1. Install F-Droid (https://f-droid.org), then Termux and Termux:Boot"
  echo "     from it — both from F-Droid, never one of them from the Play Store."
  echo "     (Missing ones are installed by this script, without F-Droid's updates.)"
  echo "  2. Settings > About tablet: tap 'Build number' 7 times, then in"
  echo "     Developer options turn on USB debugging."
  echo "  3. Debugging over Wi-Fi, one of:"
  echo "       - plug the tablet in over USB, accept the dialog, run: adb tcpip 5555"
  echo "       - Developer options > Wireless debugging on. A PC the tablet has never"
  echo "         seen must be paired first: Pair device with pairing code, then run"
  echo "         adb pair <ip>:<pairing port>. This script finds the port itself."
  echo "  4. Give the tablet a fixed IP in your router (DHCP reservation). Its"
  echo "     Wi-Fi MAC is under Settings > Wi-Fi > your network; this script also"
  echo "     prints it once connected."
  echo "  5. Remove the lock screen (or the player only starts after the first"
  echo "     unlock following a reboot)."
  echo ""
  read -rp "Press Enter when the tablet is ready… " _
fi

# =============================================================================
# STEP 1 — Tools on this PC
# =============================================================================
print_header "Checking Tools"

if ! command -v pipewire &>/dev/null || ! command -v pactl &>/dev/null; then
  print_error "pipewire and pactl (pipewire-pulse) are needed on this PC."
  exit 1
fi

if [ "$PC_ONLY" = false ]; then
  for tool in curl ssh; do
    if ! command -v "$tool" &>/dev/null; then
      print_error "$tool not found — install it for your distro, then retry."
      exit 1
    fi
  done
  PUBKEY_FILE=""
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$f" ] && { PUBKEY_FILE="$f"; break; }
  done
  if [ -z "$PUBKEY_FILE" ]; then
    print_error "No SSH key (~/.ssh/id_ed25519.pub or id_rsa.pub) — run ssh-keygen, then retry."
    exit 1
  fi
fi
print_ok "Tools present"

# =============================================================================
# STEP 2 — Which tablet
# =============================================================================
print_header "Tablet"

# A previous run on this PC left <name>.conf; offer its address back when
# there is exactly one.
PREV_IP=""
shopt -s nullglob
prev_confs=("$SINK_CONFIG_DIR"/*.conf)
shopt -u nullglob
if [ "${#prev_confs[@]}" -eq 1 ]; then
  PREV_IP="$(sed -n 's/.*pulse.server.address = "tcp:\([^:"]*\).*/\1/p' "${prev_confs[0]}")"
fi

TABLET_IP="$(ask_default "Tablet IP address" "$PREV_IP")"
if ! [[ "$TABLET_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  print_error "Not an IPv4 address: '$TABLET_IP'"
  exit 1
fi

if [ "$PC_ONLY" = false ]; then
  HAVE_SSH=false
  HAVE_ADB=false
  tablet_ssh true &>/dev/null && HAVE_SSH=true
  # --add-pc only needs adb when this PC's key isn't authorized in Termux yet.
  if [ "$ADD_PC" = false ] || [ "$HAVE_SSH" = false ]; then
    if ! command -v adb &>/dev/null; then
      print_warn "adb not found"
      install_with_pkg_manager android-tools
    fi
    connect_adb
  fi

  if [ "$HAVE_ADB" = true ]; then
    print_ok "adb connected"
    # Android uses one random MAC per Wi-Fi network: this is the one the router sees.
    WIFI_MAC="$(adb_sh cmd wifi status 2>/dev/null | grep -io -m1 'MAC: [0-9a-f:]*' | cut -d' ' -f2)"
    [ -n "$WIFI_MAC" ] && print_info "Wi-Fi MAC for the router's DHCP reservation: $WIFI_MAC"
  elif [ "$HAVE_SSH" = true ]; then
    if [ "$ADD_PC" = false ]; then
      print_warn "adb not connected — the Android settings step will be skipped"
      print_info "(adb over Wi-Fi is lost at each tablet reboot: turn on Wireless debugging on the tablet and run this again, or plug USB once and run 'adb tcpip $ADB_PORT')"
    fi
  else
    print_error "Can't reach the tablet over adb ($TABLET_IP:$ADB_PORT) or SSH (port $SSH_PORT)."
    print_info "Enable USB debugging, plug the tablet in, accept the dialog, run 'adb tcpip $ADB_PORT', then retry."
    exit 1
  fi
  [ "$HAVE_SSH" = true ] && print_ok "Termux reachable over SSH — existing install"
  detect_existing

  # ===========================================================================
  # STEP 3 — First install: Termux + Termux:Boot, then sshd (adb only)
  # ===========================================================================
  if [ "$HAVE_SSH" = false ]; then
    print_header "Installing Termux"

    # Both from F-Droid: Termux:Boot only works with a Termux signed by the
    # same key, so a Play Store Termux + F-Droid Termux:Boot does not.
    FRESH_BOOT_APP=false
    installed="$(adb_sh pm list packages)"
    for pkg in com.termux com.termux.boot; do
      if grep -qx "package:$pkg" <<<"$installed"; then
        print_ok "$pkg already installed"
        continue
      fi
      code="$(curl -fsSL --proto '=https' --tlsv1.2 "https://f-droid.org/api/v1/packages/$pkg" |
        sed -n 's/.*"suggestedVersionCode":\([0-9]*\).*/\1/p')"
      if [ -z "$code" ]; then
        print_error "Couldn't read $pkg's version from F-Droid."
        exit 1
      fi
      print_info "Downloading $pkg ($code) from F-Droid"
      curl -fSL --proto '=https' --tlsv1.2 "https://f-droid.org/repo/${pkg}_${code}.apk" -o "$WORK/$pkg.apk"
      adb_ install "$WORK/$pkg.apk"
      print_ok "Installed $pkg"
      [ "$pkg" = com.termux.boot ] && FRESH_BOOT_APP=true
    done

    # adb can't write Termux's private files and can't send it a RUN_COMMAND
    # intent (the shell user lacks the permission), so the first commands go
    # through shared storage and are typed into the Termux window. Everything
    # after that goes over SSH.
    adb_sh 'pm grant com.termux android.permission.READ_EXTERNAL_STORAGE
pm grant com.termux android.permission.WRITE_EXTERNAL_STORAGE' || true

    cat > "$WORK/bootstrap.sh" <<EOF
#!$TERMUX_PREFIX/bin/sh
# Written by android.sh (reinstall): packages, then key-only sshd at boot.
rm -f $BOOTSTRAP_DONE
pkg install -y openssh pulseaudio squeezelite || { echo failed > $BOOTSTRAP_DONE; exit 1; }
mkdir -p ~/.ssh ~/.termux/boot $TERMUX_PREFIX/etc/ssh/sshd_config.d
chmod 700 ~/.ssh
key='$(cat "$PUBKEY_FILE")'
grep -qxF "\$key" ~/.ssh/authorized_keys 2>/dev/null || echo "\$key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo 'PasswordAuthentication no' > $TERMUX_PREFIX/etc/ssh/sshd_config.d/reinstall.conf
if [ ! -e ~/.termux/boot/00-sshd ]; then
  printf '%s\n' '#!$TERMUX_PREFIX/bin/sh' '# Termux:Boot runs this at boot: key-only SSH on port $SSH_PORT.' sshd > ~/.termux/boot/00-sshd
  chmod 700 ~/.termux/boot/00-sshd
fi
pgrep -x sshd >/dev/null || sshd
echo ok > $BOOTSTRAP_DONE
EOF
    adb_ push "$WORK/bootstrap.sh" "$BOOTSTRAP_SCRIPT" >/dev/null
    adb_sh "rm -f $BOOTSTRAP_DONE"

    # An activity started with the screen off is paused at once: wake first.
    adb_sh 'input keyevent KEYCODE_WAKEUP; am start -n com.termux/.app.TermuxActivity' >/dev/null
    print_info "Termux is opening on the tablet; its first start unpacks its files…"
    sleep 20
    # Ctrl+U clears whatever already sits on the prompt (typed text appends).
    adb_sh "input keycombination 113 49 2>/dev/null; input text 'sh%s$BOOTSTRAP_SCRIPT'; input keyevent 66"
    print_info "Typed the install command into Termux. If nothing runs there, type it yourself:"
    print_info "  sh $BOOTSTRAP_SCRIPT"

    print_info "Waiting for the packages and sshd (up to 10 minutes)…"
    result=""
    for _ in $(seq 120); do
      result="$(adb_sh "cat $BOOTSTRAP_DONE 2>/dev/null" | tr -d '\r')"
      [ -n "$result" ] && break
      sleep 5
    done
    adb_sh "rm -f $BOOTSTRAP_SCRIPT $BOOTSTRAP_DONE"
    if [ "$result" != ok ]; then
      print_error "The Termux side didn't finish (${result:-timed out}) — look at the Termux window."
      exit 1
    fi
    if ! tablet_ssh true; then
      print_error "Packages installed, but SSH on port $SSH_PORT doesn't answer."
      exit 1
    fi
    print_ok "Termux packages installed, SSH up"

    if [ "$FRESH_BOOT_APP" = true ]; then
      # Android never delivers BOOT_COMPLETED to an app that was never opened.
      adb_sh 'am start -n com.termux.boot/.BootActivity' >/dev/null
      print_ok "Opened Termux:Boot once"
    fi
  fi

  # ===========================================================================
  # STEP 4 — Android settings (adb only)
  # ===========================================================================
  if [ "$HAVE_ADB" = true ] && [ "$ADD_PC" = false ]; then
    print_header "Android Settings"

    # Without the exemption Android stops Termux in the background.
    adb_sh 'for p in com.termux com.termux.boot; do dumpsys deviceidle whitelist +$p; done' >/dev/null
    print_ok "Battery optimisation off for Termux and Termux:Boot"

    # "Display over other apps": what lets a boot script start an activity.
    adb_sh 'appops set com.termux SYSTEM_ALERT_WINDOW allow'
    adb_sh 'settings put global window_animation_scale 0.5
settings put global transition_animation_scale 0.5
settings put global animator_duration_scale 0.5
settings put global stay_on_while_plugged_in 7'
    print_ok "Animations at 0.5, screen stays on while charging"

    MODEL="$(adb_sh getprop ro.product.model | tr -d '\r')"
    if [ -n "$(debloat_list "$MODEL")" ]; then
      enabled="$(adb_sh pm list packages -e | tr -d '\r')"
      count=0
      while read -r pkg; do
        grep -qx "package:$pkg" <<<"$enabled" || continue
        adb_sh "pm disable-user --user 0 $pkg" >/dev/null && count=$((count + 1))
      done < <(debloat_list "$MODEL")
      print_ok "Disabled $count unused app(s) for $MODEL (undo: adb shell pm enable <package>)"
    else
      print_info "No app list for model '$MODEL' — nothing disabled"
    fi
  fi

  if [ "$ADD_PC" = true ]; then
    add_allowed_ips
  else
    setup_player
  fi
else
  detect_existing
  PLAYER_NAME="$(ask_default "Name for this output" "${EXISTING_NAME:-Tablet}")"
  if ! [[ "$PLAYER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ _-]*$ ]]; then
    print_error "Use letters, digits, spaces, - and _ only."
    exit 1
  fi
fi

# =============================================================================
# STEP 8 — This PC: the tablet as an audio output
# =============================================================================
print_header "Tablet as an Output of This PC"

SLUG="$(tr '[:upper:] ' '[:lower:]_' <<<"$PLAYER_NAME" | tr -cd 'a-z0-9_')"
mkdir -p "$SINK_CONFIG_DIR" "$SYSTEMD_USER_DIR"

# Two tablets with the same name would share one output: the second would
# silently replace the first.
if [ -f "$SINK_CONFIG_DIR/$SLUG.conf" ] && ! grep -q "pulse.server.address = \"tcp:$TABLET_IP:" "$SINK_CONFIG_DIR/$SLUG.conf"; then
  print_error "'$PLAYER_NAME' is already the output of another tablet on this PC — give this one another name."
  exit 1
fi

# Remove what this PC already has for this tablet — under this name or an older
# one (a renamed tablet would stay listed twice) — keeping the priority audio.sh
# gave it.
PRIO_LINE=""
for old in "$SINK_CONFIG_DIR"/*.conf; do
  [ -f "$old" ] || continue
  old_slug="$(basename "$old" .conf)"
  grep -q "pulse.server.address = \"tcp:$TABLET_IP:" "$old" || continue
  [ -n "$PRIO_LINE" ] || PRIO_LINE="$(grep -m1 '^ *priority\.session = ' "$old" || true)"
  systemctl --user disable --now "tablet-sink@$old_slug.service" 2>/dev/null || true
  rm -f "$old"
  print_ok "Removed this tablet's previous output ($old_slug)"
done

# A PipeWire client of its own rather than a module of the session's PipeWire:
# nothing to restart (a PipeWire restart drops every Bluetooth device), and the
# output simply isn't there while the tablet is unreachable. No priority.session
# of our own: without one the node ranks under every real device (never picked
# by default), and audio.sh numbers these outputs when it runs.
cat > "$SINK_CONFIG_DIR/$SLUG.conf" <<EOF
# Written by android.sh (reinstall) — run by tablet-sink@$SLUG.service.
context.properties = {
    log.level = 2
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-rt
        args = { nice.level = -11 }
        flags = [ ifexists nofail ]
    }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-pulse-tunnel
        args = {
            tunnel.mode = sink
            pulse.server.address = "tcp:$TABLET_IP:$PULSE_PORT"
            pulse.latency = $TUNNEL_LATENCY_MS
            reconnect.interval.ms = 5000
            target.object = "tablet"
            audio.rate = 48000
            audio.format = S16LE
            audio.position = [ FL FR ]
            stream.props = {
                node.name = "tablet_$SLUG"
                node.description = "$PLAYER_NAME"
$PRIO_LINE
            }
        }
    }
]
EOF

cat > "$SYSTEMD_USER_DIR/tablet-sink@.service" <<'EOF'
[Unit]
Description=Android tablet %i as an audio output (PulseAudio tunnel)
After=pipewire.service
PartOf=pipewire.service

[Service]
ExecStart=/usr/bin/pipewire -c %h/.config/tablet-sink/%i.conf
Restart=always
RestartSec=5

[Install]
WantedBy=pipewire.service
EOF

systemctl --user daemon-reload
systemctl --user enable "tablet-sink@$SLUG.service" 2>/dev/null && print_ok "Enabled tablet-sink@$SLUG" || true
systemctl --user restart "tablet-sink@$SLUG.service"

found=false
for _ in $(seq 10); do
  if pactl list short sinks 2>/dev/null | grep -q "tablet_$SLUG"; then found=true; break; fi
  sleep 1
done
if [ "$found" = true ]; then
  print_ok "Output '$PLAYER_NAME' is available (pick it in your sound settings)"
else
  print_warn "Output '$PLAYER_NAME' not there yet — it appears once the tablet answers on TCP $PULSE_PORT"
  print_info "Is this PC in the tablet's allowed IPs? Log: journalctl --user -u tablet-sink@$SLUG"
fi

# =============================================================================
# Done
# =============================================================================
print_header "Setup Complete"
echo -e "${GREEN}${BOLD}All done!${NC}"
echo ""
echo -e "  Output on this PC:  ${CYAN}$PLAYER_NAME${NC} (tablet-sink@$SLUG.service)"
echo -e "  On another PC:      ${CYAN}android.sh --add-pc${NC}"
if [ "$PC_ONLY" = false ]; then
  echo -e "  Tablet shell:       ${CYAN}ssh -p $SSH_PORT $TABLET_IP${NC}"
fi
