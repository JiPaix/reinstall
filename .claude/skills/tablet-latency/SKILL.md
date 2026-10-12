---
name: tablet-latency
description: Find the lowest tunnel latency an Android tablet set up by android.sh can hold without dropouts, and apply it. Use when the user wants to test, measure or lower the latency of the tablet audio output, or when that output crackles.
---

# Tablet output latency test

`android.sh` makes a tablet an audio output of this PC: a PipeWire client
(`tablet-sink@<slug>.service`, config `~/.config/tablet-sink/<slug>.conf`) holds a PulseAudio
tunnel to the tablet's AAudio sink `tablet` on TCP 4713. `pulse.latency` in that config (ms;
measured by `android.sh`'s STEP 9 since 2026-10-12, or imposed with `TUNNEL_LATENCY_MS`) is
the buffer the tunnel aims for. Too low and Wi-Fi
jitter empties it: dropouts. This procedure finds the floor.

What it measures: dropouts per setting, as the tablet reports them (stream underflows).
What it does not: the delay you hear, which adds Android's own output path and can only be
measured with a microphone next to the tablet.

## Before starting

- Tell the user test audio will play on the tablet, and ask them to listen for crackles:
  their ears are the second signal. The tablet must sit where it normally lives — Wi-Fi
  reception is the variable under test (a first test was once run with it moved elsewhere).
- Read the tablet's address and slug from `~/.config/tablet-sink/*.conf`.
- Check the tablet answers: `ssh -n -p 8022 <ip> 'timeout 5 pactl list short sinks'` must
  list `tablet … module-aaudio-sink.c`. If `pactl` hangs there, the daemon is deadlocked
  (see CLAUDE.md, "Tablet audio"); the boot script's watchdog replaces it within ~40 s.
- Note the network baseline: `ping -c 50 -i 0.2 -q <ip>` (max and mdev matter, not the average).

## Procedure

Work in the scratchpad. Never edit the installed config or stop the installed unit during
the sweep; run a second client beside it.

1. Make 30 s of quiet test audio — long enough to cross a few Wi-Fi hiccups:
   `ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=30" -af volume=0.15 -ar 48000 -ac 2 tone.wav`
2. For each latency in `100 60 40 30 20 10`:
   - copy the installed `.conf`, set `pulse.latency = <L>` and `node.name = "tablet_latency_test"`;
   - `timeout 45 pipewire -c "$PWD/test.conf" > client-<L>.log 2>&1 &`, wait until
     `pactl list short sinks` shows `tablet_latency_test`;
   - `timeout 40 paplay -d tablet_latency_test tone.wav`; halfway through, read the buffer
     the tablet really holds:
     `ssh -n -p 8022 <ip> 'timeout 5 pactl list sink-inputs | grep "Buffer Latency"'`;
   - kill the client, then count `underflow` lines in `client-<L>.log` (`mod.pulse-tunnel`
     logs one per burst, with an "N suppressed" count — add those). One at the very start
     of the stream is normal. The installed unit's journal also showed five over six
     minutes on 2026-10-04 with no test running (whether anything was playing then was
     not established), so only count those between the start and the end of the tone —
     note the times of `paplay` and compare.
3. Put every command behind `timeout`: `paplay -d` on a sink that doesn't exist plays on
   this PC's default output instead, and a `pactl` against a hung daemon blocks for 30 s.
4. Ask the user which settings crackled.

## Reading the result

The floor is the lowest setting with no underflow after the first second **and** nothing
heard. Recommend one step above it (a 30 s run sees less jitter than an evening of music).
Report a table: setting, buffer measured on the tablet, underflows, what the user heard.

To apply: edit `pulse.latency` in `~/.config/tablet-sink/<slug>.conf` and
`systemctl --user restart tablet-sink@<slug>`. Each PC has its own value, and a later run of
`android.sh` keeps it.

`android.sh` ends on an automatic version of this (STEP 9): a probe client beside the
installed one, 60 s of silence per value, the longest step as reference, then the shortest
step that underflows no more than it. This procedure is the thorough one: longer runs,
a tone to listen to, the buffer read on the tablet.

Measured on 2026-10-12 (Lenovo TB128FU, PC on Ethernet, tablet on 5 GHz Wi-Fi), worth
knowing before a new sweep:

- Silence and a tone underflow alike, so a sweep can be silent. An idle tunnel is corked
  on the tablet and logs nothing: something has to play.
- Reading "Buffer Latency" over SSH **during** a run causes an underflow by itself (the
  `pactl` call stalls the tablet's daemon): read it in a separate run.
- The buffer the tablet really holds barely follows the setting: 13-17 ms at 5-20, 18 at
  40, 27 at 60, 36 at 100.
- 5 and 10 ms: a burst every ~4 s. From 20 up the counts are low but swing with the
  minute: 20 ms gave 0, 0, 5 (per 30 s) and 2, 4 (per 60 s); 40 ms 1, 0, 3, 1; 100 ms 2 per
  60 s; 200 ms 0. Some underflows therefore remain at every usual value; their cause was
  not established (the PC's graph clock against the tablet's is the untested suspect).
  STEP 9 settled on 40 for this PC, then on 20 at the next run two hours later: 20 is what
  the config holds.

squeezelite is not affected by this setting: it plays into the same `tablet` sink locally,
and the server compensates each player's delay when syncing a group.
