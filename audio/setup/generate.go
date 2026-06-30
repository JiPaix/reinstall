package main

import (
	"bytes"
	"embed"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
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

// Choices is the user's interactive selection — the input to rendering.
type Choices struct {
	PrimarySink   string
	PrimaryDesc   string
	Priorities    []string // ordered fallback sink names (after the primary)
	DisabledBT    []string // disabled bluez node names
	DisabledCards []string // disabled ALSA card names
	EQGains       []string // 15 dB values
	IsBT          bool
	BTInputName   string
}

// EQBand and PriorityRule feed the templates.
type EQBand struct{ Label, Gain string }
type PriorityRule struct {
	Name string
	Prio int
}

type tmplData struct {
	PrimarySink    string
	MbeqPath       string
	Username       string
	ScriptsDir     string
	MonitorSource  string
	EQBands        []EQBand
	BTPriorities   []PriorityRule
	ALSAPriorities []PriorityRule
	DisabledBT     []string
	DisabledCards  []string
	BtInputName    string
	IsBT           bool
}

// destinations under $HOME.
func homePaths() (wpDir, pwDir, systemdDir, binDir string) {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/wireplumber/wireplumber.conf.d"),
		filepath.Join(h, ".config/pipewire/pipewire.conf.d"),
		filepath.Join(h, ".config/systemd/user"),
		filepath.Join(h, ".local/bin")
}

func findMbeq() (string, error) {
	matches, _ := filepath.Glob("/usr/lib/ladspa/mbeq_1197.so")
	if len(matches) == 0 {
		return "", fmt.Errorf("mbeq_1197.so not found in /usr/lib/ladspa (install swh-plugins)")
	}
	return matches[0], nil
}

// Render writes every config to its final location, stages the udev rule (which
// needs sudo to install) and vars.sh into stagingDir, and returns the list of
// written paths for the summary.
func Render(c Choices, stagingDir string) ([]string, error) {
	u, err := user.Current()
	if err != nil {
		return nil, err
	}
	mbeq, err := findMbeq()
	if err != nil {
		return nil, err
	}
	wpDir, pwDir, sysDir, binDir := homePaths()

	bands := make([]EQBand, len(eqBandLabels))
	for i, label := range eqBandLabels {
		bands[i] = EQBand{Label: label, Gain: c.EQGains[i]}
	}

	var btP, alsaP []PriorityRule
	for i, name := range c.Priorities {
		prio := 2000 - i*500
		switch {
		case strings.HasPrefix(name, "bluez_output"):
			btP = append(btP, PriorityRule{name, prio})
		case strings.HasPrefix(name, "alsa_output"):
			alsaP = append(alsaP, PriorityRule{name, prio})
		}
	}

	data := tmplData{
		PrimarySink:    c.PrimarySink,
		MbeqPath:       mbeq,
		Username:       u.Username,
		ScriptsDir:     binDir,
		MonitorSource:  c.PrimarySink + ".monitor",
		EQBands:        bands,
		BTPriorities:   btP,
		ALSAPriorities: alsaP,
		DisabledBT:     c.DisabledBT,
		DisabledCards:  c.DisabledCards,
		BtInputName:    c.BTInputName,
		IsBT:           c.IsBT,
	}

	jobs := []struct {
		dest, tmpl string
		mode       os.FileMode
	}{
		{filepath.Join(wpDir, "99-device-priorities.conf"), "wireplumber-priorities.conf.tmpl", 0o644},
		{filepath.Join(pwDir, "soundbar-eq.conf"), "soundbar-eq.conf.tmpl", 0o644},
		{filepath.Join(sysDir, "soundbar-keepalive.service"), "soundbar-keepalive.service.tmpl", 0o644},
		{filepath.Join(sysDir, "soundbar-loopback.service"), "soundbar-loopback.service.tmpl", 0o644},
		{filepath.Join(binDir, "soundbar-loopback"), "soundbar-loopback.tmpl", 0o755},
		{filepath.Join(binDir, "soundbar-keepalive"), "soundbar-keepalive.tmpl", 0o755},
		{filepath.Join(binDir, "soundbar-status"), "soundbar-status.tmpl", 0o755},
	}

	var written []string
	for _, j := range jobs {
		if err := renderTo(j.dest, j.tmpl, j.mode, data); err != nil {
			return nil, err
		}
		written = append(written, j.dest)
	}

	udevFile := ""
	if c.IsBT && c.BTInputName != "" {
		udevFile = filepath.Join(stagingDir, "99-soundbar-keepalive.rules")
		if err := renderTo(udevFile, "udev-keepalive.rules.tmpl", 0o644, data); err != nil {
			return nil, err
		}
		written = append(written, udevFile+"  (staged → /etc/udev/rules.d)")
	}

	if err := writeVarsSh(filepath.Join(stagingDir, "vars.sh"), c, udevFile); err != nil {
		return nil, err
	}
	return written, nil
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
func writeVarsSh(path string, c Choices, udevFile string) error {
	var b strings.Builder
	b.WriteString("# Generated by soundbar-setup — sourced by audio.sh\n")
	fmt.Fprintf(&b, "PRIMARY_SINK=%q\n", c.PrimarySink)
	fmt.Fprintf(&b, "PRIMARY_DESC=%q\n", c.PrimaryDesc)
	fmt.Fprintf(&b, "IS_BT=%t\n", c.IsBT)
	fmt.Fprintf(&b, "UDEV_RULE_FILE=%q\n", udevFile)
	b.WriteString("DISABLED_CARDS=(")
	for _, card := range c.DisabledCards {
		fmt.Fprintf(&b, " %q", card)
	}
	b.WriteString(" )\n")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}
