# reinstall

Personal setup scripts to get a freshly installed machine back to my preferred
display, audio and session configuration in one command each. Built for Arch-based
systems (pacman / paru / yay) running PipeWire.

Each command walks you through a short interactive setup. Screen and audio also
download a prebuilt helper and install a small background service. No toolchain
required.

## Screen

> [!NOTE]
> Works on GNOME (via `gdctl`) and KDE Plasma (via `kscreen-doctor`) —
> auto-detected at setup, or force it with `BACKEND=gnome`/`BACKEND=kde`. On KDE
> it also works around the TV HDMI detect-loop (TV off but cable plugged) by
> toggling the connector's DRM status, installing a small root helper + sudoers
> rule for that. Optionally syncs with
> [Sunshine](https://github.com/LizardByte/Sunshine) for game streaming if it's
> installed; works fine without it.

Lets you flip your display setup between layouts on demand — for example your
desktop monitors versus the TV — instead of fiddling with display settings each
time. The setup detects your monitors and builds the layouts; a small service
then lets you switch (including remotely over the local network, which pairs
nicely with game streaming).

If Sunshine is installed, it's also enabled so it starts with every session. On
AMD graphics cards it writes a small ddcutil config too: ddcutil 3.0 probes
monitors in parallel, which freezes the GPU right after login.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/screen.sh)
```

## Audio

> [!IMPORTANT]
> Install these yourself first (package names may vary by distribution):
> `pipewire`, `pipewire-pulse`, `wireplumber`, `ladspa`, `swh-plugins`, `ffmpeg`.

Sets up the audio path for a soundbar: applies an equalizer, keeps a Bluetooth
soundbar from dozing off mid-silence, and runs a small service that reports the
soundbar's current state over the local network.

With a Bluetooth soundbar, the keepalive also kicks in at login when the
soundbar was already connected, and you can have every paired Bluetooth device
reconnect automatically at boot.

It can also install an [MPD](https://www.musicpd.org/) music server that plays
through PipeWire, reachable from the local network with a generated password
(shown at the end, and replaced each time you run it again).

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/audio.sh)
```

## Session

> [!NOTE]
> KDE Plasma with Plasma Login Manager only.

Optionally logs you in automatically at boot, so the services above (display
switching, soundbar status, Sunshine) are back after a reboot without anyone at
the keyboard.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/session.sh)
```

With autologin on, give your wallet an empty password once — KWalletManager →
kdewallet → Change Password… — or apps that store passwords in it will ask for
it after every boot.

## Notes

- Run them from a real terminal (the setup is interactive). The `bash <(curl …)`
  form above keeps the prompts working — a plain `curl … | bash` would not.
- Binaries are published automatically as a GitHub Release; the scripts pull the
  latest one. To pin a version, set `RELEASE_TAG=vX.Y.Z` before running.
