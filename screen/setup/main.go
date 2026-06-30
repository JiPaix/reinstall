// Command swapscreen-setup interactively builds the monitor/tv/taiko display
// profiles and generates swapscreen.sh from the embedded engine template.
//
// For each mode the user places detected monitors on a grid (a row at a time),
// picks each monitor's resolution/scale/color/VRR and a primary; positions are
// derived automatically from the grid (see grid.go). Output:
//
//	profiles.conf  — the three captured bash arrays
//	swapscreen.sh  — engine template with the arrays injected
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
)

var colorOptions = []string{"default", "bt2100", "sdr-native"}

func main() {
	profilesOut := flag.String("profiles", "setup/profiles.conf", "path to write the captured profile arrays")
	scriptOut := flag.String("out", "swapscreen.sh", "path to write the generated engine script")
	dump := flag.Bool("dump", false, "print detected connectors and exit (no prompts)")
	flag.Parse()

	conns, err := DetectConnectors()
	if err != nil {
		fatalf("%v\n(swapscreen-setup needs a running GNOME session — gdctl)", err)
	}
	if len(conns) == 0 {
		fatalf("no monitors detected via 'gdctl show -m'")
	}

	if *dump {
		dumpConnectors(conns)
		return
	}

	fmt.Printf("\nDetected %d connector(s): ", len(conns))
	names := make([]string, len(conns))
	for i, c := range conns {
		names[i] = c.Name
	}
	fmt.Println(strings.Join(names, ", "))

	monitor := buildProfile("monitor", conns)
	tv := buildProfile("tv", conns)
	taikoExtra := buildTaikoExtra(conns, monitor)

	if err := Generate(*profilesOut, *scriptOut, monitor, tv, taikoExtra); err != nil {
		fatalf("generating files: %v", err)
	}
	fmt.Printf("\n✓ Wrote %s and %s\n", *profilesOut, *scriptOut)
}

// buildProfile drives the full grid flow for a standalone mode and assigns a
// primary. Guaranteed to place at least one monitor (conns is non-empty).
func buildProfile(label string, conns []Connector) Profile {
	note(fmt.Sprintf("Configure the %q layout", label),
		"Place monitors on a grid. Columns go left→right (A, B, …) within a row; "+
			"new rows stack on top, auto-centered. Stop when you're done or all monitors are placed.")
	rows := buildRows(label, conns)
	setPrimary(label, rows)
	return Profile{Rows: rows}
}

// buildTaikoExtra optionally collects the extra row(s) stacked on top of the
// monitor grid. Returns nil if the user skips taiko (then taiko == monitor).
func buildTaikoExtra(conns []Connector, monitor Profile) [][]Cell {
	avail := excludeUsed(conns, usedConnectors(monitor.Rows))
	if len(avail) == 0 {
		return nil
	}
	if !confirm("Configure a 'taiko' layout (monitor grid + extra display stacked on top)?", false) {
		return nil
	}
	note("Configure the taiko extra row(s)",
		"These displays sit ON TOP of the monitor grid, centered over their column. "+
			"The monitor layout and its primary are reused as-is.")
	return buildRows("taiko (extra)", avail)
}

const (
	actSameRow = "Add another monitor to this row"
	actNewRow  = "Start a new row (stacked on top)"
	actDone    = "Finish this mode"
)

// buildRows runs the place loop over the available connectors. It always places
// at least one cell before offering to stop, and auto-finishes once every
// available connector is used.
func buildRows(label string, available []Connector) [][]Cell {
	var rows [][]Cell
	var cur []Cell
	used := map[string]bool{}

	remaining := func() []Connector { return excludeUsed(available, used) }

	for {
		rem := remaining()
		if len(rem) == 0 {
			break
		}
		col := columnLetter(len(cur))
		conn := pickConnector(fmt.Sprintf("%s — row %d, column %s: pick a monitor", label, len(rows), col), rem)
		cur = append(cur, configureCell(conn))
		used[conn.Name] = true

		if len(remaining()) == 0 {
			break // all placed → auto-finish
		}
		switch selectOpts("Next?", []string{actSameRow, actNewRow, actDone}, actSameRow) {
		case actNewRow:
			rows = append(rows, cur)
			cur = nil
		case actDone:
			rows = append(rows, cur)
			return rows
		}
	}
	if len(cur) > 0 {
		rows = append(rows, cur)
	}
	return rows
}

// configureCell prompts for resolution → refresh → scale → color → VRR.
func configureCell(c Connector) Cell {
	def := c.DefaultMode()

	res := selectOpts(c.Label()+": resolution", c.Resolutions(), def.Resolution())
	modes := c.ModesFor(res)

	labels := make([]string, len(modes))
	values := make([]string, len(modes))
	for i, m := range modes {
		labels[i] = m.Refresh + " Hz" + modeTags(m)
		values[i] = strconv.Itoa(i)
	}
	mode := modes[atoi(selectKV(res+": refresh rate", labels, values, "0"))]

	scale := chooseScale(c.Label(), mode)
	color := selectOpts(c.Label()+": color mode", colorOptions, "default")

	vrr := false
	if mode.HasVRR {
		vrr = confirm(c.Label()+": enable VRR (variable refresh)?", mode.CurrentIsVRR)
	}

	return Cell{
		Connector: c.Name,
		W:         mode.W,
		H:         mode.H,
		ModeSpec:  mode.Spec(),
		Scale:     scale,
		Color:     color,
		VRR:       vrr,
	}
}

func chooseScale(label string, m Mode) float64 {
	scales := m.Scales
	if len(scales) == 0 {
		scales = []float64{1.0}
	}
	def := formatScale(1.0)
	labels := make([]string, len(scales))
	values := make([]string, len(scales))
	for i, s := range scales {
		values[i] = formatScale(s)
		labels[i] = values[i]
		if s == m.PreferredScale {
			labels[i] += " (preferred)"
		}
		if s == 1.0 {
			def = values[i]
		}
	}
	v, _ := strconv.ParseFloat(selectKV(label+": scale", labels, values, def), 64)
	return v
}

// setPrimary marks exactly one placed cell as primary.
func setPrimary(label string, rows [][]Cell) {
	names := usedConnectorList(rows)
	if len(names) == 0 {
		return
	}
	target := names[0]
	if len(names) > 1 {
		target = selectOpts(fmt.Sprintf("%s: which monitor is primary?", label), names, names[0])
	}
	for ri := range rows {
		for ci := range rows[ri] {
			if rows[ri][ci].Connector == target {
				rows[ri][ci].Primary = true
				return
			}
		}
	}
}

// ── connector-set helpers ────────────────────────────────────────────────────

func usedConnectors(rows [][]Cell) map[string]bool {
	m := map[string]bool{}
	for _, row := range rows {
		for _, c := range row {
			m[c.Connector] = true
		}
	}
	return m
}

func usedConnectorList(rows [][]Cell) []string {
	var out []string
	for _, row := range rows {
		for _, c := range row {
			out = append(out, c.Connector)
		}
	}
	return out
}

func excludeUsed(conns []Connector, used map[string]bool) []Connector {
	var out []Connector
	for _, c := range conns {
		if !used[c.Name] {
			out = append(out, c)
		}
	}
	return out
}

func columnLetter(i int) string { return string(rune('A' + i)) }

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

// ── huh wrappers ─────────────────────────────────────────────────────────────

func pickConnector(title string, conns []Connector) Connector {
	labels := make([]string, len(conns))
	values := make([]string, len(conns))
	for i, c := range conns {
		labels[i] = c.Label()
		values[i] = strconv.Itoa(i)
	}
	return conns[atoi(selectKV(title, labels, values, "0"))]
}

func selectOpts(title string, opts []string, def string) string {
	return selectKV(title, opts, opts, def)
}

func selectKV(title string, labels, values []string, def string) string {
	v := def
	opts := make([]huh.Option[string], len(values))
	for i := range values {
		opts[i] = huh.NewOption(labels[i], values[i])
	}
	if err := huh.NewSelect[string]().Title(title).Options(opts...).Value(&v).Run(); err != nil {
		fatalf("selection cancelled: %v", err)
	}
	return v
}

func confirm(title string, def bool) bool {
	v := def
	if err := huh.NewConfirm().Title(title).Value(&v).Run(); err != nil {
		fatalf("prompt cancelled: %v", err)
	}
	return v
}

func note(title, desc string) {
	if err := huh.NewNote().Title(title).Description(desc).Next(true).Run(); err != nil {
		fatalf("prompt cancelled: %v", err)
	}
}

func modeTags(m Mode) string {
	var tags []string
	if m.Current {
		tags = append(tags, "current")
	}
	if m.Preferred {
		tags = append(tags, "preferred")
	}
	if m.HasVRR {
		tags = append(tags, "VRR")
	}
	if len(tags) == 0 {
		return ""
	}
	return " [" + strings.Join(tags, ", ") + "]"
}

func dumpConnectors(conns []Connector) {
	for _, c := range conns {
		fmt.Printf("%s\n", c.Label())
		for _, r := range c.Resolutions() {
			var refs []string
			for _, m := range c.ModesFor(r) {
				refs = append(refs, m.Refresh+modeTags(m))
			}
			fmt.Printf("  %-12s %s\n", r, strings.Join(refs, "  "))
		}
		if len(c.Modes) > 0 {
			fmt.Printf("  scales: %v\n", c.Modes[0].Scales)
		}
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "swapscreen-setup: "+format+"\n", args...)
	os.Exit(1)
}
