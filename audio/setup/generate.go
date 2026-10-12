package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"
)

//go:embed templates/*.tmpl
var templatesFS embed.FS

// eqBandLabels are the 15 mbeq control names (must match the LADSPA plugin).
var eqBandLabels = []string{
	"50Hz gain (low shelving)",
	"100Hz gain", "156Hz gain", "220Hz gain", "311Hz gain",
	"440Hz gain", "622Hz gain", "880Hz gain", "1250Hz gain", "1750Hz gain",
	"2500Hz gain", "3500Hz gain", "5000Hz gain", "10000Hz gain", "20000Hz gain",
}

// defaultEQ is the night-listening / voice-clarity curve from the original script.
var defaultEQ = []string{"-15", "-12", "-10", "-8", "-6", "-3", "0", "3", "5", "6", "5", "4", "2", "0", "-3"}

// fxPrefix named the processed outputs of earlier versions (a second output in
// front of the device); detection skips the ones still loaded.
const fxPrefix = "audio_fx."

// Output is one ranked output and the extras it asked for.
type Output struct {
	Sink      string `json:"sink"`
	Desc      string `json:"desc"`
	EQ        bool   `json:"eq"` // equalizable: follows `audio-eq on|off`
	Swap      bool   `json:"swap"`
	Keepalive bool   `json:"keepalive"`
	// The keepalive tone, tuned by ear in the wizard; zero means the default.
	ToneHz  int     `json:"tone_hz,omitempty"`
	ToneVol float64 `json:"tone_vol,omitempty"` // percent, see toneVolume
	// Model and CardName are kept so an output that is off during a re-run
	// still gets its correction EQ (see eqdb.go).
	Model    string `json:"model,omitempty"`
	CardName string `json:"card_name,omitempty"`
}

// Mic is one ranked microphone.
type Mic struct {
	Source string `json:"source"`
	Desc   string `json:"desc"`
}

// Effects names what was asked for the output, for the summaries.
func (o Output) Effects() string {
	var x []string
	if o.EQ {
		x = append(x, "EQ")
	}
	if o.Swap {
		x = append(x, "L/R swapped")
	}
	return strings.Join(x, " + ")
}

// Choices is the user's interactive selection — the input to rendering. It is
// also saved as JSON, so the next run starts from the same answers.
type Choices struct {
	Outputs       []Output `json:"outputs"`     // highest priority first
	EQGains       []string `json:"eq_gains"`    // 15 dB values, one curve for every equalizer
	StatusSink    string   `json:"status_sink"` // what soundbar-status reports on
	StatusDesc    string   `json:"status_desc"`
	DisabledBT    []string `json:"disabled_bt"`    // bluez_card.* names
	DisabledCards []string `json:"disabled_cards"` // alsa_card.* names
	Mics          []Mic    `json:"mics"`           // highest priority first
	// Earlier versions pinned a single default mic; LoadChoices turns it into
	// the first ranked one.
	DefaultSource string `json:"default_source,omitempty"`
	DefaultDesc   string `json:"default_desc,omitempty"`
}

func (c Choices) output(sink string) (Output, bool) {
	for _, o := range c.Outputs {
		if o.Sink == sink {
			return o, true
		}
	}
	return Output{}, false
}

// outputPrio spreads the ranked outputs above every stock priority.session
// (ALSA and BlueZ sinks sit around 1000), however many there are.
const (
	outputPrioBase = 2000
	outputPrioStep = 100
)

func outputPrio(rank, count int) int {
	return outputPrioBase + (count-1-rank)*outputPrioStep
}

// micPrio spreads the ranked mics above every source's stock priority.session
// (ALSA gives USB mics ~2100): the highest one connected is the default
// whenever no default is configured.
const (
	micPrioBase = 3000
	micPrioStep = 100
)

func micPrio(rank, count int) int {
	return micPrioBase + (count-1-rank)*micPrioStep
}

// EQBand, PriorityRule and Tone feed the templates.
type EQBand struct{ Label, Gain string }
type PriorityRule struct {
	Name string
	Prio int
}
type Tone struct {
	Sink   string
	Hz     int
	Volume string // ffmpeg volume factor
}

type tmplData struct {
	ScriptsDir     string
	MonitorSource  string
	Keepalives     []Tone
	EQSinks        []string // the equalized outputs, for audio-eq
	EQParamsOn     string   // Props for pw-cli: the equalizer graph / none
	EQParamsOff    string
	RankedSinks    []string
	RankedSources  []string
	BTPriorities   []PriorityRule
	ALSAPriorities []PriorityRule
	DisabledBT     []string
	DisabledCards  []string
}

// destinations under $HOME.
func homePaths() (wpDir, pwDir, systemdDir, binDir string) {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/wireplumber/wireplumber.conf.d"),
		filepath.Join(h, ".config/pipewire/pipewire.conf.d"),
		filepath.Join(h, ".config/systemd/user"),
		filepath.Join(h, ".local/bin")
}

// choicesPath is where the answers are kept between runs.
func choicesPath() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/soundbar-setup/choices.json")
}

// LoadChoices returns the previous run's answers, or a zero Choices when there
// are none (or they can't be read: they only pre-fill the prompts).
func LoadChoices() Choices {
	var c Choices
	b, err := os.ReadFile(choicesPath())
	if err != nil {
		return Choices{}
	}
	if json.Unmarshal(b, &c) != nil {
		return Choices{}
	}
	if len(c.Mics) == 0 && c.DefaultSource != "" {
		c.Mics = []Mic{{Source: c.DefaultSource, Desc: c.DefaultDesc}}
	}
	c.DefaultSource, c.DefaultDesc = "", ""
	return c
}

func saveChoices(c Choices) error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(choicesPath()), 0o755); err != nil {
		return err
	}
	return os.WriteFile(choicesPath(), append(b, '\n'), 0o644)
}

func findMbeq() (string, error) {
	matches, _ := filepath.Glob("/usr/lib/ladspa/mbeq_1197.so")
	if len(matches) == 0 {
		return "", fmt.Errorf("mbeq_1197.so not found in /usr/lib/ladspa (install swh-plugins)")
	}
	return matches[0], nil
}

// confString makes s safe between double quotes in a PipeWire .conf file.
func confString(s string) string {
	return strings.NewReplacer(`"`, "'", `\`, "/", "\n", " ").Replace(s)
}

// fxDir held the configs of the processed outputs of earlier versions.
func fxDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/soundbar-setup/fx")
}

// eqBands pairs the labels with the curve, as plain decimal numbers.
func eqBands(gains []string) ([]EQBand, error) {
	if len(gains) != len(eqBandLabels) {
		return nil, fmt.Errorf("expected %d EQ gains, got %d", len(eqBandLabels), len(gains))
	}
	bands := make([]EQBand, len(eqBandLabels))
	for i, label := range eqBandLabels {
		// A stray word here would make PipeWire reject the whole file.
		v, err := strconv.ParseFloat(strings.TrimSpace(gains[i]), 64)
		if err != nil {
			return nil, fmt.Errorf("%s: %q is not a number", label, gains[i])
		}
		bands[i] = EQBand{Label: label, Gain: strconv.FormatFloat(v, 'f', 1, 64)}
	}
	return bands, nil
}

// Render writes every config to its final location, stages vars.sh into
// stagingDir for audio.sh, saves the answers for the next run, and returns the
// list of written paths for the summary.
func Render(c Choices, stagingDir string) ([]string, error) {
	if len(c.Outputs) == 0 {
		return nil, fmt.Errorf("no output selected")
	}
	wpDir, _, sysDir, binDir := homePaths()

	data := tmplData{
		ScriptsDir:    binDir,
		MonitorSource: c.StatusSink + ".monitor",
		DisabledBT:    c.DisabledBT,
		DisabledCards: c.DisabledCards,
		EQParamsOff:   eqProps(""),
	}
	for i, o := range c.Outputs {
		rule := PriorityRule{o.Sink, outputPrio(i, len(c.Outputs))}
		switch {
		case strings.HasPrefix(o.Sink, "bluez_output"):
			data.BTPriorities = append(data.BTPriorities, rule)
		case strings.HasPrefix(o.Sink, "alsa_output"):
			data.ALSAPriorities = append(data.ALSAPriorities, rule)
		}
		data.RankedSinks = append(data.RankedSinks, o.Sink)
		if o.EQ {
			data.EQSinks = append(data.EQSinks, o.Sink)
		}
		if o.Keepalive {
			data.Keepalives = append(data.Keepalives, Tone{o.Sink, o.toneHz(), toneVolume(o.toneVol())})
		}
	}
	if len(data.EQSinks) > 0 {
		if _, err := findMbeq(); err != nil {
			return nil, err
		}
		bands, err := eqBands(c.EQGains)
		if err != nil {
			return nil, err
		}
		graph, err := eqGraph(bands)
		if err != nil {
			return nil, err
		}
		data.EQParamsOn = eqProps(graph)
	}
	for i, m := range c.Mics {
		rule := PriorityRule{m.Source, micPrio(i, len(c.Mics))}
		switch {
		case strings.HasPrefix(m.Source, "bluez_input"):
			data.BTPriorities = append(data.BTPriorities, rule)
		case strings.HasPrefix(m.Source, "alsa_input"):
			data.ALSAPriorities = append(data.ALSAPriorities, rule)
		}
		data.RankedSources = append(data.RankedSources, m.Source)
	}

	jobs := []struct {
		dest, tmpl string
		mode       os.FileMode
	}{
		{filepath.Join(wpDir, "99-device-priorities.conf"), "wireplumber-priorities.conf.tmpl", 0o644},
		{filepath.Join(sysDir, "audio-watch.service"), "audio-watch.service.tmpl", 0o644},
		{filepath.Join(binDir, "audio-watch"), "audio-watch.tmpl", 0o755},
		{filepath.Join(binDir, "audio-eq"), "audio-eq.tmpl", 0o755},
		{filepath.Join(binDir, "soundbar-status"), "soundbar-status.tmpl", 0o755},
	}

	var written []string
	for _, j := range jobs {
		if err := renderTo(j.dest, j.tmpl, j.mode, data); err != nil {
			return nil, err
		}
		written = append(written, j.dest)
	}

	// Earlier versions ran a second output in front of a device from here.
	if err := os.RemoveAll(fxDir()); err != nil {
		return nil, err
	}
	conf, err := writeRules(c)
	if err != nil {
		return nil, err
	}
	if conf != "" {
		written = append(written, conf)
	}

	if err := writeVarsSh(filepath.Join(stagingDir, "vars.sh"), c); err != nil {
		return nil, err
	}
	if err := saveChoices(c); err != nil {
		return nil, err
	}
	return append(written, choicesPath()), nil
}

func renderTo(dest, name string, mode os.FileMode, data any) error {
	tmpl, err := template.ParseFS(templatesFS, "templates/"+name)
	if err != nil {
		return fmt.Errorf("parse %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return fmt.Errorf("render %s: %w", name, err)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(dest, buf.Bytes(), mode); err != nil {
		return err
	}
	return os.Chmod(dest, mode) // ensure mode even when overwriting
}

// writeVarsSh emits the facts audio.sh needs to finish the install.
func writeVarsSh(path string, c Choices) error {
	hasBT := false
	hasEQ := false
	var b strings.Builder
	b.WriteString("# Generated by soundbar-setup — sourced by audio.sh\n")
	b.WriteString("OUTPUT_SUMMARY=(")
	for _, line := range outputLines(c) {
		fmt.Fprintf(&b, " %s", shQuote(line))
	}
	for _, o := range c.Outputs {
		hasBT = hasBT || strings.HasPrefix(o.Sink, "bluez_")
		hasEQ = hasEQ || o.EQ
	}
	b.WriteString(" )\n")
	fmt.Fprintf(&b, "STATUS_SINK=%s\n", shQuote(c.StatusSink))
	fmt.Fprintf(&b, "STATUS_DESC=%s\n", shQuote(c.StatusDesc))
	fmt.Fprintf(&b, "HAS_BT=%t\n", hasBT)
	fmt.Fprintf(&b, "HAS_EQ=%t\n", hasEQ)
	b.WriteString("MIC_SUMMARY=(")
	for i, m := range c.Mics {
		fmt.Fprintf(&b, " %s", shQuote(fmt.Sprintf("%d. %s", i+1, m.Desc)))
	}
	b.WriteString(" )\n")
	b.WriteString("DISABLED_CARDS=(")
	for _, card := range c.DisabledCards {
		fmt.Fprintf(&b, " %s", shQuote(card))
	}
	b.WriteString(" )\n")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

// shQuote single-quotes s for bash: nothing in a device description ($, `, ")
// gets expanded when audio.sh sources the file.
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// outputLines lists the outputs as they are ranked, with what each one gets.
func outputLines(c Choices) []string {
	lines := make([]string, len(c.Outputs))
	for i, o := range c.Outputs {
		line := o.Desc
		if fx := o.Effects(); fx != "" {
			line += " (" + fx + ")"
		}
		if o.Keepalive {
			line += " — keepalive " + toneLabel(o.toneHz(), o.toneVol())
		}
		lines[i] = fmt.Sprintf("%d. %s%s", i+1, line, correctionLabel(o))
	}
	return lines
}
