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
  (`~/.local/bin/swapscreen`) and live tool output (`gdctl show`) over any local copy.
- No `jq`/`envsubst`/Python anywhere in this repo — all codegen is Go (`text/template`+`embed`,
  or hand-built string/XML builders in `*/setup/generate.go`) or plain bash heredocs. `jq` is
  fine to introduce for new bash-side JSON handling in a top-level installer; gate it with the
  same `command -v` + pacman/paru/yay fallback prompt `screen.sh` already uses for `curl`.
- `*.sh` installers can't be run end-to-end outside a real GNOME session (need `gdctl`) and a
  GitHub Release fetch. To test new logic, extract the relevant block with `sed`/`awk` into a
  scratch script, stub `print_*`/`systemctl`, and exercise the file-generation logic in isolation.
