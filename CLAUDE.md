# reinstall

Personal dotfiles-style toolkit. Each top-level `*.sh` (`screen.sh`, `audio.sh`) downloads
prebuilt Go binaries from the latest GitHub Release, runs an interactive TUI setup, generates
a final shell script + systemd units from templates, and installs everything to `~/.local/bin`
/ `~/.config/systemd/user`. `power.sh`, `session.sh` and `android.sh` are the exceptions — see their
gotchas below.

## Gotchas

- Machine-specific artifacts generated at install time (`screen/swapscreen.sh`,
  `screen/setup/profiles.conf`, `audio/setup/generated/`) are gitignored and only reflect
  whatever machine/run last generated them locally — don't assume they're present or current.
  For "what's actually configured right now", trust the installed script
  (`~/.local/bin/swapscreen`) and live tool output (`gdctl show` / `kscreen-doctor -o`) over any
  local copy.
- No `jq`/`envsubst`/Python anywhere in this repo — all codegen is Go or plain bash heredocs, but
  the two tools differ: `audio/setup/generate.go` uses `text/template`+`embed`, while
  `screen/setup/generate.go` uses `//go:embed` + one `strings.Replace` of the `#__PROFILES__`
  marker (no templating) plus hand-built string/XML builders. `jq` is fine for new bash-side JSON
  in a top-level installer; gate it with `command -v` + the `install_with_pkg_manager` helper in
  `screen.sh`/`audio.sh` (don't re-inline the pacman/paru/yay prompt).
- Go modules are per-tool (`screen/go.mod`, `audio/go.mod`, `power/go.mod`), never at the repo
  root — build/test from inside: `cd screen && go vet ./setup/ && go test ./setup/`. From the
  root these silently fail (no module). `go build ./setup/` also fails (output name collides with
  the `setup/` dir) — use `go build -o <path> ./setup/`. `power` has no `setup/` subpackage and no
  third-party deps (stdlib-only `main.go`) — there's nothing to configure interactively, so unlike
  screen/audio it skips the TUI-wizard half of the pattern entirely.
- `screen` has two display backends. `swapscreen-setup -de gnome|kde` (auto: `$XDG_CURRENT_DESKTOP`,
  else which tool is on PATH) emits `BACKEND=` atop the profile block; the engine and `screen.sh`
  both dispatch on it (gnome=`gdctl`, kde=`kscreen-doctor`). GDM greeter layout is GNOME-only; KDE
  installs a root `swapscreen-drm` helper + sudoers rule for the TV DRM loop workaround. Backend
  quirks are documented at their call sites (`screen/setup/kscreen.go`) — read them before
  touching detection.
- TV handling (KDE only) is per connector, not tied to the "tv" profile: the wizard asks which of
  the placed screens are TVs and emits `TV_CONNECTORS=(…)` next to `BACKEND=` (always, empty when
  there is none — the engine expands it under `set -u`). The engine wakes every TV of the target
  profile before validating it and puts to sleep every TV outside it, in all three modes.
- The KDE install also PINS each of those connectors: `screen.sh` captures the TV's EDID at setup
  into `/var/lib/swapscreen/edid/<connector>.bin` and `swapscreen-pin-tv.service` re-applies
  every file there at each boot via amdgpu debugfs (`edid_override` + `force=on`), so the
  connector is always "connected" and a switch to it works with the TV off (the TV must boot INTO
  a stable signal — a mode change hitting it mid-boot wedges it at "no signal"). The same files
  are how the engine knows a connector is pinned (`tv_pinned <connector>`). Never write a pinned
  connector's sysfs `status` (swapscreen-drm off/detect): it overwrites the pin until reboot —
  the engine gates this on `tv_pinned`. A TV that is off at a re-run keeps its saved EDID; one
  that is un-ticked is released (`swapscreen-pin-tv --release`: `reset` + `force=unspecified`,
  untested on real hardware — on failure the pin just lasts until the next boot). Earlier
  versions had a single `/var/lib/swapscreen/tv-edid.bin` and the connector in the unit's
  `ExecStart`: `screen.sh` migrates that, and recreates it as a symlink only when the downloaded
  `swapscreen-setup` predates `TV_CONNECTORS` (checkout ahead of the latest Release).
- `swapscreen-setup` saves its answers in `~/.config/swapscreen-setup/choices.json` and offers
  each layout back on the next run when its connectors and modes are still detected (answers
  from the other backend are dropped: mode names differ). `ACCESSIBLE=1` turns the TUI into line
  prompts, with the same caveats as the audio wizard (feed answers slowly; descriptions are not
  printed; a select needs its number, Enter does not pick the default). On KDE the screens are
  named from their EDID (`edid.go`) since kscreen reports no model.
- `screen.sh` touches nothing of the previous install until the wizard is confirmed (the cleanup
  is STEP 4, after it) — keep it that way: a cancelled wizard must leave a working machine.
  The engine's KDE apply is deliberately two kscreen-doctor calls with a propagation gate
  between them (kscreen submits full-state configs from possibly-stale snapshots); don't merge
  them back into one call and don't re-order — the why is commented at each step.
- `swapscreen-login.service` (oneshot, `graphical-session.target`) forces monitor mode at login,
  and its `ExecStart` MUST keep `--wait=N` — don't "simplify" it back to a bare `--monitor`.
  The target is reached before the DP connectors are all enumerated, so `validate_profile` can
  find one missing and abort on « profil obsolète » (the message assumes changed cabling; at
  boot it's just enumeration lag). The switch never happens, the display stays on the previous
  profile — typically the TV — and a black monitor reads as a machine that never booted, with
  the unit still exiting 0. Same class of false negative as `tv_wake_kde`, but on the DP side.
  `validate_profile` therefore retries `validate_profile_once` until `WAIT_SECS` expires;
  `_once` returns its message on stdout instead of calling `out_error` so a long wait doesn't
  emit one error (or one JSON error object) per second. `--wait` defaults to 0 so an interactive
  failure stays immediate — only the login unit passes a non-zero value.
- The `*.sh` installers run from the checkout, but everything Go-built — including the engine
  template, which is `//go:embed`ded into `swapscreen-setup` — comes from the latest GitHub
  Release. A change under `screen/`/`audio/`/`power/` reaches a reinstall only after an annotated
  `v*` tag (`vX.Y.0: summary`, like the existing ones) is pushed; `release.yml` builds and
  attaches the assets. Pushing to main alone is not enough.
- KDE HDR and WCG are separate KWin flags: `hdr.disable` alone keeps BT.2020 colorimetry, which
  the Vestel TV treats as HDR, so SDR content comes out with the wrong colors. SDR means
  `hdr.disable wcg.disable` (the Sunshine prep-cmd in `screen.sh` does this). KWin persists both
  per output in `~/.config/kwinoutputconfig.json`, so an HDR-off whose undo never ran (Sunshine
  killed mid-stream) survives a reboot. The engine re-applying the profile's color on every
  switch is the repair path, so keep it. On KDE the setup picks `bt2100` only when
  `kscreen-doctor -j` reports both `hdr`/`wcg` keys (they're absent on incapable outputs).
- Sunshine captures via KMS: `output_name` is a KMS index that the engine derives from Sunshine's
  KMS log lines. The installed Sunshine also supports `capture = kwin`/`portal`, where
  `output_name` means something else, so switching the capture method needs an engine change.
  Probe Sunshine through its journal, never `sunshine --version`/`--help`: those launch a second
  instance that truncates `~/.config/sunshine/sunshine.log`.
- `*.sh` installers can't run end-to-end outside a real graphical session (need `gdctl` or
  `kscreen-doctor`) and a GitHub Release fetch. To test engine logic, render the template by
  replacing the `#__PROFILES__` line with a `BACKEND=` + `TV_CONNECTORS=(…)` + profile-array block (exactly what
  `generate.go` does), `bash -n` it, then stub `gdctl`/`kscreen-doctor`/`sudo`/`systemctl` on
  `PATH` and assert the emitted command order. For installers, extract the block with `sed`/`awk`
  and stub `print_*`/`systemctl`.
- All three HTTP servers (`swapscreen-server` :7920, `soundbar-status-server` :7921,
  `poweroff-server` :7922) bind all interfaces with no auth by default. `screen.sh`/`audio.sh`/
  `power.sh` optionally (`power.sh`: always asked, not left blank-is-fine) lock this down: an
  `ALLOWED_IPS`/`AUTH_TOKEN` pair generated at install time, written to a `server.env` (chmod
  600), loaded via each unit's `EnvironmentFile=-.../server.env`. The middleware lives in each
  `main.go` (duplicated, not shared — see the per-module gotcha above) and gates every route
  including `/healthz`. **Re-running `power.sh` always generates a brand-new token**, silently
  invalidating the old one — any external caller (e.g. a Home Assistant automation hitting
  `/shutdown`) needs its stored token updated after every reinstall, or it'll get a 401 with no
  other symptom. `screen.sh` and `audio.sh` keep the `AUTH_TOKEN` already in their `server.env`
  (delete the file to rotate it); `ALLOWED_IPS` is still asked every time, and a blank answer
  still means no restriction. The optional MPD server (`audio.sh`
  step 8b) follows the same rule: a "yes" rewrites `~/.config/mpd/mpd.conf` but keeps the
  password found in it (delete the file to rotate); `default_permissions ""` means a client
  with a wrong password is silently refused everything.
- `poweroff-server` breaks the screen/audio pattern on purpose: it's a **root system service**
  (`/etc/systemd/system/poweroff-server.service`, `WantedBy=multi-user.target`, binary in
  `/usr/local/bin`, config in `/etc/poweroff-server/server.env`), not a `--user` unit under
  `$HOME`. It must answer `POST /shutdown` (→ `systemctl poweroff`) even with nobody logged in,
  which a `--user` unit can't do without `loginctl enable-linger` — and linger was rejected here
  because it would also change `soundbar-status-server.service`'s boot behavior (it's
  `WantedBy=default.target`, so linger starts it at boot too, not just after first login) as an
  unrelated side effect. `power.sh` therefore needs `sudo` throughout and installs system-wide,
  unlike `screen.sh`/`audio.sh`.
- `session.sh` (KDE Plasma Login Manager only) downloads nothing and has no Go side: it edits
  `[Autologin]` in `/etc/plasmalogin.conf` (`User=`/`Session=`; other sections untouched, an
  existing `Session=` wins) and, with autologin on, installs `~/.config/systemd/user/ksecretd.service`.
  Autologin is how the `--user` services come back after an unattended reboot, since linger was
  rejected (gotcha above). Under autologin `pam_kwallet5` has no password, so it neither unlocks
  the wallet nor starts `ksecretd`; the unit starts it with `graphical-session.target`. **Never
  "fix" that with a D-Bus activation file for `org.freedesktop.secrets`**: ksecretd is a Qt GUI
  app, gets activated headless (e.g. when booted to `multi-user.target`) and crash-loops on
  "could not connect to display". The one manual step is an empty wallet password
  (KWalletManager → Change Password…).
- Audio extras are per output, not tied to one "primary": the wizard ranks the outputs
  (`priority.session` computed by `outputPrio`, never hard-coded) and each one picks equalizer /
  left-right swap / keepalive. **No effect is a node of its own**: each is a filter graph set on
  the device node (`audioconvert.filter-graph.N`, `audio/setup/graphs.go`), so nothing extra shows
  up in the output list and nothing can stay selected with its device gone. History, so it isn't
  redone: smart filters (`filter.smart`) still create a visible sink; then came a second output
  per device (`audio_fx.<sink>`, a `pipewire -c` client run by `audio-watch`), dropped on request
  once in-node graphs were found — `fxPrefix`/`fxDir` only survive to clean those up.
- Swap and correction EQ are permanent: `98-device-graphs.conf` holds WirePlumber
  `node.filter-graph.rules`, one rule per device, graphs numbered from 0 in rule order (swap,
  then correction). Correction EQs (AutoEq presets, `audio/setup/eqdb.go`) are never asked: the
  wizard looks each output's model up in `audio/setup/eqdb.json` (embedded) plus the optional
  `~/.config/soundbar-setup/eqdb.json` (user entries win). The key is the *card's*
  `<bus>:<vendor>:<product>` (`usb:1532:0555`), never a serial; a Bluetooth entry can add
  `"device"` (must equal the device name) because cheap devices report their chipset's ids.
  Nodes don't carry those ids, so a rule matches `api.alsa.card.name` (USB node names contain
  the serial) or the bluez `node.name`; `model`/`card_name` are saved in `choices.json` for
  outputs that are off.
- **Every graph must be one line under 511 bytes**: an ALSA node drops a longer param value
  (`spa.alsa: can't copy value`). Hence the correction graph is a `param_eq` naming a preset
  file (`~/.config/soundbar-setup/eq/`) and the mbeq graph uses the short plugin name. A set
  graph can't be read back (`pw-dump` shows nothing) and a sink's monitor taps *before* the
  graphs: to check one, raise the log level (`pw-metadata -n settings 0 log.level 4` for ALSA
  nodes, `wpctl set-log-level 4` for Bluetooth ones, which live in the WirePlumber process —
  so does their mbeq) and look for `load_filter_graph`, or measure the same graph set on a
  `pw-record` stream. A mono graph is instantiated once per channel.
- **EQ on/off** is one global runtime switch over every equalized output (`audio-eq
  on|off|status|apply [output…]`, `GET /eq`, `POST /eq/{on,off}`, and the `eq` key of `GET
  /status`), with a single curve (`Choices.EQGains`). It is not a WirePlumber rule: `audio-eq`
  sets the mbeq graph at slot 8 (the last one, after the rules' graphs) with `pw-cli set-param
  <node> Props`, and clears it (`""`) for "off" — the swap, another slot, is untouched. The
  graph dies with the node: the state lives in `~/.local/state/soundbar-setup/eq` and
  `audio-watch` applies it when an equalized device appears — only then, never on every pass:
  setting it again reloads the graph on a playing device.
- `soundbar-setup -apply` (from a checkout: `cd audio && go run ./setup -apply`) renders the
  saved answers again without a question, e.g. after editing the EQ database. It only writes
  files: the rules and priorities load when WirePlumber starts, `audio-watch` needs a restart.
- `audio-watch.service` (generated `~/.local/bin/audio-watch`) replaces the udev rule, the
  `soundbar-keepalive`/`soundbar-loopback` units and the login catch-up; `audio.sh`'s cleanup
  removes those. It follows `pactl subscribe` (under `LC_ALL=C` — the output is translated),
  hands the equalizer state to the devices that have one, plays the 18 kHz tone on the devices that want one while they are
  connected, and runs `wpctl clear-default` whenever a ranked output comes or goes so the
  priority order decides again. It kills the tone itself: a `pw-cat` with `node.dont-reconnect`
  whose target is gone just sits there unlinked. A udev `remove` rule can't match `ATTRS{}`
  (sysfs is already gone), which is how the old design never cleaned up.
- Restarting PipeWire/WirePlumber disconnects every Bluetooth audio device (WirePlumber holds
  their endpoints) and they don't come back on their own, so the wizard would start without
  them. `audio.sh` therefore restarts before the wizard only when it removed a config, its
  `restart_pipewire` reconnects the devices that had a node (retrying: the first connect can be
  refused while the endpoints register), and the wizard opens on a "Detected devices" screen
  with a "look again" option. Don't add a restart without going through `restart_pipewire`.
- The wizard saves its answers in `~/.config/soundbar-setup/choices.json` and pre-fills the next
  run from them, including outputs that aren't connected right now. `ACCESSIBLE=1` turns the TUI
  into line prompts; to script it, feed the answers slowly (each prompt buffers stdin, so lines
  sent ahead are swallowed). Hiding is per card: a Bluetooth device can only be hidden whole
  (`device.disabled` on `bluez_card.*`; on a node match it is ignored). `pactl -f json` prints
  `"(null)"` for any non-ASCII description (translated profile names), hence the fallback on
  `device.description`.
- Mics: `99-device-priorities.conf` sets `session.suspend-timeout-seconds = 0` on every
  `alsa_input.*` (a USB mic resumed by a new recording crackles for 1–2 s). That value only
  stops an *idle* node from suspending — nodes still come up `suspended` at every WirePlumber
  start, so `audio.sh` also installs `mic-wake.service` (`WantedBy=wireplumber.service`), which
  opens each mic for 1 s with `pw-record`. Check with `pw-cli info <node> | grep state:`
  (`idle`, not `suspended`). The wizard's default mic is pinned with `priority.session = 3000`
  (stock ALSA mics sit around 2100); it wins only when `default-nodes` has no configured source,
  which is why the cleanup deleting that state file matters.
- `bt-autoconnect` (optional step in `audio.sh`) is a root system unit for the same reason as
  `poweroff-server`: it has to run before anyone logs in. It keeps no device list (it walks
  `bluetoothctl devices Paired`) and retries 12×10s, capped by a 240 s budget that must stay
  under the unit's `TimeoutStartSec` (an unreachable device costs ~5 s per attempt, and a
  `bluetoothctl connect` can hang, hence the per-call `timeout`); `audio.sh` starts it `--no-block`
  so the first pass doesn't stall the install. Tunables: `/etc/bt-autoconnect/bt-autoconnect.env`.
- ddcutil ≥ 3.0.0 scans I2C buses in parallel once there are enough of them (threshold 4,
  upstream 09263068; 2.2.x used 99). amdgpu has a bus per connector plus one per DP AUX channel,
  and the concurrent probes hang the GPU ring within seconds of powerdevil starting at login
  (`Fence fallback timer expired` → `device lost from bus`) — it looks like a hardware or kernel
  fault, it isn't. `screen.sh` writes `~/.config/ddcutil/ddcutilrc` with
  `--i2c-bus-checks-async-min 99 --i2c-init-async-min 99` on amdgpu, only when no rc exists.
  Check it applies with `ddcutil --verbose --version` ("Applying ddcutil options from …");
  reproduce without Plasma with `ddcutil environment --verbose` (`detect` alone often survives).
  A boot where powerdevil hits EACCES on `/dev/i2c-*` (logind ACL not in place yet, common with
  autologin) never probes, so it proves nothing either way. rockowitz/ddcutil#629.
- The Sunshine package doesn't enable its user unit, so `screen.sh` enables it — then restarts
  it, which also starts it, so `global_prep_cmd` applies immediately.
- `android.sh` is the third exception: no Release download, no Go — adb and ssh against a
  tablet (Termux + Termux:Boot + squeezelite + PulseAudio on TCP 4713), then a PC-side
  `tablet-sink@<slug>.service` (`pipewire -c ~/.config/tablet-sink/<slug>.conf`, a pulse-tunnel
  client of its own so the session's PipeWire is never restarted). Home Assistant's side of
  the tablet (`00-sshd`, `10-dashboard` in `~/.termux/boot`, entities, automations) belongs
  to another session's config: the installer only writes `start-squeezelite` and
  `$PREFIX/etc/pulse/default.pa.d/50-reinstall.pa`, and creates `00-sshd` only when missing.
- adb can't reach Termux's files (`run-as` fails) and can't send `RUN_COMMAND` (the shell
  user lacks the permission), so a fresh install pushes a script to `/sdcard/Download` and
  *types* `sh …` into the Termux window (`input text`); everything after goes over SSH (8022).
  That first-install path has never been run for real — the only tablet so far was set up
  by hand and adopted. adb over Wi-Fi dies at each tablet reboot, SSH doesn't: a re-run
  without adb skips the Android settings step and still works.
- Tablet audio: the `module-aaudio-sink` sink (`tablet`) has ~20 ms of buffer against ~150 for
  the stock OpenSL ES one, but **deadlocks the whole PulseAudio daemon when it suspends**
  (intermittent; the log ends on "Sink … idle for too long, suspending"). So the config
  unloads `module-suspend-on-idle` — keep that — and the boot script has a watchdog that
  replaces a daemon that stops answering `pactl info`. Symptom of a hung daemon: `pactl`
  on the tablet hangs, and a tunnel from a PC gets "connection failure: Timeout".
- In every `tablet_ssh` call, stdin is closed (`ssh -n`): otherwise ssh swallows the answers
  typed ahead for the next prompt (`tablet_ssh_in` is for the heredoc-fed calls). And a
  `pkill -f` pattern must not appear literally anywhere on the same remote command line —
  the `[s]` trick only works if the script's path isn't also there, hence two ssh calls.
- The tunnel's remote sink goes in the module args (`target.object = "tablet"`), not in
  `stream.props` (there it is ignored and the stream lands on the tablet's default sink).
  The debloat list in `android.sh` is per `ro.product.model`; another tablet = another case.
- Network outputs (`node.network = true`: the tablets' tunnels) are invisible to the audio
  wizard (`isNetwork` in `audio/setup/pactl.go`) and are never ranked there. Their
  `priority.session` can't come from a WirePlumber rule — the node belongs to its own
  `pipewire -c` client — so `audio.sh` rewrites it in `~/.config/tablet-sink/*.conf` (100,
  99, … in file order) just before its PipeWire restart, which restarts the units
  (`PartOf=pipewire.service`). `android.sh` writes no priority of its own (none = ranks
  last) and keeps the line `audio.sh` put there on a re-run.
- `android.sh --add-pc` (another PC, tablet already set up) only merges addresses into the
  `auth-ip-acl=` of the tablet's `50-reinstall.pa` and reloads `module-native-protocol-tcp`
  live (no daemon restart: music keeps playing, connected PCs' tunnels reconnect in ~3 s);
  it never rewrites the boot script or the Android settings. A full run, by contrast, asks
  the allowlist from scratch and replaces it. `--pc-only` touches nothing on the tablet.
- `android.sh` detects an existing install on every route (`detect_existing`) and asks
  reconfigure/stop. What it can see depends on the channel: SSH reads the tablet's files and
  processes; adb alone only sees apps and processes (Termux's files are private); `--pc-only`
  only probes the audio port (`pactl -s tcp:…`). Like `screen.sh`, nothing is removed at
  that prompt: the old player (boot script, `50-reinstall.pa`) goes at STEP 7 and the PC
  output at STEP 8, right before the new ones are written — keep it that way, a run
  stopped at a later prompt must leave a working tablet. `00-sshd`/`10-dashboard` never go.
- `android.sh --rename` (menu, or `--rename <ip|name> <local|player|both> <new>` with no
  question for scripts). "local" moves `~/.config/tablet-sink/<slug>.conf` and its unit
  instance to the new slug; "player" seds the `-n "…"` of the tablet's boot script and
  restarts *the script* (the running loop already read the old name), leaving PulseAudio
  up so tunnels aren't cut. The two names are independent after that: `--add-pc` reads the
  player's name, `--pc-only` offers the local one.
- adb after a tablet reboot: `adb tcpip` is gone (and `persist.adb.tcp.port` can't be set
  without root, nor can Termux re-enable anything: the `settings` command is refused to app
  uids on Android 13 even with `WRITE_SECURE_SETTINGS`). What does work without a cable is
  turning Wireless debugging on in the tablet's settings: `connect_adb` then finds its
  random port by probing 30000–60999 (a few seconds; skipped when the tablet doesn't ping),
  connects, and runs `adb tcpip $ADB_PORT` to get back on the fixed port. A PC already
  authorized over USB needs no pairing for that.
