# reinstall

Personal dotfiles-style toolkit. Each top-level `*.sh` (`screen.sh`, `audio.sh`) downloads
prebuilt Go binaries from the latest GitHub Release, runs an interactive TUI setup, generates
a final shell script + systemd units from templates, and installs everything to `~/.local/bin`
/ `~/.config/systemd/user`. `power.sh`, `session.sh` and `android.sh` are the exceptions — see their
gotchas below. What was written but never run for real is listed in two skills: `tests-left`
(screen, audio, release) and `android-tests-left` (the tablet).

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
- Go modules are per tool (`screen/`, `audio/`, `power/`, `tablet/`), never at the root: from
  the root `go vet`/`go test` silently do nothing. `cd screen && go vet ./setup/ && go test
  ./setup/`. `go build ./setup/` fails (output name collides with the dir): `go build -o
  <path> ./setup/`. `power` and `tablet` are a stdlib-only `main.go` with no `setup/` and no
  wizard (`cd tablet && go vet . && go test .`; it is built for `android/arm64`).
- The `*.sh` run from the checkout, but everything built — the Go binaries, including the
  engine template `//go:embed`ded into `swapscreen-setup`, `tablet-server`, and the Input Home
  APK — comes from the latest GitHub Release. A change under `screen/`/`audio/`/`power/`/
  `tablet/` reaches a reinstall only after an annotated `v*` tag (`vX.Y.0: summary`) is
  pushed (`release.yml`); pushing to main is not enough. `screen.sh`, `audio.sh` and
  `android.sh` take `--local` to build from the checkout instead.
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
  A fourth one, `tablet-server` :7923, runs on each tablet (see "Android tablet"): same
  middleware, allowlist only, its `server.env` in Termux.

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
  is STEP 4): a cancelled wizard must leave a working machine. The wizard refuses a single
  screen (look again or quit): the engine tells the modes apart by which primary is lit, so
  one screen in both layouts would always read "tv". The engine's KDE apply is
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
- Input Home (`screen/inputhome/`, an Android TV app: Home key, wake and boot open the HDMI
  input) is `screen.sh`'s last step, asked only when a TV is configured, and never aborts the
  run. It is the one non-Go Release asset: `build.sh` (no Gradle, nothing to install) builds
  `inputhome.apk`, in `release.yml` or with `screen.sh --local`, with a toolchain it downloads
  itself into the gitignored `screen/inputhome/.sdk/` — build-tools, platform and JDK pinned
  by URL and sha256 at the top of the script. Signed with
  `~/.local/share/inputhome/debug.keystore`, created only when missing; an APK from another
  key can't update the installed one, so the installer then uninstalls it first and redoes
  every setting. `enabled_accessibility_services` is a `:` list shared with the TV's other
  services: append, never overwrite. The pinned input is the only HDMI input in state 0 of
  `dumpsys tv_input` (else asked); setting it means starting `TvActivity`, which opens that
  input on the TV at once. `adb shell input keyevent` goes past the accessibility filter:
  only a real remote tests the Home key.
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
  rule matches `api.alsa.card.name` or the bluez `node.name`. An entry's `left`/`right` add a
  preamp and filters to one channel: the graph then also names `filename1`/`filename2`, which
  `param_eq` takes *in place of* the shared preset for that channel, so that file repeats the
  shared filters. The BlackShark's `right` (-1.5 dB, eased in the treble) was set by ear on
  this unit; Rtings' own unit measured 4.3 dB. AutoEq averages both ears, so it never shows.
- **An output's graph stays on one line under 511 bytes** (`maxGraph`): past that the ALSA
  node logs `spa.alsa: can't copy value … (max 511 bytes)` every time the graph is set. The
  error is about the node's own copy only: the converter, which runs the graph, takes the
  whole string and the graph loads (measured on PipeWire 1.6.9 with 1.2 kB, on a source and
  on a sink; not tried on a Bluetooth node). So it is noise, not a failure — and the voice
  chain below lives with it. Hence the correction graph is a `param_eq` naming a preset
  file (`~/.config/soundbar-setup/eq/`) and the mbeq graph uses the short plugin name. A set
  graph can't be read back (`pw-dump` shows nothing; its controls do show in `pw-cli
  enum-params <node> Props`, as `<node name>:<control>`, and can be set live the same way)
  and a sink's monitor taps *before* the graphs. To check one: raise the log level
  (`pw-metadata -n settings 0 log.level 4` for ALSA nodes, `wpctl set-log-level 4` for
  Bluetooth ones, which live in WirePlumber) and look for `load_filter_graph`; or set
  `debug.wav-path` on the node (`pw-cli set-param <id> Props '{ params = [ "debug.wav-path"
  "/path.wav" ] }'`, `""` to stop): the converter then dumps what goes to the device on a
  sink (after the graphs) and what comes from it on a source (before them).
- A microphone's **voice chain** (EQ, compressor, de-esser, limiter) is a graph on the
  mic's own node too, so apps keep picking the mic itself; never asked. One commented
  filter graph per model in `audio/setup/mics/<bus>-<vendor>-<product>.conf`
  (`micchain.go` strips it to one line; the same file name in
  `~/.config/soundbar-setup/mics/` wins), set by one more rule of `98-device-graphs.conf`
  matching `api.alsa.card.name` + `media.class = "Audio/Source"`. ALSA mics only. It is one
  graph of ~3 kB — the de-esser's two parallel branches alone don't fit in 511 bytes — so
  the error above shows up each time the mic appears. Don't move it to `monitor.alsa.rules`
  (a node *property* `audioconvert.filter-graph.N` has no size limit) without solving the
  match: `api.alsa.card.name` isn't on the node yet when those rules run, only the
  serial-bearing `node.name`. The mic's gain comes before the chain: the BlackShark's is
  calibrated at 100 % ("Mic" 67/67) for one voice, by ear, and its output level is the
  limiter's input gain. To re-check it, dump the raw input with `debug.wav-path` while
  `pw-record` takes the mic, render the dump with ffmpeg (`equalizer`/`highpass`… with
  `t=q`, `ladspa=file=sc4m_1916:…`) and subtract: −85 dB on 2026-10-12.
- **EQ on/off** is one global runtime switch with a single curve (`audio-eq
  on|off|status|apply`, `GET /eq`, `POST /eq/{on,off}`, the `eq` key of `GET /status`). Not a
  WirePlumber rule: `audio-eq` sets the mbeq graph at slot 8 (after the rules' graphs) with
  `pw-cli set-param <node> Props` and clears it for "off"; the swap is untouched. The graph
  dies with the node: the state lives in `~/.local/state/soundbar-setup/eq` and `audio-watch`
  applies it when an equalized device appears — only then, never on every pass (setting it
  again reloads the graph on a playing device).
- `audio-watch.service` (generated `~/.local/bin/audio-watch`) follows `pactl subscribe` under
  `LC_ALL=C` (the output is translated). It hands the EQ state to devices as they appear,
  plays the keepalive tone on the devices that want one while they are connected (and
  kills it itself: a `pw-cat` with `node.dont-reconnect` whose target is gone just sits
  there), and runs `wpctl clear-default` whenever a ranked output or mic comes or goes so
  the priority order decides again. The tone is per output (18 kHz at 5 % unless tuned;
  `tone_hz`/`tone_vol` in `choices.json`): the wizard's tuner (`audio/setup/tone.go`) plays
  it live on the device while "kHz-percent" is typed. 100 % is ffmpeg's sine at 1/8 of full
  scale, so a typo can't blast a speaker. It replaced a udev rule and the
  `soundbar-keepalive`/`soundbar-loopback` units, which `audio.sh`'s cleanup removes.
- **The tone's volume is the level at the device, whatever the output's volume.** Most
  Bluetooth speakers have no absolute volume: the PC applies it to the samples
  (`softVolumes` on the node), the tone's included — at 19 % a 5 % tone reached the soundbar
  at −90 dBFS and it fell asleep after its 15 min (measured 2026-10-14; a tone reaching it at
  −44 dBFS kept it awake, at 19 % and at 5 %). So the tone is boosted by 1/`softVolumes`
  (`toneGain`, the same formula in `audio-watch`), sent as f32, and replayed when a
  `'change' on sink` shows the volume moved: at once when it rose (the tone is too strong
  meanwhile), after 0.5 s of quiet when it fell. **The boost stops where the tone reaches
  full scale before the volume** (≈ 18 % for 5 %), so a volume raised in one go can never
  clip it (a clipped 18 kHz tone is audible) — the user chose that over covering 5 %. Below,
  the tone weakens again. No way around the volume on one node: a filter graph runs
  *before* it (a `sine` graph was tried), and only the dropped two-node layout kept the
  device at 100 %. The tone carries `node.dont-move`: boosted, it must never be dragged to
  a headset. `channelmix.lock-volumes = true` (`pw-cli set-param <node> Props`) freezes a
  node's applied volume — pactl still reports the requested one — a guard for live tests.
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
  <node> | grep state:` (`idle`, not `suspended`). The mics are ranked in the wizard
  like the outputs (`priority.session` 3000 and up, by `micPrio`; stock ALSA mics sit around
  2100): the highest one connected wins only when `default-nodes` has no configured source,
  which is why the cleanup deletes that state file. On top of that `audio-watch` forces it:
  at every pass, and on every `'change' on server` event (a default changed), the first
  ranked mic that is connected is set as default source if it isn't. Outputs are not forced
  that way: a hand-picked one lasts until a ranked output comes or goes. A `choices.json`
  from before the ranking has a single `default_source`: it becomes the first ranked mic.
- `bt-autoconnect` (optional) is a root system unit, like `poweroff-server`: it must run
  before anyone logs in. It keeps no device list: every paired device with the Audio Sink
  UUID, read from BlueZ at each pass, the wizard's ranked Bluetooth outputs first
  (`/etc/bt-autoconnect/order`, rewritten by `audio.sh`), the ones hidden in the wizard
  (`disabled_bt` → `/etc/bt-autoconnect/hidden`) skipped. **Audio outputs only, and calling
  in parallel doesn't help**: the radio pages one device at a time (two parallel connects to
  absent devices: 5 s, then 10 s) and while it pages an absent one (5 s; 20 s for a BLE
  controller) a speaker switched on meanwhile waits — with the controllers in the loop, the
  soundbar once waited ~20 s at boot. It retries 12×10 s within a 240 s budget that must
  stay under the unit's `TimeoutStartSec`; each `bluetoothctl connect` has its own `timeout`
  (it can hang), capped by what is left of the budget. `audio.sh` starts it `--no-block`.
  Tunables: `/etc/bt-autoconnect/bt-autoconnect.env`.

### Android tablet

- `android.sh` works by adb and ssh against a tablet, and has no wizard. What the tablet
  does is chosen per run, four components: music player (squeezelite), network audio
  (PulseAudio on TCP 4713), Home Assistant, Moonlight. Over adb it installs F-Droid, then
  Termux, Termux:Boot and Termux:API with `-i org.fdroid.fdroid` so they count as F-Droid
  installs; the KISS launcher becomes the home screen only when the script is what installs
  it. PC side: `tablet-sink@<slug>.service` (`pipewire -c ~/.config/tablet-sink/<slug>.conf`,
  a pulse-tunnel client of its own so the session's PipeWire is never restarted), only with
  network audio and asked. On the tablet it owns `~/.termux/boot/start-squeezelite` (also the
  boot script when there is no player: PulseAudio and its watchdog),
  `$PREFIX/etc/pulse/default.pa.d/50-reinstall.pa`, `~/.termux/boot/20-tablet-server`,
  `~/.local/bin/tablet-server{,-run}` and `~/.config/tablet-server/server.env` (its own
  answers, read back as the next run's defaults); `00-sshd` is created only when missing.
  `10-dashboard` and the Home Assistant app's own settings belong to the Home Assistant
  session's config — never touch. Home Assistant and Moonlight themselves are installed and
  signed in by hand (Play Store, accounts, the Sunshine PIN): a prerequisite, not a step.
- `tablet-server` (`tablet/`, stdlib-only like `power/`, built `GOOS=android GOARCH=arm64`
  with no cgo — the `linux` build doesn't answer in Termux) is the one Release asset of
  `android.sh`, or built with `--local`. Port 7923, same `ALLOWED_IPS`/`AUTH_TOKEN`
  middleware as the PC's three; the script sets an allowlist only (Home Assistant is to need
  nothing but the address) and adds 127.0.0.1 to check it from the tablet. `GET
  /capabilities`, `GET /state` (display / screen / battery), `POST
  /display/{homeassistant,moonlight}`. It runs as Termux, which sees nothing of the screen
  until adb grants it `DUMP` **and** `PACKAGE_USAGE_STATS` (`dumpsys activity activities`
  wants both; `window` and `battery` stay unreachable, hence Termux:API for the battery).
  "moonlight" means the stream: `com.limelight/.Game` on top *and* focused — Moonlight's
  error box ("connection terminated", after any Sunshine restart) sits on that same activity
  and only the focus tells. Its watcher brings Home Assistant back when a stream ends unasked
  or an ordered one never comes up (45 s); a focus lost for under ~8 s is ignored (system
  panels). Nothing in it talks to the PC, and the Sunshine session is left paused on purpose
  (closing it on a client's departure would cut other clients). Termux traps: `am start`
  exits 1 with a stack trace after starting the activity all right — judge by the screen;
  `pkill -x` compares with the command as typed, so the server is started by its bare name;
  a boot script must return (the server's loop is a script of its own, started with
  `setsid`); Termux can't wake the screen, stop another app or read `/sys` power files.
- Moonlight on command needs the PC's id and the app's: `sunshine_uuid` reads
  `~/.config/sunshine/sunshine_state.json`, `sunshine_app_id` computes Sunshine's own id
  (CRC32 of the name + the SHA-256 of its image, as a positive int32 — `gzip | tail -c8` for
  the CRC). Both extras go to `ShortcutTrampoline` as strings; without `AppId` Moonlight
  opens its app list. Moonlight has no intent or setting to quit a stream.
- The tablet's name is asked once and is its player, its PC output and its page in Home
  Assistant (`<dashboard>/<slug>`; `HA_PAGE=…` in the environment points elsewhere).
  `TABLET_ID` is its serial number where adb reads it, kept across runs. `--rename` still
  renames the player or the PC output alone, not that name.
- Channels: adb can't reach Termux's files (`run-as` fails) nor send `RUN_COMMAND` (the shell
  user lacks the permission), so a fresh install pushes a script to `/sdcard/Download` and
  *types* `sh …` into the Termux window; everything after goes over SSH (8022). That
  first-install path has never been run for real (see the `android-tests-left` skill).
  SSH survives a tablet reboot, `adb tcpip` doesn't, and nothing root-free brings it back
  unattended (`persist.adb.tcp.port` is refused; the `settings` command is refused to app
  uids on Android 13 even with `WRITE_SECURE_SETTINGS`). By hand: Wireless debugging on, then
  `connect_adb` finds its random port (mDNS through `avahi-browse`: this adb build has no
  mdns of its own; else by probing 30000–60999) and runs `adb tcpip` to return to the fixed
  one. An unpaired PC gets a plain "failed to connect", never "unauthorized": when the port
  is announced yet refuses, `pair_adb` finds the pairing port the same way and asks for the
  code. A re-run without adb only skips
  the Android settings step. `pkg install` can fail on a tablet whose Termux mirror
  throttles (429): `tablet_pkg` then installs from `packages.termux.dev` for that once,
  without touching `sources.list`.
- `android.sh` without an option opens on a menu by category — on a tablet: install or
  reconfigure, rename its player; on this PC: use a tablet as output, rename that output
  (`--full`, `--this-pc`, `--add-pc`, `--pc-only`, `--rename` skip it; end of input at the
  menu quits). `--this-pc` is `--add-pc` when the tablet answers on SSH, else `--pc-only`.
  A full run asks everything (`choose_setup`) before it changes anything. Its main flow is the
  body of `setup_one_tablet`, left at the margin, so that the end of the script can offer
  another tablet; an `exit` anywhere in it still ends the run. Every mode that writes
  the PC-side output ends by measuring `pulse.latency` itself (STEP 9), no ear needed: a
  probe client beside the installed one plays 60 s of silence per value and counts the
  tunnel's `underflow` lines (silence underflows like sound; an *idle* tunnel is corked and
  never does). The longest step is the reference, then the shortest step that is no worse
  wins; `TUNNEL_LATENCY_MS` imposes a value instead. Counts swing from one minute to the
  next (20 ms: 0 to 5 per 30 s the same night), so the result can move by a step between
  runs. Don't query the tablet (`pactl` over SSH) during a probe: that alone causes an
  underflow. The tablet's own ~16 ms buffer has no knob: `module-aaudio-sink`'s `latency=`
  only changes what it reports, and it already opens AAudio in low-latency mode.
- Tablet audio: the `module-aaudio-sink` sink (`tablet`) has ~20 ms of buffer against ~150 for
  the stock OpenSL ES one, but **deadlocks the whole PulseAudio daemon when it suspends**
  (intermittent; the log ends on "Sink … idle for too long, suspending"). So the config
  unloads `module-suspend-on-idle` — keep that — and the boot script has a watchdog that
  replaces a daemon that stops answering `pactl info` (logged in `~/audio-watchdog.log`).
  Symptom: `pactl` hangs on the tablet, a PC's tunnel gets "connection failure: Timeout".
  Plugging or unplugging the jack hung it the same way (the module closes its stream
  from its own error callback when Android moves it), and the watchdog's restart
  dropped the player from Music Assistant: hence `no_close_hack=1` on the AAudio sink
  (stop, then a new stream; tested 2026-10-21, jack out and back in, music on, same
  daemon). Keep it.
- **The speakers' equalizer** (asked at a full run, `speaker_eqs`: one `name|controls` line
  per speaker) is `module-ladspa-sink` with `peq`, a LADSPA plugin of our own
  (`tablet/peq/`): Termux packages no LADSPA equalizer. It is built freestanding (no libc,
  no libm, a fixed pool of instances) so clang and lld make it without an NDK; `build.sh
  test` checks it on the host, `build.sh curve <controls>` prints a curve and its highest
  point, which the preamp must cancel, and refuses a list that isn't exactly 25 values
  (the module would refuse it too). Release asset `tablet-peq.so`, installed in
  `$PREFIX/lib/ladspa` (the module's default path). With an EQ the AAudio sink becomes
  `tablet_out` and the EQ sink takes the name `tablet`, so squeezelite's `-o tablet` and
  the tunnels' `target.object` need no change. An EQ line the module refuses leaves the
  daemon up without `tablet` (seen 2026-10-21): squeezelite exits, the player is gone. Controls can't be changed on a loaded sink without D-Bus: to try a
  curve live, load a second EQ sink on top of `tablet` and `pactl move-sink-input` the
  stream (no cut), then unload the first.
- Network outputs (`node.network = true`: the tablets' tunnels) are invisible to the audio
  wizard (`isNetwork` in `audio/setup/pactl.go`). Their `priority.session` can't come from a
  WirePlumber rule — the node belongs to its own `pipewire -c` client — so `audio.sh`
  rewrites it in `~/.config/tablet-sink/*.conf` (100, 99, … in file order) just before its
  PipeWire restart. `restart_pipewire` restarts the `tablet-sink@*` units itself: it kills
  and starts PipeWire, which is no restart job, so `PartOf=pipewire.service` doesn't carry
  over — and a tunnel client that lost its daemon doesn't exit, it stays "active" with its
  sink gone (seen on 2026-10-10, before that line existed). `android.sh`
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
  loop already read the old name), and leaves PulseAudio up. A full run gives the player
  and the PC output the tablet's name; `--rename` can still make them differ, and a PC
  added with `--this-pc` names its own output. A full run without network audio removes this
  PC's output for that tablet. The debloat list, the charge-protection setting and the
  maker's sound processing (`sound_effect_apps`) are per `ro.product.model`: another
  tablet, another case (Lenovo: `battery_protected_charge`; Dolby's DAP, which levels
  everything the tablet plays, after PulseAudio — it made a 12 dB quieter Assist voice
  sound the same. No `settings` key holds it: its service is disabled, and being a
  persistent app it keeps running until the next reboot).
- Bash traps in `android.sh`: every `tablet_ssh` closes stdin (`ssh -n`), or ssh swallows the
  answers typed ahead for the next prompt (`tablet_ssh_in` is for heredoc-fed calls); and a
  `pkill -f` pattern must not appear literally anywhere on the same remote command line —
  the `[s]` trick fails if the script's path is also there, hence two ssh calls.
