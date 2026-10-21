# reinstall

Personal setup scripts to get a freshly installed machine back to my preferred
display, audio and session configuration in one command each — plus one that
sets up an Android tablet as a network speaker and a Home Assistant screen.
Built for Arch-based systems (pacman / paru / yay) running PipeWire.

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
nicely with game streaming). It needs at least two screens: with a single one
the setup stops and leaves any previous install as it was.

If Sunshine is installed, it's also enabled so it starts with every session. On
AMD graphics cards it writes a small ddcutil config too: ddcutil 3.0 probes
monitors in parallel, which freezes the GPU right after login.

If one of your screens is an Android TV, the setup can also take care of it. It
asks first, tells you the TV has to be switched on and on your network, with
USB/network debugging turned on in its developer options, then asks for its IP
address. Two things are done there:

- the TV is lightened: animations and screensaver off, and on a known model the
  preinstalled apps nobody uses are disabled (reversible). Chromecast built-in
  is never one of them, and is switched back on if something disabled it: it is
  what keeps the TV reachable on the network in standby;
- Input Home is installed: a tiny app that makes the TV's Home button, its wake
  from standby and its boot open the HDMI input instead of the home screen (a
  long press on Home still opens that one). The setup finds the input your PC
  is plugged into by itself when it is the only one with a signal.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/screen.sh)
```

## Audio

> [!IMPORTANT]
> Install these yourself first (package names may vary by distribution):
> `pipewire`, `pipewire-pulse`, `wireplumber`, `ladspa`, `swh-plugins`, `ffmpeg`.

Sets up your audio outputs: you rank them, and the highest one connected is the
one that plays. Each device can get a voice-clarity equalizer, swapped
left/right channels, and a keepalive that stops it dozing off mid-silence: an
inaudible tone, whose pitch and volume you can tune by ear for each device (it
plays while you type, until it suits that speaker).

All of it is applied on the device itself: no extra output shows up in your
sound settings. A device whose model has a known correction EQ (an
[AutoEq](https://autoeq.app/) preset that flattens what the manufacturer got
wrong) also gets it automatically, before the voice equalizer. The known models
are in [`audio/setup/eqdb.json`](audio/setup/eqdb.json); add your own in
`~/.config/soundbar-setup/eqdb.json`, same format. An entry can also correct one
ear apart from the other (`left` / `right`: a preamp and filters added for that
channel), for a headset whose two sides don't play at the same level.

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
crackle, and has you rank them like the outputs: the highest one connected is
the default, and stays it: a default picked by hand is put back. Apps can still
use another one if you pick it inside the app.

A microphone whose model has a voice chain (EQ, compressor, de-esser, limiter)
gets it on the microphone itself: apps keep picking the same microphone and
record it processed. The known ones are in
[`audio/setup/mics/`](audio/setup/mics/), one filter graph per model, tuned by
ear for one voice; put your own in `~/.config/soundbar-setup/mics/`, same file
name, and yours is used instead.

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
> fixed IP in your router. The script starts by listing these steps, and pairs
> with Android's Wireless debugging itself: you only read it the code. No root.

Sets up an Android tablet that stays on its charger: a network speaker, and a
screen Home Assistant can switch between its dashboard and a stream of your PC.
You choose what it does: music player, network audio, Home Assistant, Moonlight.

Over adb, with nothing to tap on the tablet, it installs F-Droid, then
[Termux](https://termux.dev/), Termux:Boot and Termux:API as F-Droid apps, and
the light KISS launcher as home screen. As a music player, it starts
[squeezelite](https://github.com/ralph-irving/squeezelite) at every boot, so the
tablet shows up as a player in Lyrion or Music Assistant. It also sets a few
things on the tablet so the player isn't put to sleep, and turns off the
maker's sound processing where it knows it (Dolby on the Lenovo tablet), which
evens out every sound the tablet plays. If speakers are plugged
into the tablet and their model is in the list (Logitech Z120 for now), it can
put an equalizer made for them on everything the tablet plays.

The tablet then becomes an audio output of your PC, listed with the others in
your sound settings whenever it is reachable. It is never picked by default.
You choose which addresses may play on it. The setup ends by measuring, on its
own and in silence, the shortest delay the link between the PC and the tablet
holds without dropping out more than a long one does.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/android.sh)
```

Run like this it opens on a menu: on a tablet, install or reconfigure it, or
rename its music player; on this PC, use a tablet as an audio output, or rename
that output. When a tablet is done, it offers to set up another one.

For Home Assistant and Moonlight, install both apps on the tablet yourself and
sign in (Moonlight connected once to your PC): the setup does the rest. It
leaves a small server on the tablet for Home Assistant to talk to, port 7923:

| Request | Answer |
| --- | --- |
| `GET /capabilities` | the tablet's name, model, id and what it was set up to do |
| `GET /state` | `{ "display": "homeassistant", "screen_on": true, "battery": { "level": 48, … } }` |
| `POST /display/moonlight` | starts the stream of your PC's desktop |
| `POST /display/homeassistant` | back to the tablet's page of your dashboard |

`display` is `homeassistant`, `moonlight` (the stream is running) or `other`.
When a stream stops on its own — the PC restarted its streaming server, say —
the tablet goes back to Home Assistant by itself. You choose which addresses may
give it orders.

On another PC, for a tablet that is already set up — it allows that PC on the
tablet if needed, then adds the output there:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JiPaix/reinstall/main/android.sh) --this-pc
```

To rename without the menu: `--rename <tablet IP or current name>
<local|player|both> <new name>`.

Running it again starts from the tablet's current settings, and works over SSH
when adb is no longer connected.

## Notes

- Run them from a real terminal (the setup is interactive). The `bash <(curl …)`
  form above keeps the prompts working — a plain `curl … | bash` would not.
- Binaries are published automatically as a GitHub Release; the scripts pull the
  latest one. To pin a version, set `RELEASE_TAG=vX.Y.Z` before running.
