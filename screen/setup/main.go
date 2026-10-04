// Command swapscreen-setup interactively builds the monitor/tv/taiko display
// profiles and generates swapscreen.sh from the embedded engine template.
//
// For each mode the user places detected monitors on a grid (a row at a time),
// picks each monitor's resolution/scale/color/VRR and a primary; positions are
// derived automatically from the grid (see grid.go). On KDE the user then says
// which of the placed screens are TVs. The answers are saved, and the next run
// offers each layout back. Output:
//
//	profiles.conf  — the three captured bash arrays + TV_CONNECTORS
//	swapscreen.sh  — engine template with that block injected
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"

	"github.com/charmbracelet/huh"
)

var colorOptions = []string{"default", "bt2100", "sdr-native"}

// ACCESSIBLE=1 swaps the TUI for plain line prompts (screen readers, dumb
// terminals, scripted runs).
var accessible = os.Getenv("ACCESSIBLE") != ""

func main() {
	profilesOut := flag.String("profiles", "setup/profiles.conf", "path to write the captured profile arrays")
	scriptOut := flag.String("out", "swapscreen.sh", "path to write the generated engine script")
	gdmOut := flag.String("gdm", "gdm-monitors.xml", "path to write the generated GDM greeter layout")
	deFlag := flag.String("de", "", "desktop backend: gnome (gdctl) | kde (kscreen-doctor) — default: autodetect")
	dump := flag.Bool("dump", false, "print detected connectors and exit (no prompts)")
	flag.Parse()

	backend := resolveBackend(*deFlag)
	conns := detect(backend)

	if *dump {
		dumpConnectors(conns)
		return
	}

	// Mode names differ between backends (kscreen rounds the refresh rate), so
	// answers saved under the other desktop can't be offered back.
	prev := LoadChoices()
	if prev.Backend != backend {
		prev = Choices{}
	}

	conns = confirmScreens(backend, conns)
	var c Choices
	for {
		c = runWizard(backend, conns, prev)
		if review(c) {
			break
		}
		prev = c // start over from what was just answered
	}

	if err := Generate(*profilesOut, *scriptOut, *gdmOut, conns, c); err != nil {
		fatalf("generating files: %v", err)
	}
	if err := saveChoices(c); err != nil {
		fmt.Fprintf(os.Stderr, "swapscreen-setup: answers not saved for the next run: %v\n", err)
	}
	if backend == "kde" {
		fmt.Printf("\n✓ Wrote %s and %s (KDE backend — no GDM greeter layout)\n", *profilesOut, *scriptOut)
	} else {
		fmt.Printf("\n✓ Wrote %s, %s, and %s\n", *profilesOut, *scriptOut, *gdmOut)
	}
}

// detect lists the connected screens, or exits: nothing can be set up without
// a session to ask.
func detect(backend string) []Connector {
	conns, err := DetectConnectors(backend)
	if err != nil {
		fatalf("%v\n(swapscreen-setup needs a running %s session — %s)", err, backend, backendTool(backend))
	}
	if len(conns) == 0 {
		fatalf("no monitors detected via %s", backendTool(backend))
	}
	return conns
}

// confirmScreens shows what was detected before any question depends on it,
// and looks again on request: a TV that is off (and not pinned) isn't listed,
// and can be switched on without starting over.
func confirmScreens(backend string, conns []Connector) []Connector {
	const (
		cont = "continue"
		scan = "scan"
	)
	for {
		var b strings.Builder
		for _, c := range conns {
			fmt.Fprintf(&b, "  • %s — %s\n", c.Label(), c.DefaultMode().Spec())
		}
		b.WriteString("\nA screen that is off may be missing: switch it on, then look again.")
		v := cont
		ask(huh.NewSelect[string]().
			Title("Detected screens").
			Description(b.String()).
			Options(
				huh.NewOption("Continue with these", cont),
				huh.NewOption("Look again (after switching on or plugging in a screen)", scan),
			).Value(&v))
		if v == cont {
			return conns
		}
		conns = detect(backend)
	}
}

// wizard numbers the steps as they are asked: some are skipped (no screen left
// for taiko, no TV question on GNOME), so the count isn't known up front.
type wizard struct{ step int }

func (w *wizard) title(s string) string {
	w.step++
	return fmt.Sprintf("Step %d · %s", w.step, s)
}

func runWizard(backend string, conns []Connector, prev Choices) Choices {
	w := &wizard{}
	c := Choices{Backend: backend}
	c.Monitor = buildProfile(w, "monitor", conns, prev.Monitor)
	c.TV = buildProfile(w, "tv", conns, prev.TV)
	c.TaikoExtra = buildTaikoExtra(w, conns, c.Monitor, prev.TaikoExtra)
	c.TVs = pickTVs(w, conns, c, prev)
	return c
}

// resolveBackend picks the display backend: an explicit -de flag wins, else
// $XDG_CURRENT_DESKTOP, else whichever of gdctl/kscreen-doctor is on PATH,
// defaulting to gnome.
func resolveBackend(flagVal string) string {
	switch strings.ToLower(flagVal) {
	case "gnome", "kde":
		return strings.ToLower(flagVal)
	}
	de := strings.ToLower(os.Getenv("XDG_CURRENT_DESKTOP"))
	switch {
	case strings.Contains(de, "kde"), strings.Contains(de, "plasma"):
		return "kde"
	case strings.Contains(de, "gnome"):
		return "gnome"
	}
	if _, err := exec.LookPath("gdctl"); err == nil {
		return "gnome"
	}
	if _, err := exec.LookPath("kscreen-doctor"); err == nil {
		return "kde"
	}
	return "gnome"
}

// backendTool names the detection binary for a backend (for error messages).
func backendTool(backend string) string {
	if backend == "kde" {
		return "kscreen-doctor"
	}
	return "gdctl"
}

// buildProfile drives the full grid flow for a standalone mode and assigns a
// primary. Guaranteed to place at least one monitor (conns is non-empty). A
// layout saved by the previous run is offered back when it still fits the
// detected screens.
func buildProfile(w *wizard, label string, conns []Connector, prev Profile) Profile {
	title := w.title(fmt.Sprintf("%q layout", label))
	if layoutUsable(prev.Rows, conns) {
		keep := true
		ask(huh.NewConfirm().
			Title(title + " — keep the previous one?").
			Description("★ primary\n" + describeRows(prev.Rows)).
			Affirmative("Keep").Negative("Change").Value(&keep))
		if keep {
			return prev
		}
	}
	note(title,
		"Place monitors on a grid. Columns go left→right (A, B, …) within a row; "+
			"new rows stack on top, auto-centered. Stop when you're done or all monitors are placed.")
	rows := buildRows(label, conns)
	setPrimary(label, rows)
	return Profile{Rows: rows}
}

// buildTaikoExtra optionally collects the extra row(s) stacked on top of the
// monitor grid. Returns nil if the user skips taiko (then taiko == monitor).
func buildTaikoExtra(w *wizard, conns []Connector, monitor Profile, prev [][]Cell) [][]Cell {
	avail := excludeUsed(conns, usedConnectors(monitor.Rows))
	if len(avail) == 0 {
		return nil
	}
	title := w.title(`"taiko" layout`)
	const what = "The monitor layout, plus extra display(s) stacked on top."
	if layoutUsable(prev, avail) {
		const (
			keep   = "keep"
			change = "change"
			none   = "none"
		)
		v := keep
		ask(huh.NewSelect[string]().
			Title(title).
			Description(what+"\nPrevious extra display(s):\n"+describeRows(prev)).
			Options(
				huh.NewOption("Keep it", keep),
				huh.NewOption("Change it", change),
				huh.NewOption("No taiko layout", none),
			).Value(&v))
		switch v {
		case keep:
			return prev
		case none:
			return nil
		}
	} else {
		configure := false
		ask(huh.NewConfirm().Title(title + " — configure one?").Description(what).Value(&configure))
		if !configure {
			return nil
		}
	}
	note("Configure the taiko extra row(s)",
		"These displays sit ON TOP of the monitor grid, centered over their column. "+
			"The monitor layout and its primary are reused as-is.")
	return buildRows("taiko (extra)", avail)
}

// pickTVs asks which of the placed screens are TVs (KDE only: the GNOME
// backend has no TV handling). The engine wakes a TV before switching to a
// layout that uses it and puts it to sleep after leaving one, and screen.sh
// pins its connector; a monitor needs none of that.
func pickTVs(w *wizard, conns []Connector, c Choices, prev Choices) []string {
	if c.Backend != "kde" {
		return nil
	}
	used := usedConnectors(c.Monitor.Rows)
	for _, rows := range [][][]Cell{c.TV.Rows, c.TaikoExtra} {
		for name := range usedConnectors(rows) {
			used[name] = true
		}
	}
	var placed []Connector
	for _, conn := range conns {
		if used[conn.Name] {
			placed = append(placed, conn)
		}
	}

	// First run: the primary of the "tv" layout is the obvious candidate.
	was := prev.TVs
	if prev.Backend == "" {
		was = nil
		for _, row := range c.TV.Rows {
			for _, cell := range row {
				if cell.Primary {
					was = []string{cell.Connector}
				}
			}
		}
	}

	var sel []string
	opts := make([]huh.Option[string], len(placed))
	for i, conn := range placed {
		opts[i] = huh.NewOption(conn.Label(), conn.Name)
		if slices.Contains(was, conn.Name) {
			sel = append(sel, conn.Name)
		}
	}
	ask(huh.NewMultiSelect[string]().
		Title(w.title("Which of these screens are TVs?")).
		Description("A TV drops off its connector when it is off or asleep. Each ticked screen\n" +
			"gets its EDID captured and its connector pinned as always connected, so a\n" +
			"switch works even with the TV off. Leave monitors unticked.\n" +
			"space toggles · enter confirms · nothing ticked = no TV").
		Value(&sel).Options(opts...))

	var tvs []string
	for _, conn := range placed { // detection order, whatever the ticking order
		if slices.Contains(sel, conn.Name) {
			tvs = append(tvs, conn.Name)
		}
	}
	return tvs
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

// configureCell prompts for resolution → refresh → scale → color → VRR (color
// only when the backend can't detect it — see autoColor).
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
	color := autoColor(c)
	if color == "" {
		color = selectOpts(c.Label()+": color mode", colorOptions, "default")
	}

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

// autoColor picks the color mode from the output's real capabilities when the
// backend reports them (KDE): HDR whenever available, SDR otherwise. Returns ""
// when unknown (gdctl), so the caller asks instead.
func autoColor(c Connector) string {
	if c.HDR == nil {
		return ""
	}
	if *c.HDR {
		return "bt2100"
	}
	return "default"
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
	ask(huh.NewSelect[string]().Title(title).Options(opts...).Value(&v))
	return v
}

func confirm(title string, def bool) bool {
	v := def
	ask(huh.NewConfirm().Title(title).Value(&v))
	return v
}

func note(title, desc string) {
	ask(huh.NewNote().Title(title).Description(desc).Next(true))
}

// ask runs the fields as one screen.
func ask(fields ...huh.Field) {
	if err := huh.NewForm(huh.NewGroup(fields...)).WithAccessible(accessible).Run(); err != nil {
		fatalf("cancelled: %v", err)
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
		if color := autoColor(c); color != "" {
			fmt.Printf("  color: %s\n", color)
		}
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "swapscreen-setup: "+format+"\n", args...)
	os.Exit(1)
}
