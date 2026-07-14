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
- `*.sh` installers can't run end-to-end outside a real graphical session (need `gdctl` or
  `kscreen-doctor`) and a GitHub Release fetch. To test engine logic, render the template by
  replacing the `#__PROFILES__` line with a `BACKEND=` + profile-array block (exactly what
  `generate.go` does), `bash -n` it, then stub `gdctl`/`kscreen-doctor`/`sudo`/`systemctl` on
  `PATH` and assert the emitted command order. For installers, extract the block with `sed`/`awk`
  and stub `print_*`/`systemctl`.
