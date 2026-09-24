# reinstall

Personal dotfiles-style toolkit. Each top-level `*.sh` (`screen.sh`, `audio.sh`) downloads
prebuilt Go binaries from the latest GitHub Release, runs an interactive TUI setup, generates
a final shell script + systemd units from templates, and installs everything to `~/.local/bin`
/ `~/.config/systemd/user`. `power.sh` and `session.sh` are the exceptions — see their gotchas
below.

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
  `screen.sh` (don't re-inline the pacman/paru/yay prompt).
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
- The KDE install also PINS the TV connector: `screen.sh` captures the TV's EDID at setup and
  `swapscreen-pin-tv.service` re-applies it at every boot via amdgpu debugfs (`edid_override` +
  `force=on`), so the connector is always "connected" and `swapscreen --tv` works with the TV
  off (the TV must boot INTO a stable signal — a mode change hitting it mid-boot wedges it at
  "no signal"). Never write the connector's sysfs `status` (swapscreen-drm off/detect) on a
  pinned system: it overwrites the pin until reboot — the engine gates this on `tv_pinned`.
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
  replacing the `#__PROFILES__` line with a `BACKEND=` + profile-array block (exactly what
  `generate.go` does), `bash -n` it, then stub `gdctl`/`kscreen-doctor`/`sudo`/`systemctl` on
  `PATH` and assert the emitted command order. For installers, extract the block with `sed`/`awk`
  and stub `print_*`/`systemctl`.
- All three HTTP servers (`swapscreen-server` :7920, `soundbar-status-server` :7921,
  `poweroff-server` :7922) bind all interfaces with no auth by default. `screen.sh`/`audio.sh`/
  `power.sh` optionally (`power.sh`: always asked, not left blank-is-fine) lock this down: an
  `ALLOWED_IPS`/`AUTH_TOKEN` pair generated at install time, written to a `server.env` (chmod
  600), loaded via each unit's `EnvironmentFile=-.../server.env`. The middleware lives in each
  `main.go` (duplicated, not shared — see the per-module gotcha above) and gates every route
  including `/healthz`. **Re-running an installer always generates a brand-new token**, silently
  invalidating the old one — any external caller (e.g. a Home Assistant automation hitting
  `/mode/{tv,monitor}` or `/shutdown`) needs its stored token updated after every reinstall, or
  it'll get a 401 with no other symptom. Same for the optional MPD server (`audio.sh` step 8b):
  every "yes" rewrites `~/.config/mpd/mpd.conf` with a new password, and `default_permissions ""`
  means clients still using the old one are silently refused everything.
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
- `soundbar-keepalive`/`soundbar-loopback` are **never enabled**: `99-soundbar-keepalive.rules`
  starts/stops them when the Bluetooth soundbar's input device appears/disappears. An enabled
  copy runs at every login with the soundbar off (tone on the fallback sink, default sink pointed
  at `bt_swap_sink`), so `audio.sh`'s cleanup disables any. The rule can't reach a user manager
  that doesn't exist yet (soundbar connected at boot, before login), hence the generated
  `soundbar-keepalive-login.service`: a oneshot whose `ExecCondition` greps
  `/sys/class/input/input*/name` for the rule's input name — read back from the staged rule,
  because `vars.sh` doesn't carry it — then starts both units with `--no-block`.
- `bt-autoconnect` (optional step in `audio.sh`) is a root system unit for the same reason as
  `poweroff-server`: it has to run before anyone logs in. It keeps no device list (it walks
  `bluetoothctl devices Paired`) and retries 12×10s; `audio.sh` starts it `--no-block` so the
  first pass doesn't stall the install. Tunables: `/etc/bt-autoconnect/bt-autoconnect.env`.
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
