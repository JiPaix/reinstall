// Command soundbar-setup interactively picks what to do with each audio device
// (hide it, default mic, output priority, per-output equalizer / channel swap /
// keepalive) and renders the PipeWire/WirePlumber configs, the watcher service
// and the status script from the embedded templates straight to their final
// locations. A small vars.sh is staged for audio.sh to finish the install.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
)

// ACCESSIBLE=1 swaps the TUI for plain line prompts (screen readers, dumb
// terminals, scripted runs).
var accessible = os.Getenv("ACCESSIBLE") != ""

func main() {
	staging := flag.String("staging", "setup/generated", "dir for the staged vars.sh")
	dump := flag.Bool("dump", false, "print detected devices and exit (no prompts)")
	apply := flag.Bool("apply", false, "render the saved answers again and exit (no prompts)")
	flag.Parse()

	devs, err := DetectDevices()
	if err != nil {
		fatalf("%v\n(soundbar-setup needs pipewire-pulse running for pactl)", err)
	}
	if *dump {
		dumpDevices(devs)
		return
	}

	stagingAbs, err := filepath.Abs(*staging)
	if err != nil {
		fatalf("%v", err)
	}

	prev := LoadChoices()
	if *apply {
		applySaved(devs, prev, stagingAbs)
		return
	}
	devs = confirmDevices(devs, prev)
	var c Choices
	for {
		c = runWizard(devs, prev)
		if review(c) {
			break
		}
		prev = c // start over from what was just answered
	}

	written, err := Render(c, stagingAbs)
	if err != nil {
		fatalf("generating files: %v", err)
	}

	fmt.Println("\n✓ Generated:")
	for _, w := range written {
		fmt.Println("  -", w)
	}
}

// applySaved renders the answers of the last run again, without a question:
// after an edit of the correction EQ database, or an update of the templates.
// It only writes the files; audio.sh is what restarts the services.
func applySaved(devs Devices, c Choices, staging string) {
	if len(c.Outputs) == 0 {
		fatalf("no saved outputs in %s — run audio.sh first", choicesPath())
	}
	for i, o := range c.Outputs {
		for _, d := range devs.Sinks {
			if d.Name == o.Sink {
				c.Outputs[i].Model, c.Outputs[i].CardName = d.Model, d.CardName
			}
		}
	}
	written, err := Render(c, staging)
	if err != nil {
		fatalf("generating files: %v", err)
	}
	fmt.Println(summary(c))
	fmt.Println("✓ Generated:")
	for _, w := range written {
		fmt.Println("  -", w)
	}
}

// confirmDevices shows what was detected before any question depends on it,
// and looks again on request: a Bluetooth device that is off, or that dropped
// when PipeWire restarted, can be brought back without starting over.
func confirmDevices(devs Devices, prev Choices) Devices {
	const (
		cont = "continue"
		scan = "scan"
	)
	for {
		v := cont
		ask(huh.NewSelect[string]().
			Title("Detected devices").
			Description(detected(devs, prev)).
			Options(
				huh.NewOption("Continue with these", cont),
				huh.NewOption("Look again (after connecting or switching on a device)", scan),
			).Value(&v))
		if v == cont {
			return devs
		}
		again, err := DetectDevices()
		if err != nil {
			fatalf("%v", err)
		}
		devs = again
	}
}

// detected lists the outputs and mics found, plus the outputs only known from
// the previous run.
func detected(devs Devices, prev Choices) string {
	var b strings.Builder
	list := func(title string, items []string) {
		fmt.Fprintf(&b, "%s\n", title)
		if len(items) == 0 {
			b.WriteString("  none\n")
		}
		for _, s := range items {
			fmt.Fprintf(&b, "  • %s\n", s)
		}
	}
	sinks := deviceLabels(devs.Sinks)
	for i, d := range devs.Sinks {
		sinks[i] += correctionLabel(Output{Desc: d.Desc, Model: d.Model})
	}
	list("Outputs", sinks)
	list("Microphones", deviceLabels(devs.Sources))

	var absent []string
	for _, p := range prev.Outputs {
		if !hasDevice(devs.Sinks, p.Sink) {
			absent = append(absent, p.Desc)
		}
	}
	if len(absent) > 0 {
		list("Not connected, kept from the previous run", absent)
	}
	return b.String()
}

// wizard numbers the steps as they are asked: some are skipped (one output,
// no equalizer…), so the count isn't known up front.
type wizard struct{ step int }

func (w *wizard) title(s string) string {
	w.step++
	return fmt.Sprintf("Step %d · %s", w.step, s)
}

func runWizard(devs Devices, prev Choices) Choices {
	var c Choices
	w := &wizard{}

	// 1. Hide unwanted hardware.
	hidden := map[string]bool{}
	for _, hw := range pickHidden(w, devs, prev) {
		hidden[hw.Card] = true
		if hw.BT {
			c.DisabledBT = append(c.DisabledBT, hw.Card)
		} else {
			c.DisabledCards = append(c.DisabledCards, hw.Card)
		}
	}

	// 2. Default microphone, among the sources still there.
	var mics []Device
	for _, s := range devs.Sources {
		if !hidden[s.Card] {
			mics = append(mics, s)
		}
	}
	if mic, ok := pickDefaultSource(w, mics, prev); ok {
		c.DefaultSource = mic.Name
		c.DefaultDesc = mic.Desc
	}

	// 3. Outputs, by priority.
	var outputs []Device
	for _, s := range devs.Sinks {
		if !hidden[s.Card] {
			outputs = append(outputs, s)
		}
	}
	// Outputs set up last time but not connected right now stay on offer: a
	// Bluetooth speaker doesn't have to be on for a re-run to keep it.
	for _, p := range prev.Outputs {
		if !hasDevice(outputs, p.Sink) && !hasDevice(devs.Sinks, p.Sink) && !hidden[cardOf(p.Sink, "")] {
			outputs = append(outputs, Device{Name: p.Sink, Desc: p.Desc, Model: p.Model, CardName: p.CardName, Absent: true})
		}
	}
	if len(outputs) == 0 {
		fatalf("no output devices left after hiding")
	}
	for _, d := range rankOutputs(w, outputs, prev) {
		o := Output{Sink: d.Name, Desc: d.Desc, Model: d.Model, CardName: d.CardName}
		if p, ok := prev.output(d.Name); ok {
			o.EQ, o.Swap, o.Keepalive = p.EQ, p.Swap, p.Keepalive
		}
		c.Outputs = append(c.Outputs, o)
	}

	// 4. Extras, then the curve the equalizers share.
	pickExtras(w, c.Outputs)
	c.EQGains = prev.EQGains // kept for a later run even with no equalizer now
	for _, o := range c.Outputs {
		if o.EQ {
			c.EQGains = chooseEQ(w, prev.EQGains)
			break
		}
	}

	// 5. What the status server reports on.
	status := pickStatus(w, c.Outputs, prev)
	c.StatusSink, c.StatusDesc = status.Sink, status.Desc

	return c
}

// ── huh steps ────────────────────────────────────────────────────────────────

// ask runs the fields as one screen.
func ask(fields ...huh.Field) {
	askGroups(huh.NewGroup(fields...))
}

func askGroups(groups ...*huh.Group) {
	if err := huh.NewForm(groups...).WithAccessible(accessible).Run(); err != nil {
		fatalf("cancelled: %v", err)
	}
}

func pickHidden(w *wizard, devs Devices, prev Choices) []Hardware {
	if len(devs.Hardware) == 0 {
		return nil
	}
	was := map[string]bool{}
	for _, card := range append(append([]string{}, prev.DisabledCards...), prev.DisabledBT...) {
		was[card] = true
	}
	var sel []string
	opts := make([]huh.Option[string], len(devs.Hardware))
	for i, hw := range devs.Hardware {
		opts[i] = huh.NewOption(hardwareLabel(hw, devs), strconv.Itoa(i))
		if was[hw.Card] {
			sel = append(sel, strconv.Itoa(i))
		}
	}
	ask(huh.NewMultiSelect[string]().
		Title(w.title("Hide devices")).
		Description("Hidden devices never show up as an output or a microphone.\nspace toggles · enter confirms · nothing ticked = keep them all").
		Value(&sel).Options(opts...))

	out := make([]Hardware, 0, len(sel))
	for _, s := range sel {
		out = append(out, devs.Hardware[atoi(s)])
	}
	return out
}

// hardwareLabel tells what the device currently provides, e.g.
// "Razer BlackShark V2 Pro 2.4 — output + mic".
func hardwareLabel(hw Hardware, devs Devices) string {
	var has []string
	for _, s := range devs.Sinks {
		if s.Card == hw.Card {
			has = append(has, "output")
			break
		}
	}
	for _, s := range devs.Sources {
		if s.Card == hw.Card {
			has = append(has, "mic")
			break
		}
	}
	what := "currently off"
	if len(has) > 0 {
		what = strings.Join(has, " + ")
	}
	if hw.BT {
		what = "Bluetooth, " + what
	}
	return fmt.Sprintf("%s — %s", hw.Desc, what)
}

// deviceLabels returns one label per device: its description, plus the node
// name only where two devices share a description.
func deviceLabels(devs []Device) []string {
	seen := map[string]int{}
	for _, d := range devs {
		seen[d.Desc]++
	}
	labels := make([]string, len(devs))
	for i, d := range devs {
		labels[i] = d.Desc
		if seen[d.Desc] > 1 {
			labels[i] = fmt.Sprintf("%s — %s", d.Desc, d.Name)
		}
		if d.Absent {
			labels[i] += " (not connected)"
		}
	}
	return labels
}

func deviceOptions(devs []Device) []huh.Option[string] {
	opts := make([]huh.Option[string], len(devs))
	for i, label := range deviceLabels(devs) {
		opts[i] = huh.NewOption(label, strconv.Itoa(i))
	}
	return opts
}

// pickDefaultSource asks which mic becomes the default; apps that want another
// one have to select it themselves. ok is false when there is nothing to pick
// or the user leaves the choice to WirePlumber.
func pickDefaultSource(w *wizard, mics []Device, prev Choices) (Device, bool) {
	if len(mics) == 0 {
		return Device{}, false
	}
	const none = "none"
	v := "0"
	if len(prev.Outputs) > 0 && prev.DefaultSource == "" {
		v = none
	}
	for i, d := range mics {
		if d.Name == prev.DefaultSource {
			v = strconv.Itoa(i)
		}
	}
	opts := append(deviceOptions(mics), huh.NewOption("No preference (leave it to WirePlumber)", none))
	ask(huh.NewSelect[string]().
		Title(w.title("Default microphone")).
		Description("Apps use this one unless you pick another inside the app.").
		Options(opts...).Value(&v))
	if v == none {
		return Device{}, false
	}
	return mics[atoi(v)], true
}

// rankOutputs orders the outputs, preferred first: the first one connected is
// the one that plays.
func rankOutputs(w *wizard, outputs []Device, prev Choices) []Device {
	if len(outputs) == 1 {
		return outputs
	}

	// Same set of outputs as last time: offer to keep their order.
	var kept []Device
	for _, p := range prev.Outputs {
		for _, d := range outputs {
			if d.Name == p.Sink {
				kept = append(kept, d)
			}
		}
	}
	if len(kept) == len(outputs) {
		keep := true
		ask(huh.NewConfirm().
			Title(w.title("Output priority")).
			Description("Previous order, preferred first:\n" + numbered(deviceLabels(kept)) + "\nKeep it?").
			Affirmative("Keep").Negative("Change").Value(&keep))
		if keep {
			return kept
		}
		w.step-- // the ranking below is the same step
	}

	title := w.title("Output priority")
	remaining := append([]Device{}, outputs...)
	var order []Device
	for len(remaining) > 1 {
		v := "0"
		desc := "When several outputs are connected, the highest one plays."
		if len(order) > 0 {
			desc = "So far:\n" + numbered(deviceLabels(order))
		}
		ask(huh.NewSelect[string]().
			Title(fmt.Sprintf("%s — pick #%d", title, len(order)+1)).
			Description(desc).
			Options(deviceOptions(remaining)...).Value(&v))
		idx := atoi(v)
		order = append(order, remaining[idx])
		remaining = append(remaining[:idx], remaining[idx+1:]...)
	}
	return append(order, remaining...)
}

// pickOutputs asks which outputs get one extra: a tick per output.
func pickOutputs(w *wizard, outputs []Output, title, desc string, has func(Output) bool) map[string]bool {
	var sel []string
	devs := make([]Device, len(outputs))
	for i, o := range outputs {
		devs[i] = Device{Name: o.Sink, Desc: o.Desc}
		if has(o) {
			sel = append(sel, strconv.Itoa(i))
		}
	}
	ask(huh.NewMultiSelect[string]().
		Title(w.title(title)).
		Description(desc + "\nspace toggles · enter confirms · nothing ticked = none").
		Value(&sel).Options(deviceOptions(devs)...))

	picked := map[string]bool{}
	for _, s := range sel {
		picked[outputs[atoi(s)].Sink] = true
	}
	return picked
}

// pickExtras asks, extra by extra, which outputs get it.
func pickExtras(w *wizard, outputs []Output) {
	eq := pickOutputs(w, outputs, "Equalizer (voice clarity)",
		"Cuts the bass, lifts the voices: made for night listening.\n"+
			"Applied on the device itself: no extra output to pick.\n"+
			"It is switched on and off for every ticked device at once, at any\n"+
			"time (audio-eq on|off, or POST /eq/on and /eq/off).",
		func(o Output) bool { return o.EQ })
	swap := pickOutputs(w, outputs, "Swap left and right",
		"For a speaker that plays the channels the wrong way round.\n"+
			"Applied on the device itself, always on, whatever the equalizer does.",
		func(o Output) bool { return o.Swap })
	keepalive := pickOutputs(w, outputs, "Keepalive tone",
		"For a device that powers off after a few minutes of silence:\n"+
			"an inaudible tone plays on it for as long as it is connected.",
		func(o Output) bool { return o.Keepalive })

	for i, o := range outputs {
		outputs[i].EQ, outputs[i].Swap, outputs[i].Keepalive = eq[o.Sink], swap[o.Sink], keepalive[o.Sink]
	}
}

// chooseEQ returns the 15 gains shared by every equalizer.
func chooseEQ(w *wizard, prev []string) []string {
	const (
		keep   = "keep"
		preset = "preset"
		custom = "custom"
	)
	hasPrev := len(prev) == len(eqBandLabels)
	var opts []huh.Option[string]
	v := preset
	if hasPrev {
		opts = append(opts, huh.NewOption("Keep the current curve ("+strings.Join(prev, " ")+")", keep))
		v = keep
	}
	opts = append(opts,
		huh.NewOption("Preset: voice clarity, night listening, no bass vibration", preset),
		huh.NewOption("Custom: enter the 15 bands", custom))
	ask(huh.NewSelect[string]().
		Title(w.title("Equalizer curve")).
		Description("One curve, shared by every equalized output.").
		Options(opts...).Value(&v))

	switch v {
	case keep:
		return prev
	case preset:
		return append([]string{}, defaultEQ...)
	}

	gains := append([]string{}, defaultEQ...)
	if hasPrev {
		copy(gains, prev)
	}
	fields := make([]huh.Field, len(eqBandLabels))
	for i := range eqBandLabels {
		fields[i] = huh.NewInput().Title(eqBandLabels[i] + " (dB)").Value(&gains[i]).Validate(validateNumber)
	}
	ask(fields...)
	for i := range gains {
		gains[i] = strings.TrimSpace(gains[i])
	}
	return gains
}

// pickStatus asks which output the status server reports on.
func pickStatus(w *wizard, outputs []Output, prev Choices) Output {
	if len(outputs) == 1 {
		return outputs[0]
	}
	v := "0"
	devs := make([]Device, len(outputs))
	for i, o := range outputs {
		devs[i] = Device{Name: o.Sink, Desc: o.Desc}
		if o.Sink == prev.StatusSink {
			v = strconv.Itoa(i)
		}
	}
	ask(huh.NewSelect[string]().
		Title(w.title("Status server")).
		Description("soundbar-status-server answers \"is it playing?\" for one output.").
		Options(deviceOptions(devs)...).Value(&v))
	return outputs[atoi(v)]
}

// review shows what is about to be written; false means start over.
func review(c Choices) bool {
	ok := true
	ask(
		huh.NewNote().Title("Review").Description(summary(c)),
		huh.NewConfirm().Title("Write this configuration?").
			Affirmative("Write").Negative("Start over").Value(&ok),
	)
	return ok
}

func summary(c Choices) string {
	var b strings.Builder
	b.WriteString("Outputs, preferred first\n")
	for _, line := range outputLines(c) {
		fmt.Fprintf(&b, "  %s\n", line)
	}
	mic := "left to WirePlumber"
	if c.DefaultSource != "" {
		mic = c.DefaultDesc
	}
	fmt.Fprintf(&b, "\nDefault microphone: %s\n", mic)
	fmt.Fprintf(&b, "Status server reports on: %s\n", c.StatusDesc)
	if n := len(c.DisabledCards) + len(c.DisabledBT); n > 0 {
		fmt.Fprintf(&b, "Hidden devices: %d\n", n)
	}
	return b.String()
}

func numbered(items []string) string {
	var b strings.Builder
	for i, s := range items {
		fmt.Fprintf(&b, "  %d. %s\n", i+1, s)
	}
	return b.String()
}

func validateNumber(s string) error {
	if _, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err != nil {
		return fmt.Errorf("must be a number in dB")
	}
	return nil
}

// ── helpers ──────────────────────────────────────────────────────────────────

func dumpDevices(d Devices) {
	fmt.Println("Hardware:")
	for _, hw := range d.Hardware {
		fmt.Printf("  %-70s %s\n", hw.Card, hardwareLabel(hw, d))
	}
	row := func(dev Device) {
		fmt.Printf("  %-70s card=%s\n", dev.Name, dev.Card)
	}
	fmt.Println("Sinks (outputs):")
	for _, s := range d.Sinks {
		row(s)
	}
	fmt.Println("Sources (inputs):")
	for _, s := range d.Sources {
		row(s)
	}
}

func hasDevice(devs []Device, name string) bool {
	for _, d := range devs {
		if d.Name == name {
			return true
		}
	}
	return false
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "soundbar-setup: "+format+"\n", args...)
	os.Exit(1)
}
