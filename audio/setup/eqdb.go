package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Correction EQs fix a device's frequency response (AutoEq-style parametric
// presets). Unlike the equalizer/swap extras they are not an output of their
// own: WirePlumber sets the graph on the device node itself
// (node.filter-graph.rules), so everything played to the device goes through
// it and nothing new shows up in the output list.

//go:embed eqdb.json
var embeddedEQDB []byte

// correctionConf is the WirePlumber config holding the rules.
const correctionConf = "98-correction-eq.conf"

// EQFilter is one band, with the AutoEq type names: PK, LSC, HSC.
type EQFilter struct {
	Type string  `json:"type"`
	Fc   float64 `json:"fc"`
	Gain float64 `json:"gain"`
	Q    float64 `json:"q"`
}

// EQEntry is the correction for one device model.
type EQEntry struct {
	// ID names the model, never one unit of it: "usb:<vendor>:<product>" or
	// "bluetooth:<vendor>:<product>" (4 hex digits each), see modelID.
	ID string `json:"id"`
	// Device, when set, must also equal the device's name. Bluetooth ids are
	// often the chipset's and shared by unrelated products.
	Device  string     `json:"device,omitempty"`
	Name    string     `json:"name"`
	Source  string     `json:"source,omitempty"`
	Preamp  float64    `json:"preamp"`
	Filters []EQFilter `json:"filters"`
}

// filterTypes are the AutoEq filter types param_eq knows: peaking, low shelf
// and high shelf.
var filterTypes = map[string]bool{"PK": true, "LSC": true, "HSC": true}

// userEQDBPath is an optional database of the same format, read on top of the
// embedded one: a device can be added (or an entry replaced, same id and
// device) without waiting for a release.
func userEQDBPath() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/soundbar-setup/eqdb.json")
}

func parseEQDB(b []byte, from string) ([]EQEntry, error) {
	var entries []EQEntry
	if err := json.Unmarshal(b, &entries); err != nil {
		return nil, fmt.Errorf("%s: %w", from, err)
	}
	for _, e := range entries {
		if e.ID == "" || len(e.Filters) == 0 {
			return nil, fmt.Errorf("%s: entry %q needs an id and filters", from, e.Name)
		}
		for _, f := range e.Filters {
			if !filterTypes[f.Type] || f.Fc <= 0 || f.Q <= 0 {
				return nil, fmt.Errorf("%s: %s: bad filter %+v (type PK, LSC or HSC; fc and q above 0)", from, e.ID, f)
			}
		}
	}
	return entries, nil
}

// loadEQDB returns the user's entries followed by the embedded ones, so the
// first match is the user's.
func loadEQDB() ([]EQEntry, error) {
	db, err := parseEQDB(embeddedEQDB, "embedded eqdb.json")
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(userEQDBPath())
	if errors.Is(err, fs.ErrNotExist) {
		return db, nil
	}
	if err != nil {
		return nil, err
	}
	user, err := parseEQDB(b, userEQDBPath())
	if err != nil {
		return nil, err
	}
	return append(user, db...), nil
}

// modelID builds the database key from a card's properties, e.g.
// "usb:1532:0555". It is "" when the card has no vendor/product id (PCI audio).
func modelID(props map[string]string) string {
	bus := props["device.bus"]
	if bus != "usb" && bus != "bluetooth" {
		return ""
	}
	vendor, product := hex4(props["device.vendor.id"]), hex4(props["device.product.id"])
	if vendor == "" || product == "" {
		return ""
	}
	return bus + ":" + vendor + ":" + product
}

// hex4 normalises "0x1532", "bluetooth:05d6" or "usb:054c" to 4 hex digits.
func hex4(s string) string {
	if i := strings.LastIndex(s, ":"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	n, err := strconv.ParseUint(s, 16, 16)
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%04x", n)
}

// findCorrection returns the entry for an output, if its model has one.
func findCorrection(db []EQEntry, o Output) (EQEntry, bool) {
	if o.Model == "" {
		return EQEntry{}, false
	}
	for _, e := range db {
		if e.ID == o.Model && (e.Device == "" || e.Device == o.Desc) {
			return e, true
		}
	}
	return EQEntry{}, false
}

// correctionLabel is " — correction EQ: <name>" for an output that gets one.
// A broken user database only costs the label here: Render reports it.
func correctionLabel(o Output) string {
	db, err := loadEQDB()
	if err != nil {
		return ""
	}
	e, ok := findCorrection(db, o)
	if !ok {
		return ""
	}
	return " — correction EQ: " + e.Name
}

// eqDir holds one preset file per corrected model, in the AutoEq text format
// PipeWire's param_eq reads. The graph only names the file: an ALSA node
// refuses a param value over 511 bytes, which ten inline filters exceed.
func eqDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/soundbar-setup/eq")
}

// maxGraph is that limit (spa.alsa: "can't copy value … (max 511 bytes)").
const maxGraph = 511

// Correction is one WirePlumber rule: the graph of a model on its node(s).
type Correction struct {
	Desc, Name, Source string
	Match              string // the rule's match, in .conf syntax
	Graph              string
	File, Preset       string // the preset file and its content
}

// presetText writes an entry the way AutoEq does (ParametricEq.txt).
func presetText(e EQEntry) string {
	num := func(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }
	var b strings.Builder
	fmt.Fprintf(&b, "Preamp: %s dB\n", num(e.Preamp))
	for i, f := range e.Filters {
		fmt.Fprintf(&b, "Filter %d: ON %s Fc %s Hz Gain %s dB Q %s\n", i+1, f.Type, num(f.Fc), num(f.Gain), num(f.Q))
	}
	return b.String()
}

// fileName turns an id (and device name) into a plain file name.
func fileName(parts ...string) string {
	name := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		}
		return '-'
	}, strings.Join(parts, "-"))
	return strings.Trim(name, "-") + ".txt"
}

// buildCorrections returns one rule per output whose model is in the database.
func buildCorrections(c Choices) ([]Correction, error) {
	db, err := loadEQDB()
	if err != nil {
		return nil, err
	}
	var out []Correction
	seen := map[string]bool{}
	for _, o := range c.Outputs {
		e, ok := findCorrection(db, o)
		if !ok {
			continue
		}
		// A USB node name carries the unit's serial; the card name doesn't, so
		// the rule holds for any unit of the model, whatever its profile. A
		// Bluetooth node name is the address, and nothing else on the node
		// names the device.
		match := fmt.Sprintf(`node.name = "%s"`, o.Sink)
		if o.CardName != "" && strings.HasPrefix(o.Sink, "alsa_output") {
			match = fmt.Sprintf(`api.alsa.card.name = "%s", media.class = "Audio/Sink"`, confString(o.CardName))
		}
		if seen[match] {
			continue
		}
		seen[match] = true

		file := filepath.Join(eqDir(), fileName(e.ID, e.Device))
		// One line: WirePlumber passes the text as written, spaces included.
		graph := fmt.Sprintf(`{ nodes = [ { type = builtin name = eq label = param_eq config = { filename = "%s" } } ] }`, confString(file))
		if len(graph) > maxGraph {
			return nil, fmt.Errorf("correction EQ for %s: %s is too long a path", o.Desc, file)
		}
		out = append(out, Correction{
			Desc:   confString(o.Desc),
			Name:   confString(e.Name),
			Source: confString(e.Source),
			Match:  match,
			Graph:  graph,
			File:   file,
			Preset: presetText(e),
		})
	}
	return out, nil
}

// writeCorrections renders the rules to WirePlumber's conf.d with their preset
// files, or removes the lot when no output has a correction. It returns the
// path of the rules when written.
func writeCorrections(c Choices) (string, []Correction, error) {
	corrections, err := buildCorrections(c)
	if err != nil {
		return "", nil, err
	}
	wpDir, _, _, _ := homePaths()
	dest := filepath.Join(wpDir, correctionConf)
	// The presets of a previous run must not outlive it.
	if err := os.RemoveAll(eqDir()); err != nil {
		return "", nil, err
	}
	if len(corrections) == 0 {
		if err := os.Remove(dest); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return "", nil, err
		}
		return "", nil, nil
	}
	if err := os.MkdirAll(eqDir(), 0o755); err != nil {
		return "", nil, err
	}
	for _, k := range corrections {
		if err := os.WriteFile(k.File, []byte(k.Preset), 0o644); err != nil {
			return "", nil, err
		}
	}
	if err := renderTo(dest, "correction-eq.conf.tmpl", 0o644, corrections); err != nil {
		return "", nil, err
	}
	return dest, corrections, nil
}
