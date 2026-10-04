# reinstall

Personal setup scripts to get a freshly installed machine back to my preferred
display, audio and session configuration in one command each — plus one that
sets up an Android tablet as a network speaker. Built for Arch-based
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

Sets up your audio outputs: you rank them, and the highest one connected is the
one that plays. Each device can get a voice-clarity equalizer, swapped
left/right channels, and a keepalive that stops it dozing off mid-silence.

All of it is applied on the device itself: no extra output shows up in your
sound settings. A device whose model has a known correction EQ (an
[AutoEq](https://autoeq.app/) preset that flattens what the manufacturer got
wrong) also gets it automatically, before the voice equalizer. The known models
are in [`audio/setup/eqdb.json`](audio/setup/eqdb.json); add your own in
`~/.config/soundbar-setup/eqdb.json`, same format.

A small service on the local network reports whether one of the outputs (a
soundbar, typically) is playing, and switches the equalizer on or off for every
output that has one:

| Request | Answer |
| --- | --- |
| `GET /status` | `{ "soundbar": true, "eq": true }` |
| `GET /eq` | `{ "eq": true }` |
| `POST /eq/on`, `POST /eq/off` | the new state |

The same switch from a terminal: `audio-eq on`, `audio-eq off`. It survives a
reboot, and leaves the swapped channels alone.

It also keeps your microphones awake, so recordings don't start with a second of
crackle, and asks which microphone should always be the default. Apps can still
use the other one if you pick it inside the app.

You can have every paired Bluetooth device reconnect automatically at boot.

Running it again starts from your previous answers.

It can also install an [MPD](https://www.musicpd.org/) music server that plays
through PipeWire, reachable from the local network with a generated password
(shown at the end, and kept when you run it again).

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

## Android tablet

> [!NOTE]
> The tablet needs USB debugging on, `adb` reachable over the network and a
> fixed IP in your router. The script starts by listing these steps. No root.

Turns an Android tablet into a network speaker. It installs
[Termux](https://termux.dev/) and Termux:Boot from F-Droid, then starts
[squeezelite](https://github.com/ralph-irving/squeezelite) at every boot, so the
tablet shows up as a player in Lyrion or Music Assistant. It also sets a few
things on the tablet so the player isn't put to sleep.

The tablet then becomes an audio output of your PC, listed with the others in
your sound settings whenever it is reachable. It is never picked by default.
You choose which addresses may play on it.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/android.sh)
```

To use a tablet that is already set up from another PC — it asks which addresses
to add to the tablet's allowed ones, then adds the output on that PC:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/android.sh) --add-pc
```

That PC reaches the tablet over SSH; if its key isn't known there yet, it needs
adb once, like a first install. With `--pc-only` instead, the tablet isn't
touched at all (the PC must already be allowed).

To rename a tablet, on the PC, as a player in your music server, or both, add
`--rename`: it lists the installed tablets and loops until you exit. Without a
terminal: `--rename <tablet IP or current name> <local|player|both> <new name>`.

Running it again starts from the tablet's current settings, and works over SSH
when adb is no longer connected.

## Notes

- Run them from a real terminal (the setup is interactive). The `bash <(curl …)`
  form above keeps the prompts working — a plain `curl … | bash` would not.
- Binaries are published automatically as a GitHub Release; the scripts pull the
  latest one. To pin a version, set `RELEASE_TAG=vX.Y.Z` before running.
