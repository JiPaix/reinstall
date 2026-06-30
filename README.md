# reinstall

Personal setup scripts to get a freshly installed machine back to my preferred
display and audio configuration in one command each. Built for Arch-based
systems (pacman / paru / yay) running PipeWire.

Each command downloads a prebuilt helper, walks you through a short interactive
setup, and installs a small background service. No toolchain required.

## Screen

> **GNOME only.** Switching relies on `gdctl`, which ships with GNOME's
> compositor (the `mutter` package). It won't work on other desktops.

Lets you flip your display setup between layouts on demand — for example your
desktop monitors versus the TV — instead of fiddling with display settings each
time. The setup detects your monitors and builds the layouts; a small service
then lets you switch (including remotely over the local network, which pairs
nicely with game streaming).

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/screen.sh)
```

## Audio

> **PipeWire required.** This configures a PipeWire setup; it does not install
> PipeWire for you. Make sure PipeWire (with `pipewire-pulse` and WirePlumber)
> is installed and running first — how varies by distribution.

Sets up the audio path for a soundbar: applies an equalizer, keeps a Bluetooth
soundbar from dozing off mid-silence, and runs a small service that reports the
soundbar's current state over the local network.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/audio.sh)
```

## Notes

- Run them from a real terminal (the setup is interactive). The `bash <(curl …)`
  form above keeps the prompts working — a plain `curl … | bash` would not.
- Binaries are published automatically as a GitHub Release; the scripts pull the
  latest one. To pin a version, set `RELEASE_TAG=vX.Y.Z` before running.
