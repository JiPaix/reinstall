// Command soundbar-setup interactively selects audio devices (primary/disable/
// priority/EQ) and renders the PipeWire/WirePlumber configs, services, scripts,
// and udev rule from the embedded templates straight to their final locations.
// The udev rule and a small vars.sh are staged for audio.sh to finish (sudo).
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

func main() {
	staging := flag.String("staging", "setup/generated", "dir for the staged udev rule + vars.sh")
	dump := flag.Bool("dump", false, "print detected devices and exit (no prompts)")
	flag.Parse()

	devs, err := DetectDevices()
	if err != nil {
		fatalf("%v\n(soundbar-setup needs pipewire-pulse running for pactl)", err)
	}
	if len(devs.Sinks) == 0 {
		fatalf("no output devices detected via pactl")
	}

	if *dump {
		dumpDevices(devs)
		return
	}

	stagingAbs, err := filepath.Abs(*staging)
	if err != nil {
		fatalf("%v", err)
	}

	c := runWizard(devs)
	written, err := Render(c, stagingAbs)
	if err != nil {
		fatalf("generating files: %v", err)
	}

	fmt.Println("\n✓ Generated:")
	for _, w := range written {
		fmt.Println("  -", w)
	}
}

func runWizard(devs Devices) Choices {
	var c Choices

	// 1. Disable unwanted devices.
	all := append(append([]Device{}, devs.Sinks...), devs.Sources...)
	disabledSet := map[string]bool{}
	for _, d := range multiSelectDevices("Disable any unwanted devices (space toggles, enter confirms — or skip):", all) {
		disabledSet[d.Name] = true
		switch {
		case d.IsBT():
			c.DisabledBT = append(c.DisabledBT, d.Name)
		case d.IsALSA() && d.Card != "":
			c.DisabledCards = appendUnique(c.DisabledCards, d.Card)
		}
	}

	// 2. Primary device, among the remaining sinks.
	var remaining []Device
	for _, s := range devs.Sinks {
		if !disabledSet[s.Name] {
			remaining = append(remaining, s)
		}
	}
	if len(remaining) == 0 {
		fatalf("no output devices left after disabling")
	}
	primary := pickDevice("Which device gets L/R swap + EQ + keepalive (primary)?", remaining)
	c.PrimarySink = primary.Name
	c.PrimaryDesc = primary.Desc

	// 3. BT udev input name (only for a Bluetooth primary).
	if primary.IsBT() {
		c.IsBT = true
		c.BTInputName = resolveBTInput(primary.Desc)
	}

	// 4. Fallback priority order for the other sinks.
	var others []Device
	for _, s := range remaining {
		if s.Name != primary.Name {
			others = append(others, s)
		}
	}
	c.Priorities = rankDevices(others)

	// 5. EQ curve.
	c.EQGains = chooseEQ()

	return c
}

// ── huh steps ────────────────────────────────────────────────────────────────

func multiSelectDevices(title string, devs []Device) []Device {
	if len(devs) == 0 {
		return nil
	}
	var sel []string
	opts := make([]huh.Option[string], len(devs))
	for i, d := range devs {
		opts[i] = huh.NewOption(d.Label(), strconv.Itoa(i))
	}
	if err := huh.NewMultiSelect[string]().Title(title).Options(opts...).Value(&sel).Run(); err != nil {
		fatalf("selection cancelled: %v", err)
	}
	out := make([]Device, 0, len(sel))
	for _, s := range sel {
		out = append(out, devs[atoi(s)])
	}
	return out
}

func pickDevice(title string, devs []Device) Device {
	opts := make([]huh.Option[string], len(devs))
	for i, d := range devs {
		opts[i] = huh.NewOption(d.Label(), strconv.Itoa(i))
	}
	v := "0"
	if err := huh.NewSelect[string]().Title(title).Options(opts...).Value(&v).Run(); err != nil {
		fatalf("selection cancelled: %v", err)
	}
	return devs[atoi(v)]
}

// rankDevices ranks fallbacks by repeatedly asking for the next-highest one.
func rankDevices(devs []Device) []string {
	remaining := append([]Device{}, devs...)
	var order []string
	for rank := 1; len(remaining) > 0; rank++ {
		if len(remaining) == 1 {
			order = append(order, remaining[0].Name)
			break
		}
		opts := make([]huh.Option[string], len(remaining))
		for i, d := range remaining {
			opts[i] = huh.NewOption(d.Label(), strconv.Itoa(i))
		}
		v := "0"
		if err := huh.NewSelect[string]().
			Title(fmt.Sprintf("Fallback priority #%d — pick the next device:", rank)).
			Options(opts...).Value(&v).Run(); err != nil {
			fatalf("selection cancelled: %v", err)
		}
		idx := atoi(v)
		order = append(order, remaining[idx].Name)
		remaining = append(remaining[:idx], remaining[idx+1:]...)
	}
	return order
}

func resolveBTInput(desc string) string {
	names := inputDeviceNames()
	if m := matchBTInputName(desc, names); m != "" {
		fmt.Printf("→ Auto-matched Bluetooth input name: %q\n", m)
		return m
	}
	if len(names) == 0 {
		return promptManualInput()
	}
	const manual = "\x00manual"
	opts := make([]huh.Option[string], 0, len(names)+1)
	for _, n := range names {
		opts = append(opts, huh.NewOption(n, n))
	}
	opts = append(opts, huh.NewOption("Enter manually…", manual))
	v := opts[0].Value
	if err := huh.NewSelect[string]().
		Title("Could not auto-match the BT device — pick its udev input name:").
		Options(opts...).Value(&v).Run(); err != nil {
		fatalf("selection cancelled: %v", err)
	}
	if v == manual {
		return promptManualInput()
	}
	return v
}

func promptManualInput() string {
	var v string
	if err := huh.NewInput().
		Title("Enter the udev input name (e.g. 'HIGHONE BDS C10 (AVRCP)'):").
		Value(&v).Run(); err != nil {
		fatalf("input cancelled: %v", err)
	}
	return strings.TrimSpace(v)
}

func chooseEQ() []string {
	if confirm("Use the default EQ curve (voice clarity, night listening, no bass vibration)?", true) {
		return append([]string{}, defaultEQ...)
	}
	gains := append([]string{}, defaultEQ...)
	fields := make([]huh.Field, len(eqBandLabels))
	for i := range eqBandLabels {
		fields[i] = huh.NewInput().Title(eqBandLabels[i] + " (dB)").Value(&gains[i]).Validate(validateNumber)
	}
	if err := huh.NewForm(huh.NewGroup(fields...)).Run(); err != nil {
		fatalf("EQ form cancelled: %v", err)
	}
	return gains
}

func validateNumber(s string) error {
	if _, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err != nil {
		return fmt.Errorf("must be a number in dB")
	}
	return nil
}

func confirm(title string, def bool) bool {
	v := def
	if err := huh.NewConfirm().Title(title).Value(&v).Run(); err != nil {
		fatalf("prompt cancelled: %v", err)
	}
	return v
}

// ── helpers ──────────────────────────────────────────────────────────────────

func dumpDevices(d Devices) {
	row := func(dev Device) {
		fmt.Printf("  %-55s alsa=%-5v bt=%-5v card=%s\n", dev.Name, dev.IsALSA(), dev.IsBT(), dev.Card)
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

func appendUnique(s []string, v string) []string {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "soundbar-setup: "+format+"\n", args...)
	os.Exit(1)
}
