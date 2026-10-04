---
name: android-tests-left
description: The tests of android.sh (Android tablet as squeezelite player + network audio output) that were still to run when it was written, with steps and pass criteria. Use when the user wants to continue testing android.sh, has a second PC or a second/fresh tablet available, or asks what is left to test on the tablet setup.
---

# android.sh — tests still to run

`android.sh` was written and tested on 2026-10-04 against one tablet (Lenovo TB128FU,
Android 13, already set up by hand) from one PC. Read the `android.sh` gotchas at the end
of `CLAUDE.md` first: they hold the design and every trap met so far.

When a test below passes, delete its section here (and tell the user); when it fails, fix
`android.sh` and note the trap in `CLAUDE.md`.

## Already tested — don't redo

Full run on an existing install (adopt, reconfigure), `--add-pc` (duplicates ignored, a
real addition, live reload without cutting the music), `--pc-only`, `--rename` (menu and
one-shot; Music Assistant shows a player rename at once), existing-install detection over
SSH and over adb alone, name-collision guards with two tablets, tablet reboot (player,
network audio, sshd, Android settings all come back), the Wireless-debugging port search,
the Bluetooth-off fallback to the local output, the audio wizard hiding network outputs.

## Rules while testing

- Find the tablet's address in `~/.config/tablet-sink/*.conf`; Termux answers on SSH 8022.
- Ask before anything the user would hear or lose: restarting the player while music
  plays, test tones, a PipeWire restart (drops Bluetooth), a tablet reboot (adb is lost
  until Wireless debugging is switched on again by hand).
- The allowed-IPs prompt is the user's to answer. To exercise it yourself, re-type the
  current list (shown by the "Existing Install" screen) or add `127.0.0.2`, then restore.
- Never start an interactive installer or wizard with stdin closed or short of answers
  "just to look": at end of input the prompts take their defaults and the run goes on to
  write. That is how `soundbar-setup` once rewrote the real audio config during a test.
  To stop a run early, feed the explicit "Stop" answer, or test a copy with an `exit`
  inserted before the first write.
- To answer prompts from a pipe: `printf 'a\nb\n' | ./android.sh …`. Order for a full run:
  Enter (prerequisites screen), tablet IP, reconfigure/stop (only if something is
  installed), player name, music server, MAC, allowed IPs.

## 1. First install on a fresh tablet

Needs a tablet without Termux (a second tablet; or, only if the user asks, uninstalling
Termux and Termux:Boot on the first one — that wipes its player setup).

Never run so far: the F-Droid downloads and `adb install`; the typed bootstrap (script
pushed to `/sdcard/Download`, `sh …` typed into the Termux window with `input text`); the
SSH key being authorized; Termux:Boot being opened once; the debloat list on another model
(none unless a `debloat_list` case is added); a real "unauthorized" wait or `adb pair`.

Steps: follow the script's "Before You Start" screen with the user, run `./android.sh`,
watch the tablet's screen during "Installing Termux".

Likely trouble spots: the fixed `sleep 20` before typing (Termux's first start may take
longer — then the typed line lands nowhere; the script prints the command to type by hand);
`pkg install` asking a question despite `-y`; the storage permission grant on a newer
Termux/Android; `input keycombination` missing on older Android (it is allowed to fail).

Pass: "Termux packages installed, SSH up", then the run ends like on an existing tablet;
`ssh -p 8022 <ip> true` works; the player shows up in Music Assistant; the output appears
on the PC. Then reboot the tablet and check the player comes back within ~1 minute.

## 2. `--add-pc` from a second PC

Needs another Linux PC with PipeWire (`pipewire`, `pactl`), on the same network.

- Its SSH key is unknown to the tablet, so the route must fall back to adb to authorize it
  (this goes through the same typed bootstrap as test 1 — untested). adb must be reachable:
  port 5555, or Wireless debugging on (the script finds the port; a PC the tablet has never
  seen must first be paired with `adb pair`, or authorized over USB).
- Run `./android.sh --add-pc`, give the second PC's address at "IPs to add".

Pass: the detection screen describes the tablet through adb ("a player … is running"), the
key gets authorized, the address is appended to the allowlist (check
`$PREFIX/etc/pulse/default.pa.d/50-reinstall.pa` and `pactl list short modules | grep tcp`
on the tablet), the output appears on the second PC and plays, and the first PC's output
reconnects by itself within seconds. The player must not restart (same squeezelite pid).

Also worth doing there: `--pc-only` on a PC that is already allowed, and `--rename … local`
giving the tablet a different name on each PC.

## 3. `audio.sh --local` end to end

Restarts PipeWire: Bluetooth devices drop (the script reconnects them). The user launches
it and answers the wizard; `--local` builds the wizard from the checkout (needs Go), which
is what carries the network-output filter.

Pass: no tablet anywhere in the wizard's lists; at "Reloading Services" one line per tablet,
"Network output <name>: priority 100" (99, 98… for further ones); afterwards
`pw-dump | jq -r '.[] | select(.info.props["node.network"]==true) | .info.props | "\(.["priority.session"]) \(.["node.name"])"'`
shows those values, the tablet units are active again (`systemctl --user list-units
'tablet-sink@*'`), and the default output is the highest-ranked local device. With no
tablet installed (`~/.config/tablet-sink` empty or absent) the step must print nothing.

## 4. Rename through a full run

Run `./android.sh` (full), choose Reconfigure, and give a different player name.

Pass: "Removed this tablet's previous output (<old slug>)", a single output for that tablet
on the PC under the new name with its `priority.session` kept, the player renamed in Music
Assistant. Rename it back afterwards (`./android.sh --rename <ip> both "<old name>"`).

## 5. Latency floor, and the hang fix over time

Separate skills: `tablet-latency` (sweep, plays tones, needs the user's ears) and
`tablet-audio-health` (did PulseAudio hang again — meaningful after a few days of use).
On 2026-10-04 the tunnel's journal showed a few underflows at the default 40 ms with no
test running; if the user hears crackles when playing from a PC, run the sweep.
