# reinstall

Personal dotfiles-style toolkit. Each top-level `*.sh` (`screen.sh`, `audio.sh`) downloads
prebuilt Go binaries from the latest GitHub Release, runs an interactive TUI setup, generates
a final shell script + systemd units from templates, and installs everything to `~/.local/bin`
/ `~/.config/systemd/user`. `power.sh`, `session.sh` and `android.sh` are the exceptions — see their
gotchas below.

## Gotchas

### All installers

- Machine-specific files generated at install time (`screen/swapscreen.sh`,
  `screen/setup/profiles.conf`, `audio/setup/generated/`) are gitignored and may be absent or
  stale. For what is configured right now, trust the installed script
  (`~/.local/bin/swapscreen`) and live output (`gdctl show` / `kscreen-doctor -o`).
- No `envsubst`/Python: codegen is Go or bash heredocs. `audio/setup/generate.go` uses
  `text/template`+`embed`; `screen/setup/generate.go` uses `//go:embed` + one `strings.Replace`
  of the `#__PROFILES__` marker plus hand-built builders. `jq` is fine for bash-side JSON in a
  top-level installer, gated with `command -v` + the `install_with_pkg_manager` helper (don't
  re-inline the pacman/paru/yay prompt).
- Go modules are per tool (`screen/`, `audio/`, `power/`), never at the root: from the root
  `go vet`/`go test` silently do nothing. `cd screen && go vet ./setup/ && go test ./setup/`.
  `go build ./setup/` fails (output name collides with the dir): `go build -o <path> ./setup/`.
  `power` is a stdlib-only `main.go` with no `setup/` and no wizard.
- The `*.sh` run from the checkout, but everything Go-built — including the engine template,
  `//go:embed`ded into `swapscreen-setup` — comes from the latest GitHub Release. A change
  under `screen/`/`audio/`/`power/` reaches a reinstall only after an annotated `v*` tag
  (`vX.Y.0: summary`) is pushed (`release.yml`); pushing to main is not enough.
- Installers can't run end-to-end outside a graphical session. To test engine logic: replace
  the `#__PROFILES__` line with a `BACKEND=` + `TV_CONNECTORS=(…)` + profile-array block (what
  `generate.go` does), `bash -n`, then stub `gdctl`/`kscreen-doctor`/`sudo`/`systemctl` on
  `PATH` and assert the emitted command order. For an installer, extract the block with
  `sed`/`awk` and stub `print_*`/`systemctl`.
- Never start an installer or a wizard with stdin closed or short of answers "just to look":
  at end of input every prompt takes its default and the run writes for real (`soundbar-setup`
  once rewrote the live audio config that way). Feed the explicit stop/cancel answer, or test
  a copy with an `exit` before the first write.
- The three HTTP servers (`swapscreen-server` :7920, `soundbar-status-server` :7921,
  `poweroff-server` :7922) bind all interfaces, no auth by default. Each installer can lock
  its own down with `ALLOWED_IPS`/`AUTH_TOKEN` in a `server.env` (chmod 600, loaded through
  `EnvironmentFile=-`); the middleware is duplicated in each `main.go` and gates every route,
  `/healthz` included. `ALLOWED_IPS` is asked at every run, blank = no restriction.
  **`power.sh` mints a new token at every run**: an external caller (a Home Assistant
  automation on `/shutdown`) then gets a bare 401 until its token is updated. `screen.sh` and
  `audio.sh` keep theirs (delete `server.env` to rotate). Same rule for the optional MPD
  server (`audio.sh` step 8b): the password in `~/.config/mpd/mpd.conf` is kept, and
  `default_permissions ""` means a wrong password is silently refused everything.

### Screen

- Two backends: `swapscreen-setup -de gnome|kde` (auto: `$XDG_CURRENT_DESKTOP`, else the tool
  on PATH) emits `BACKEND=` atop the profile block; the engine and `screen.sh` dispatch on it
  (`gdctl` / `kscreen-doctor`). GDM greeter layout is GNOME-only; KDE installs a root
  `swapscreen-drm` helper + sudoers rule for the TV DRM loop workaround. Backend quirks are
  documented at their call sites (`screen/setup/kscreen.go`) — read them before touching
  detection.
- TVs (KDE only) are handled per connector, not through the "tv" profile: the wizard asks
  which screens are TVs and emits `TV_CONNECTORS=(…)`, always, even empty (the engine expands
  it under `set -u`). In all three modes the engine wakes every TV of the target profile
  before validating it and sleeps every TV outside it.
- Each TV connector is PINNED: `screen.sh` saves the TV's EDID in
  `/var/lib/swapscreen/edid/<connector>.bin` and `swapscreen-pin-tv.service` re-applies every
  file at boot through amdgpu debugfs (`edid_override` + `force=on`). The connector is then
  always "connected", so a switch works with the TV off — the TV must boot INTO a stable
  signal; a mode change hitting it mid-boot wedges it at "no signal". Those files are also
  how the engine knows a connector is pinned (`tv_pinned`). **Never write a pinned
  connector's sysfs `status`** (`swapscreen-drm off`/`detect`): it overrides the pin until
  reboot; the engine gates this on `tv_pinned`. A TV that is off at a re-run keeps its EDID;
  an un-ticked one is released (`swapscreen-pin-tv --release`, untested on real hardware —
  on failure the pin lasts until the next boot). `screen.sh` migrates the older single
  `/var/lib/swapscreen/tv-edid.bin`.
- `swapscreen-setup` saves its answers in `~/.config/swapscreen-setup/choices.json` and offers
  a layout back when its connectors and modes are still detected (the other backend's answers
  are dropped: mode names differ). On KDE the screens are named from their EDID (`edid.go`).
  `ACCESSIBLE=1` turns the TUI into line prompts: feed answers slowly, descriptions are not
  printed, a select needs its number (Enter does not pick the default).
- `screen.sh` touches nothing of the previous install until the wizard is confirmed (cleanup
  is STEP 4): a cancelled wizard must leave a working machine. The engine's KDE apply is
  deliberately two `kscreen-doctor` calls with a propagation gate between them (kscreen
  submits full-state configs from possibly stale snapshots): don't merge or re-order them.
- `swapscreen-login.service` forces monitor mode at login and its `ExecStart` MUST keep
  `--wait=N`. `graphical-session.target` is reached before the DP connectors are all
  enumerated: `validate_profile` finds one missing, aborts on « profil obsolète », the display
  stays on the previous profile (typically the TV) and a black monitor reads as a machine that
  never booted — with the unit exiting 0. `validate_profile` therefore retries
  `validate_profile_once` until `WAIT_SECS` expires (`_once` returns its message on stdout so
  a wait doesn't emit an error per second). `--wait` defaults to 0, so an interactive failure
  stays immediate.
- KDE HDR and WCG are separate KWin flags. `hdr.disable` alone keeps BT.2020, which the
  Vestel TV treats as HDR: SDR content gets wrong colors. SDR means `hdr.disable wcg.disable`
  (what the Sunshine prep-cmd does). KWin persists both per output in
  `~/.config/kwinoutputconfig.json`, so an HDR-off whose undo never ran survives a reboot; the
  engine re-applying the profile's color on every switch is the repair path — keep it. The
  setup picks `bt2100` only when `kscreen-doctor -j` reports both `hdr` and `wcg` keys.
- Sunshine captures via KMS: `output_name` is a KMS index the engine derives from Sunshine's
  KMS log lines. With `capture = kwin`/`portal` it means something else: switching capture
  method needs an engine change. Probe Sunshine through its journal, never `sunshine
  --version`/`--help`: they start a second instance that truncates
  `~/.config/sunshine/sunshine.log`. The package doesn't enable its user unit: `screen.sh`
  enables then restarts it, so `global_prep_cmd` applies at once.
- ddcutil ≥ 3.0.0 probes I2C buses in parallel, which on amdgpu hangs the GPU ring seconds
  after powerdevil starts at login (`Fence fallback timer expired` → `device lost from bus`).
  It looks like a hardware or kernel fault; it isn't (rockowitz/ddcutil#629). `screen.sh`
  writes `~/.config/ddcutil/ddcutilrc` with `--i2c-bus-checks-async-min 99
  --i2c-init-async-min 99` on amdgpu, only when no rc exists. Check with `ddcutil --verbose
  --version` ("Applying ddcutil options from …"); reproduce without Plasma with `ddcutil
  environment --verbose`. A boot where powerdevil hits EACCES on `/dev/i2c-*` never probes,
  so it proves nothing.

### Power and session

- `poweroff-server` is a **root system service** on purpose (`/etc/systemd/system`, binary in
  `/usr/local/bin`, config in `/etc/poweroff-server/server.env`): `POST /shutdown` must work
  with nobody logged in. `--user` + `loginctl enable-linger` was rejected because linger
  would also start `soundbar-status-server.service` at boot. `power.sh` needs `sudo`.
- `session.sh` (KDE Plasma Login Manager only; no download, no Go) edits `[Autologin]` in
  `/etc/plasmalogin.conf` (other sections untouched, an existing `Session=` wins). Autologin
  is how the `--user` services come back after an unattended reboot, linger being rejected.
  Under autologin `pam_kwallet5` has no password, so it neither unlocks the wallet nor starts
  `ksecretd`: `session.sh` installs `~/.config/systemd/user/ksecretd.service`, started with
  `graphical-session.target`. **Never replace that with a D-Bus activation file for
  `org.freedesktop.secrets`**: ksecretd is a Qt GUI app, gets activated headless and
  crash-loops on "could not connect to display". The one manual step is an empty wallet
  password (KWalletManager → Change Password…).

### Audio

- Extras are per output: the wizard ranks the outputs (`priority.session` from `outputPrio`,
  never hard-coded) and each one picks equalizer / left-right swap / keepalive. **No effect
  is a node of its own**: each is a filter graph set on the device node
  (`audioconvert.filter-graph.N`, `audio/setup/graphs.go`), so nothing extra shows up in the
  output list. Already tried and dropped, don't redo: smart filters (`filter.smart`, still a
  visible sink) and a second output per device (`audio_fx.<sink>`); `fxPrefix`/`fxDir` only
  survive to clean those up.
- Swap and correction EQ are permanent: `98-device-graphs.conf` holds WirePlumber
  `node.filter-graph.rules`, one rule per device, graphs numbered from 0 in rule order (swap,
  then correction). Correction EQs (AutoEq presets) are never asked: the wizard looks each
  output's model up in the embedded `audio/setup/eqdb.json` plus
  `~/.config/soundbar-setup/eqdb.json` (user entries win). The key is the *card's*
  `<bus>:<vendor>:<product>`, never a serial; a Bluetooth entry can add `"device"` (the device
  name) because cheap devices report their chipset's ids. Nodes don't carry those ids, so a
  rule matches `api.alsa.card.name` or the bluez `node.name`.
- **Every graph must be one line under 511 bytes**: an ALSA node drops a longer param value
  (`spa.alsa: can't copy value`). Hence the correction graph is a `param_eq` naming a preset
  file (`~/.config/soundbar-setup/eq/`) and the mbeq graph uses the short plugin name. A set
  graph can't be read back (`pw-dump` shows nothing) and a sink's monitor taps *before* the
  graphs. To check one: raise the log level (`pw-metadata -n settings 0 log.level 4` for ALSA
  nodes, `wpctl set-log-level 4` for Bluetooth ones, which live in WirePlumber) and look for
  `load_filter_graph`, or measure the same graph on a `pw-record` stream.
- **EQ on/off** is one global runtime switch with a single curve (`audio-eq
  on|off|status|apply`, `GET /eq`, `POST /eq/{on,off}`, the `eq` key of `GET /status`). Not a
  WirePlumber rule: `audio-eq` sets the mbeq graph at slot 8 (after the rules' graphs) with
  `pw-cli set-param <node> Props` and clears it for "off"; the swap is untouched. The graph
  dies with the node: the state lives in `~/.local/state/soundbar-setup/eq` and `audio-watch`
  applies it when an equalized device appears — only then, never on every pass (setting it
  again reloads the graph on a playing device).
- `audio-watch.service` (generated `~/.local/bin/audio-watch`) follows `pactl subscribe` under
  `LC_ALL=C` (the output is translated). It hands the EQ state to devices as they appear,
  plays the 18 kHz keepalive tone on the devices that want one while they are connected (and
  kills it itself: a `pw-cat` with `node.dont-reconnect` whose target is gone just sits
  there), and runs `wpctl clear-default` whenever a ranked output comes or goes so the
  priority order decides again. It replaced a udev rule and the
  `soundbar-keepalive`/`soundbar-loopback` units, which `audio.sh`'s cleanup removes.
- Restarting PipeWire/WirePlumber disconnects every Bluetooth audio device and they don't
  come back on their own. So `audio.sh` restarts before the wizard only when it removed a
  config, `restart_pipewire` reconnects the devices that had a node (retrying), and the
  wizard opens on a "Detected devices" screen with a "look again" option. **Don't add a
  restart without going through `restart_pipewire`.**
- The wizard saves its answers in `~/.config/soundbar-setup/choices.json` and pre-fills the
  next run, including outputs that aren't connected. `soundbar-setup -apply` (`cd audio && go
  run ./setup -apply`) re-renders them without a question; it only writes files (rules load
  when WirePlumber starts, `audio-watch` needs a restart). `ACCESSIBLE=1` gives line prompts;
  feed answers slowly (each prompt buffers stdin). Hiding is per card: a Bluetooth device can
  only be hidden whole (`device.disabled` on `bluez_card.*`; on a node match it is ignored).
  `pactl -f json` prints `"(null)"` for a non-ASCII description, hence the fallback on
  `device.description`.
- Mics: `99-device-priorities.conf` sets `session.suspend-timeout-seconds = 0` on every
  `alsa_input.*` (a USB mic resumed by a new recording crackles for 1–2 s). That only stops
  an *idle* node from suspending — nodes still come up `suspended` at every WirePlumber start,
  so `mic-wake.service` opens each mic for 1 s with `pw-record`. Check with `pw-cli info
  <node> | grep state:` (`idle`, not `suspended`). The wizard's default mic gets
  `priority.session = 3000` (stock ALSA mics sit around 2100); it wins only when
  `default-nodes` has no configured source, which is why the cleanup deletes that state file.
- `bt-autoconnect` (optional) is a root system unit, like `poweroff-server`: it must run
  before anyone logs in. It keeps no device list (`bluetoothctl devices Paired`) and retries
  12×10 s within a 240 s budget that must stay under the unit's `TimeoutStartSec`; each
  `bluetoothctl connect` has its own `timeout` (it can hang). `audio.sh` starts it
  `--no-block`. Tunables: `/etc/bt-autoconnect/bt-autoconnect.env`.

### Android tablet

- `android.sh` has no Release download and no Go: adb and ssh against a tablet (Termux +
  Termux:Boot + squeezelite + PulseAudio on TCP 4713), then a PC-side
  `tablet-sink@<slug>.service` (`pipewire -c ~/.config/tablet-sink/<slug>.conf`, a pulse-tunnel
  client of its own so the session's PipeWire is never restarted). On the tablet it owns
  only `~/.termux/boot/start-squeezelite` and `$PREFIX/etc/pulse/default.pa.d/50-reinstall.pa`;
  `00-sshd` is created only when missing. `10-dashboard`, the Home Assistant app and what
  switches apps on the tablet belong to the Home Assistant session's config — never touch.
- Channels: adb can't reach Termux's files (`run-as` fails) nor send `RUN_COMMAND` (the shell
  user lacks the permission), so a fresh install pushes a script to `/sdcard/Download` and
  *types* `sh …` into the Termux window; everything after goes over SSH (8022). That
  first-install path has never been run for real (see the `android-tests-left` skill).
  SSH survives a tablet reboot, `adb tcpip` doesn't, and nothing root-free brings it back
  unattended (`persist.adb.tcp.port` is refused; the `settings` command is refused to app
  uids on Android 13 even with `WRITE_SECURE_SETTINGS`). By hand: Wireless debugging on, then
  `connect_adb` finds its random port by probing 30000–60999 and runs `adb tcpip` to return
  to the fixed one (no pairing for a PC already authorized). A re-run without adb only skips
  the Android settings step.
- Tablet audio: the `module-aaudio-sink` sink (`tablet`) has ~20 ms of buffer against ~150 for
  the stock OpenSL ES one, but **deadlocks the whole PulseAudio daemon when it suspends**
  (intermittent; the log ends on "Sink … idle for too long, suspending"). So the config
  unloads `module-suspend-on-idle` — keep that — and the boot script has a watchdog that
  replaces a daemon that stops answering `pactl info` (logged in `~/audio-watchdog.log`).
  Symptom: `pactl` hangs on the tablet, a PC's tunnel gets "connection failure: Timeout".
- Network outputs (`node.network = true`: the tablets' tunnels) are invisible to the audio
  wizard (`isNetwork` in `audio/setup/pactl.go`). Their `priority.session` can't come from a
  WirePlumber rule — the node belongs to its own `pipewire -c` client — so `audio.sh`
  rewrites it in `~/.config/tablet-sink/*.conf` (100, 99, … in file order) just before its
  PipeWire restart, which restarts the units (`PartOf=pipewire.service`). `android.sh`
  writes none (none = ranks last) and keeps the line `audio.sh` put there. The tunnel's
  remote sink goes in the module args (`target.object = "tablet"`); in `stream.props` it is
  ignored and the stream lands on the tablet's default sink.
- Every route shows what is installed and asks reconfigure/stop (`detect_existing`; SSH sees
  the tablet's files, adb alone only apps and processes, `--pc-only` only the audio port).
  Like `screen.sh`, nothing is removed at that prompt: the old player goes at STEP 7 and the
  PC output at STEP 8, right before the new ones are written — keep it that way. A full run
  replaces the allowlist; `--add-pc` only merges into it and reloads
  `module-native-protocol-tcp` live (music keeps playing, tunnels reconnect in ~3 s).
  `--rename … player` must restart the boot *script*, not just squeezelite (the running
  loop already read the old name), and leaves PulseAudio up. The PC-side and player names
  are independent. The debloat list is per `ro.product.model`: another tablet, another case.
- Bash traps in `android.sh`: every `tablet_ssh` closes stdin (`ssh -n`), or ssh swallows the
  answers typed ahead for the next prompt (`tablet_ssh_in` is for heredoc-fed calls); and a
  `pkill -f` pattern must not appear literally anywhere on the same remote command line —
  the `[s]` trick fails if the script's path is also there, hence two ssh calls.
