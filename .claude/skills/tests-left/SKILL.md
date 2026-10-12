---
name: tests-left
description: What was written on 2026-10-11/12 and never run for real, outside the tablet — Input Home on the Android TV, the single-screen refusal, the audio wizard's ranked mics and keepalive tuner, the release build, the Home Assistant side. Use when the user asks what is left to test, wants to continue testing screen.sh or audio.sh, or before trusting one of these features. The tablet's own list is the android-tests-left skill.
---

# Tests still to run (screen, audio, release, Home Assistant)

Written and committed on 2026-10-11/12, tested with stubs or in part only. The tablet
(`android.sh`, tablet-server) has its own list: the `android-tests-left` skill.

When a test below passes, delete its entry here (and tell the user); when it fails, fix the
code and note the trap in `CLAUDE.md`.

Rules: read the "All installers" gotchas of `CLAUDE.md` first — an installer or wizard is
never started with stdin closed or short of answers, and the Go-built parts only reach a
normal run after a `v*` tag (`--local` builds from the checkout).

## Release build

- The first tag after 2026-10-12 is the first time `release.yml` builds `inputhome.apk`
  (`screen/inputhome/build.sh`, which downloads its pinned toolchain) and `tablet-server`
  (android/arm64). Check the run, and that both are among the Release's assets.
- `inputhome.apk` from the Release must carry the same certificate as a local build
  (`INPUTHOME_KEYSTORE_B64` secret): `apksigner verify --print-certs`, SHA-256 starting
  `c2f9a0ea`. If it differs, the installer still works (it replaces the app) but the
  secret didn't apply.

## screen.sh

- **Input Home, whole installer.** Only the Input Home step was run, extracted, against the
  Android TV. To run: a full `screen.sh` (or `--local`) with a TV ticked, answering yes at
  "Install Input Home". Pass: the step installs or updates, says which HDMI input it found,
  and the rest of the install is as before.
- **The command that sets the input** (`am start … TvActivity --es input_id …`) was held
  back in every test: it re-opens the input on the TV, which was in use. Pass: after the
  step, Home on a real remote opens that HDMI input.
- **Long press on Home** opens the stock home screen: never tried (needs a real remote
  that can hold the key; the SwitchBot IR one sends ~260 ms presses).
- **Paths only run against a stubbed adb**: several HDMI inputs with a live source (the
  question), none, a TV that doesn't know the PC (authorization dialog), an app signed by
  another key (uninstall then install), a Release without the APK.
- **Is "state 0" the source or the selected input?** The step pins the only HDMI input in
  state 0. On the one TV tried, HDMI 1 was both live and selected. To settle: with the TV
  showing another input, read `adb shell dumpsys tv_input` and see whether the PC's input
  is still state 0.
- **Single screen refused.** Tested with a fake `kscreen-doctor` returning one output.
  Never on a machine that really has one screen, nor through `screen.sh` (it must stop
  before its cleanup and leave the previous install alone).

## audio.sh — nothing of this ran on the real audio setup

- **The wizard, in a terminal** (`cd audio && go run ./setup` writes for real: run it
  through `audio.sh --local`, on purpose). New steps: "Microphone priority" (ranking, kept
  order offered back), "Keepalive tone — <output>" for each output with a keepalive.
- **The live tuner.** The tone must follow what is typed ("10-5" = 10 kHz at 5 %), 0.4 s
  after the last key; Enter keeps it; an invalid field keeps the last tone playing. Only
  its model was driven by a test, and the player was tried alone for one second.
- **Per-output tone in `audio-watch`**: after an install, `journalctl --user -u audio-watch`
  shows "keepalive on <sink>", and `pgrep -af sine=frequency` shows each device's own
  frequency and volume.
- **Top-ranked mic forced as default**: pick another default by hand in the sound settings;
  it must come back at once (`'change' on server` event — an assumption: if that event
  doesn't come, the 30 s safety pass does it). Unplug the top mic: the next ranked one
  becomes default; plug it back: it takes over again.
- **Do running recordings follow the new default mic?** Expected from
  `linking.follow-default-target`, never observed with a source.
- **Old answers**: a `choices.json` with a single `default_source` must show that mic first
  in the ranking (unit-tested only).

## Home Assistant side (the `ha` session's, on the server)

- The switch "Moonlight tablette" through tablet-server was tested end to end by `ha` on
  2026-10-12. Not tried: the voice command ("allume Moonlight tablette"), and a TV ↔ PC
  switch during a stream (the tablet must come back to Home Assistant, and `ha`'s
  automation must not restart Sunshine a second time).
