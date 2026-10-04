---
name: tablet-audio-health
description: Check whether an Android tablet set up by android.sh has had its PulseAudio daemon hang since the fix (idle-suspend disabled + watchdog), and report whether the fix holds over time. Use when the user asks to check the tablet's audio health, the hang fix, the watchdog, or says the tablet stopped playing.
---

# Has the tablet's audio daemon hung again?

## What this is about

On the tablet, squeezelite and the PCs' tunnels all play into PulseAudio's AAudio sink
(`tablet`). On 2026-10-04 that sink deadlocked the whole daemon twice within minutes, both
times while *suspending* after 5 s of silence (its debug log ended on "Sink aaudio idle for
too long, suspending ..."). Symptoms: `pactl` hangs on the tablet, the player goes silent,
a PC's tunnel logs "connection failure: Timeout".

Two things were put in place by `android.sh`:

1. `$PREFIX/etc/pulse/default.pa.d/50-reinstall.pa` unloads `module-suspend-on-idle`, so
   the sink never suspends — this is the actual fix;
2. the boot script `~/.termux/boot/start-squeezelite` has a watchdog: every 30 s, if
   `pactl info` doesn't answer within 10 s, it kills and restarts PulseAudio and squeezelite,
   and appends a line to `~/audio-watchdog.log`.

The fix was only observed for a couple of hours. The question to answer: **over days of
normal use, did the daemon hang again?** No hang = fix confirmed. Hangs caught by the
watchdog = the fix is incomplete but the tablet recovers. A hang nobody caught = worst case.

## How to check

The tablet's address is in `~/.config/tablet-sink/*.conf` (`pulse.server.address`); Termux
answers on SSH port 8022 (`ssh -n -p 8022 <ip> '…'`). Everything below is read-only. Put
`timeout` in front of every `pactl`: against a hung daemon it blocks.

1. **Is it answering now?** `timeout 10 pactl info >/dev/null && echo alive`. Then
   `timeout 5 pactl list short sinks` must show `tablet … module-aaudio-sink.c` in state
   `IDLE` or `RUNNING`, never `SUSPENDED`.
2. **Is the fix still in place?** `timeout 5 pactl list short modules | grep -c suspend-on-idle`
   must print `0`, and `cat $PREFIX/etc/pulse/default.pa.d/50-reinstall.pa` must contain
   `unload-module module-suspend-on-idle`.
3. **Did the watchdog fire?** `cat ~/audio-watchdog.log` — one dated line per replacement;
   no file = it never fired. Check the watchdog can log at all:
   `grep -c audio-watchdog.log ~/.termux/boot/start-squeezelite` must be ≥ 1. (That line was
   added to the file on 2026-10-04 while the script was already running: a script instance
   started before then doesn't log, see step 4.)
4. **Cross-check with process ages**, which works even without the log:

       uptime
       ps -o etime=,args= -p "$(pgrep -x pulseaudio)"
       pgrep -af 'boot/[s]tart-squeezelite'      # then ps -o etime= -p <pid> on the oldest

   Run that `pgrep` as an ssh command of its own: on a command line that also contains the
   script's path, it lists the ssh shell itself.

   PulseAudio is started by the boot script, so normally it is as old as the script (give or
   take a second). **PulseAudio clearly younger than the boot script = something restarted
   it**: the watchdog, or a run of `android.sh` (a full run restarts both, so they stay the
   same age; `--rename` restarts only the script, making the script *younger* — harmless).
5. Ask the user whether the tablet went silent or a PC lost the "tablet" output at any point,
   and for how long the tablet has been in normal use since the last restart.

## Reading the result

| Observation | Meaning |
| --- | --- |
| alive, no log, PulseAudio as old as the script, several days of use | fix holds — say so, with the uptime it is based on |
| log lines / PulseAudio younger than the script | the daemon hung and was replaced: fix incomplete. Report dates and frequency |
| `pactl` hangs right now | a hang in progress; the watchdog should clear it within ~40 s. If it doesn't, the watchdog isn't running (step 4 shows no script) |
| `suspend-on-idle` loaded, or sink `SUSPENDED` | the config was lost or overwritten — re-run `android.sh` |

Less than about two days of real use (music played and stopped many times — each stop used
to be a suspend) is not enough to call it confirmed: say what was seen and for how long.

## If it still hangs

Don't experiment on the live daemon while someone is listening. The fallback is the stock
OpenSL ES sink, which ran for hours before the change without a hang but buffers ~145 ms
instead of ~20: in `android.sh`, squeezelite's `-o tablet` and the tunnel's
`target.object = "tablet"` would point to `OpenSL_ES_sink`, and the `module-aaudio-sink`
line would go. That is a code change to discuss with the user, not something to apply here.
To capture evidence of a new hang first, restart PulseAudio with
`--log-target=file:$HOME/pa-debug.log --log-level=debug` and read the last lines after it
hangs (delete the log afterwards — it grows).

## Baseline (2026-10-04)

Tablet rebooted at 21:44 with the fix in place and the logging watchdog running: player,
PulseAudio (AAudio sink, TCP 4713, no suspend-on-idle) and sshd all came back by
themselves within about a minute. No hang and no watchdog log at that point. Any
`~/audio-watchdog.log`, or a PulseAudio younger than the boot script, dates from after that.
