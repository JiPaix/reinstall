# reinstall

Personal dotfiles-style toolkit. Each top-level `*.sh` (`screen.sh`, `audio.sh`) downloads
prebuilt Go binaries from the latest GitHub Release, runs an interactive TUI setup, generates
a final shell script + systemd units from templates, and installs everything to `~/.local/bin`
/ `~/.config/systemd/user`.

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
- Go modules are per-tool (`screen/go.mod`, `audio/go.mod`), never at the repo root — build/test
  from inside: `cd screen && go vet ./setup/ && go test ./setup/`. From the root these silently
  fail (no module). `go build ./setup/` also fails (output name collides with the `setup/` dir) —
  use `go build -o <path> ./setup/`.
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
- `*.sh` installers can't run end-to-end outside a real graphical session (need `gdctl` or
  `kscreen-doctor`) and a GitHub Release fetch. To test engine logic, render the template by
  replacing the `#__PROFILES__` line with a `BACKEND=` + profile-array block (exactly what
  `generate.go` does), `bash -n` it, then stub `gdctl`/`kscreen-doctor`/`sudo`/`systemctl` on
  `PATH` and assert the emitted command order. For installers, extract the block with `sed`/`awk`
  and stub `print_*`/`systemctl`.
- Both HTTP servers (`swapscreen-server` :7920, `soundbar-status-server` :7921) bind all
  interfaces with no auth by default. `screen.sh`/`audio.sh` optionally lock this down: an
  `ALLOWED_IPS`/`AUTH_TOKEN` pair generated at install time, written to
  `~/.config/<service-name>/server.env` (chmod 600, outside the repo — not gitignored, just not
  tracked), loaded via each unit's `EnvironmentFile=-%h/.config/.../server.env`. The middleware
  lives in each `main.go` (duplicated, not shared — see the per-module gotcha above) and gates
  every route including `/healthz`. **Re-running the installer always generates a brand-new
  token**, silently invalidating the old one — any external caller (e.g. a Home Assistant
  automation hitting `/mode/{tv,monitor}`) needs its stored token updated after every reinstall,
  or it'll get a 401 with no other symptom.
