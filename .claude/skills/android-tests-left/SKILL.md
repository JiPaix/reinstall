---
name: android-tests-left
description: The tests of android.sh (an Android tablet as music player, network audio output, Home Assistant and Moonlight screen, with its tablet-server) that are still to run, with steps and pass criteria, plus the open to-dos on the tablet. Use when the user wants to continue testing android.sh, has a second PC or a second/fresh tablet available, or asks what is left to test on the tablet setup.
---

# android.sh — tests still to run

`android.sh` was written and tested on 2026-10-04 against one tablet (Lenovo TB128FU,
Android 13, already set up by hand) from one PC, then reworked on 2026-10-12 (components,
tablet-server, menu by category). Read the `android.sh` gotchas at the end of `CLAUDE.md`
first: they hold the design and every trap met so far. Tests outside the tablet (screen,
audio, release) are in the `tests-left` skill.

When a test below passes, delete its section here (and tell the user); when it fails, fix
`android.sh` and note the trap in `CLAUDE.md`.

## Already tested — don't redo

Full run on an existing install (adopt, reconfigure), `--add-pc` (duplicates ignored, a
real addition, live reload without cutting the music), `--pc-only`, `--rename` (menu and
one-shot; Music Assistant shows a player rename at once), existing-install detection over
SSH and over adb alone, name-collision guards with two tablets, tablet reboot (player,
network audio, sshd, Android settings all come back), the Wireless-debugging port search,
the Bluetooth-off fallback to the local output, the audio wizard hiding network outputs.
Wireless-debugging pairing (2026-10-12, on a phone that had been unpaired: connection port
and pairing port found over mDNS, `adb pair`, then connected — only the final `adb tcpip`
was held back). The component-based full run with tablet-server (2026-10-12, twice on the
Lenovo, an existing install then a re-run): every Android setting, sound, the server, the
PC output and its measured latency; then for real `POST /display/moonlight` (stream up in
~3 s), `POST /display/homeassistant`, and the watcher (stream ordered, `systemctl --user
restart sunshine` on the PC: Home Assistant back in front 7 s later, unasked).
A tablet reboot with tablet-server (2026-10-12, `adb reboot`): SSH back after 106 s, then
without a hand the player, PulseAudio and its TCP port, tablet-server (permissions still
granted, battery protection still on), the dashboard in front ~2 min 20 after the reboot,
this PC's output reconnected; both orders worked afterwards. adb was lost, as expected.

## Rules while testing

- Find the tablet's address in `~/.config/tablet-sink/*.conf`; Termux answers on SSH 8022,
  tablet-server on 7923 (from an allowed address). adb has been off on the Lenovo since its
  reboot of 2026-10-12: what needs it (first install, Android settings, a reboot by command)
  waits for Wireless debugging to be switched on by hand.
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
- To answer prompts from a pipe: `printf 'a\nb\n' | ./android.sh --full --local`
  (`--local` builds tablet-server from the checkout; without it the Release must have it).
  Without an option the script opens on a menu (1 install or reconfigure, 2 rename the
  player, 3 use a tablet as output of this PC, 4 rename that output, 0 quit).
  Order for a full run: Enter (prerequisites screen), tablet IP, reconfigure/stop (only if
  something is installed), components (Enter = what is there), tablet name, then per
  component — music server and MAC; network audio's allowed IPs; the dashboard (not asked
  with `HA_PAGE=…` set); Enter at the Moonlight pairing prompt (first time only) — then
  tablet-server's allowed IPs, and "output of this PC?" (Enter = yes). The latency
  measurement asks nothing (silent, a few minutes; `TUNNEL_LATENCY_MS=<ms>` skips it).
  Last prompt of every run: "Set up another tablet?" — `n`, or end of input, quits.
  The two real runs of 2026-10-12 on the Lenovo used:
  `printf '\n\n1\n\n\n\n\n<audio IPs>\n\n<server IPs>\n\nn\n' | HA_PAGE=… ./android.sh --full --local`
  (one `\n` less on a re-run: no pairing prompt).

## 1. First install on a fresh tablet

Needs a tablet without Termux (a second tablet; or, only if the user asks, uninstalling
Termux and Termux:Boot on the first one — that wipes its player setup).

Never run so far: the F-Droid downloads and `adb install` of F-Droid, Termux, Termux:Boot,
Termux:API and the KISS launcher (checked on 2026-10-12, on the Lenovo: `adb install -i
org.fdroid.fdroid` records F-Droid as the installer, with a throwaway APK removed after;
`cmd package set-home-activity` answers Success where KISS already was the home screen);
the typed bootstrap (script pushed to `/sdcard/Download`,
`sh …` typed into the Termux window with `input text`); the SSH key being authorized;
Termux:Boot being opened once; the debloat list on another model (none unless a
`debloat_list` case is added); a real "unauthorized" wait.

Steps: follow the script's "Before You Start" screen with the user, run `./android.sh --full`
(`--local` as long as no Release has `tablet-server`), watch the tablet's screen during
"Installing Termux".

Likely trouble spots: the fixed `sleep 20` before typing (Termux's first start may take
longer — then the typed line lands nowhere; the script prints the command to type by hand);
`pkg install` asking a question despite `-y`, or its mirror refusing (the bootstrap then
falls back to Termux's main repository — that fallback only ran over SSH so far); the
storage permission grant on a newer Termux/Android; `input keycombination` missing on older Android (it is allowed to fail).

Pass: "Termux packages installed, SSH up", then the run ends like on an existing tablet;
`ssh -p 8022 <ip> true` works; the player shows up in Music Assistant; the output appears
on the PC; `curl http://<ip>:7923/state` answers with a `display` that isn't `unknown`.
Then reboot the tablet and check the player and the server come back by themselves.

## 2. `--add-pc` from a second PC

Needs another Linux PC with PipeWire (`pipewire`, `pactl`), on the same network.

- Its SSH key is unknown to the tablet, so the route must fall back to adb to authorize it
  (this goes through the same typed bootstrap as test 1 — untested). adb must be reachable:
  port 5555, or Wireless debugging on (the script finds the port; a PC the tablet has never
  seen must first be paired with `adb pair`, or authorized over USB).
- Run `./android.sh --add-pc` (or `--this-pc`, the menu's "use a tablet as an audio
  output": it must pick `--add-pc` once SSH works), give the second PC's address at
  "IPs to add".

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
shows those values, the tablet's output is back in `pactl list short sinks` (not only its
unit "active": on 2026-10-10 the unit stayed active with its output gone after
`restart_pipewire` — it now restarts `tablet-sink@*` itself; that line was run alone and
brings the output back, but never inside a real `audio.sh` run), and
the default output is the highest-ranked local device. With no
tablet installed (`~/.config/tablet-sink` empty or absent) the step must print nothing.

## 4. Rename through a full run

Run `./android.sh --full`, choose Reconfigure, and give a different tablet name.

Pass: "Removed this tablet's previous output (<old slug>)", a single output for that tablet
on the PC under the new name with its `priority.session` kept, the player renamed in Music
Assistant, the new name in `GET /capabilities`. The tablet's page in Home Assistant follows
the name (`<dashboard>/<slug>`): the view must exist under the new path first, or run with
`HA_PAGE=<the current page>`. Rename it back afterwards with a second full run.

## 5. Latency floor, and the hang fix over time

Separate skills: `tablet-latency` (sweep, plays tones, needs the user's ears) and
`tablet-audio-health` (did PulseAudio hang again — meaningful after a few days of use).
On 2026-10-04 the tunnel's journal showed a few underflows at the default 40 ms with no
test running; if the user hears crackles when playing from a PC, run the sweep.

## 5. What the component-based run hasn't done yet

Both real runs of 2026-10-12 had all four components on. Never run for real:

- a tablet without the music player (the boot script must keep PulseAudio and its watchdog
  alive, `wait`ing), without network audio (no TCP line in `50-reinstall.pa`, no output
  offered on the PC, the PC's old output removed), with neither (both files gone, nothing
  left running), without Home Assistant or Moonlight (tablet-server refuses that order
  with a 404, and its watcher stays off without Home Assistant);
- a component whose app is missing (it must be left out with a warning);
- `--this-pc`, `--add-pc` and `--pc-only` past their first prompt since the rewrite
  (`--this-pc` was only taken to "Reconfigure / Stop");
- the Moonlight prompts on a PC that isn't the Sunshine host (ids asked by hand);
- a run without `--local` (needs a Release that has `tablet-server`);
- a run over SSH alone, adb gone: the Android settings step must be skipped, and the
  server must still be (re)installed;
- "Set up another tablet?" answered yes with a real second tablet.

Everything else left to test outside the tablet is in the `tests-left` skill.

## To do — the speakers' equalizer, and the jack

Written on 2026-10-21 (`speaker_eqs`, `install_peq`, `tablet/peq/`). JiPaix settled the
Z120 curve by ear that evening (a V, treble shelf +2.5 dB): final, in `speaker_eqs`. The
tablet played through it from 19:46 until ~21:15, when JiPaix, with Dolby off, chose no
equalizer: its `50-reinstall.pa` is back to the no-EQ shape (the EQ one is
`~/50-reinstall.pa.eq-z120.bak`; the 21:15:30 watchdog line is that restart, not a hang).
The profile stays in the installer. android.sh itself never ran it:

- a full run choosing "Logitech Z120": `50-reinstall.pa` has `# speakers:`, `tablet_out`
  (AAudio) and `tablet` (`module-ladspa-sink`); squeezelite and a PC's tunnel play
  through the EQ; a re-run offers the same choice back, and "0" brings back a single
  AAudio `tablet` sink;
- a run without `--local`: needs a Release that has `tablet-peq.so`;
- `tablet-latency` once with the EQ: the filter sink should add nothing measurable.

The jack: **fixed and tested the same day** (CLAUDE.md, Android tablet). Pulled and put back
while music played (19:49): Android moved the stream both ways, a new stream opened in
0.2 s, same daemon, watchdog quiet. Left to see: a long run of plugs (`no_close_hack`
never closes the old stream, one leaked per move; check the daemon's memory after a few
dozen), and whether it also cures the idle-suspend hang (`module-suspend-on-idle` stays
unloaded until someone tries).

## To do — Dolby off, at the next reboot

`sound_effect_apps` (2026-10-21) disables Lenovo's `com.dolby.daxservice` and
`com.dolby.daxappui2`. Done by hand on the kitchen tablet that evening (`pm list packages
-d` lists both), but daxservice is a persistent app: `disable-user` and `force-stop` leave
its process (and the DAP effect it made on session 0, switched off from its screen
beforehand) up until the tablet reboots. After the next reboot, check: no
`com.dolby.daxservice` process (`pidof`), `dumpsys media.audio_flinger | grep -c "name:
DAP$"` → 0, and audio still plays. The "Music Listener" effects (Dolby's, from
`/vendor/etc/audio_effects.xml`, on every music stream) can't be removed without root:
they report streams to DAP and should do nothing without it — not checked by ear. A
reboot drops `adb tcpip`: Wireless debugging by hand afterwards.

## To do — dropouts that remain on the PC link at every latency

Not a test of `android.sh`: an open problem found on 2026-10-12 while measuring the link
(numbers in the `tablet-latency` skill). From 20 ms up, the tunnel still underflows a few
times a minute on some minutes — 2 per minute at 100 ms, 0 at 200 — so no usual
`pulse.latency` is clean, and STEP 9 can only pick "no worse than a long buffer". Nobody
has listened for it yet: JiPaix asked to leave it until he has time to stand in the kitchen.

To do, with him next to the tablet and something playing from the PC through the tablet
output:

- Does he hear a click when `journalctl --user -u tablet-sink@<slug> -f` logs an
  `underflow`? If nothing is audible, close this.
- If it is: find the cause before touching the latency. Untested suspect: the tunnel node
  follows the PC's graph clock (`node.want-driver`, Dummy-Driver or the Bluetooth output)
  while the tablet consumes at its own audio clock, and `module-pulse-tunnel`'s rate
  matching lets the buffer drift until it runs dry. Compare the underflow rate with the
  Bluetooth output playing and not playing, and over Ethernet-only pings for Wi-Fi bursts.

## To do — a tablet of another make

Everything so far ran on one Lenovo TB128FU. Three things are per make and can only be
found with the tablet in hand (JiPaix is looking at an HONOR Pad X8a: same Snapdragon 680
and 4 GB as the Lenovo, Android 14, MagicOS 8):

- **Charge protection**: add a `battery_protection` case. Find the key with
  `adb shell settings list global|system|secure | grep -iE 'charg|batter|protect'`, then
  prove it: flip it and watch `dumpsys battery` go from status 2 (charging) to 4 (not
  charging) within seconds, as the Lenovo's `battery_protected_charge` did.
- **Preloaded apps**: add a `debloat_list` case (`pm list packages`, then `pm disable-user`
  — reversible — for what the owner doesn't use there).
- **Background killing**: MagicOS stops background apps beyond stock Android (Settings >
  App launch > manage manually > Run in background). Termux, Termux:Boot and the Home
  Assistant app must be exempt or the player and the orders stop. Whether adb can set it is
  unknown: look for the setting first, else tell the user to do it in "Before You Start".

## To do — a full run from a factory-reset tablet

Wanted by JiPaix (2026-10-12): reset the Lenovo, then install it from A to Z, to prove the
first-install path (section 1) and that nothing depends on what was set up by hand before.
It wipes the tablet: his decision, and his to start.

What needs him, at the tablet, for about a quarter of an hour:
- Android's own first-boot setup (Wi-Fi, Google account), no lock screen;
- Developer options, Wireless debugging on — then reading out the pairing code when the
  script asks for it (the only thing the script can't see);
- the router's DHCP reservation: Android draws a new random MAC for the network after a
  reset, so the tablet's address changes unless the reservation is redone (the script
  prints the new MAC once adb is connected);
- Home Assistant and Moonlight from the Play Store, signed in, the wake word switched on,
  and Moonlight paired with Sunshine (PIN typed in Sunshine's web page on the PC).

What Claude can then do alone, tablet untouched: run `./android.sh --full --local` with
the answers above, watch "Installing Termux" through adb screenshots (`adb exec-out
screencap -p`), and run the checks of the 2026-10-12 runs (both orders, the watcher).
The allowed-IP prompts are JiPaix's to answer: ask him for both lists before starting.
Before the reset, save what a reset loses and the script doesn't put back: nothing on the
tablet side is known to be in that case, but check `~/.termux/boot/10-dashboard` (the
Home Assistant session's) and ask that session what it keeps there.
