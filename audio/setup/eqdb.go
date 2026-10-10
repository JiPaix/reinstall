package main

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Correction EQs fix a device's frequency response (AutoEq-style parametric
// presets). Nothing is asked: an output whose model is in the database gets
// its preset, as one of the graphs set on the device node (graphs.go).

//go:embed eqdb.json
var embeddedEQDB []byte

// EQFilter is one band, with the AutoEq type names: PK, LSC, HSC.
type EQFilter struct {
	Type string  `json:"type"`
	Fc   float64 `json:"fc"`
	Gain float64 `json:"gain"`
	Q    float64 `json:"q"`
}

// EQChannel is what one ear gets on top of the entry's preamp and filters: a
// headset whose two drivers don't play at the same level.
type EQChannel struct {
	Preamp  float64    `json:"preamp,omitempty"`
	Filters []EQFilter `json:"filters,omitempty"`
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
	// Left and Right are added to Preamp and Filters for that channel only
	// (the first and second of the device). Unlike the rest of the entry they
	// can describe one unit rather than the model.
	Left  *EQChannel `json:"left,omitempty"`
	Right *EQChannel `json:"right,omitempty"`
}

// entryChannel is one per-channel part of an entry.
type entryChannel struct {
	N    int    // the channel number param_eq knows it by, from 1
	Side string // "left" or "right"
	*EQChannel
}

// channels lists the per-channel parts an entry really has.
func (e EQEntry) channels() []entryChannel {
	var out []entryChannel
	for i, ch := range []*EQChannel{e.Left, e.Right} {
		if ch != nil && (ch.Preamp != 0 || len(ch.Filters) > 0) {
			out = append(out, entryChannel{i + 1, []string{"left", "right"}[i], ch})
		}
	}
	return out
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
		filters := e.Filters
		for _, ch := range e.channels() {
			filters = append(filters[:len(filters):len(filters)], ch.Filters...)
		}
		for _, f := range filters {
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

// presetText writes an entry the way AutoEq does (ParametricEq.txt): all of
// it for one channel when ch is set, the part every channel shares otherwise.
func presetText(e EQEntry, ch *EQChannel) string {
	num := func(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }
	preamp, filters := e.Preamp, e.Filters
	if ch != nil {
		// Two decimals: the sum of two short decimals isn't one in binary.
		preamp = math.Round((preamp+ch.Preamp)*100) / 100
		filters = append(filters[:len(filters):len(filters)], ch.Filters...)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Preamp: %s dB\n", num(preamp))
	for i, f := range filters {
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

// correctionGraph is the graph of an entry and the preset files it reads
// (file -> content). param_eq takes its keys in order: "filename" sets every
// channel, then "filenameN" replaces channel N — whole, which is why a
// channel's file repeats the shared filters.
func correctionGraph(e EQEntry) (graph string, presets map[string]string) {
	file := filepath.Join(eqDir(), fileName(e.ID, e.Device))
	presets = map[string]string{file: presetText(e, nil)}
	config := fmt.Sprintf(`filename = "%s"`, confString(file))
	for _, ch := range e.channels() {
		chFile := strings.TrimSuffix(file, ".txt") + "-" + ch.Side + ".txt"
		presets[chFile] = presetText(e, ch.EQChannel)
		config += fmt.Sprintf(` filename%d = "%s"`, ch.N, confString(chFile))
	}
	return fmt.Sprintf(`{ nodes = [ { type = builtin name = eq label = param_eq config = { %s } } ] }`, config), presets
}

// correctionNote is the comment of a correction graph in the rules.
func correctionNote(e EQEntry) string {
	note := "correction EQ: " + e.Name
	if e.Source != "" {
		note += " (" + e.Source + ")"
	}
	for _, ch := range e.channels() {
		note += fmt.Sprintf("; %s ear %+g dB", ch.Side, ch.Preamp)
		if n := len(ch.Filters); n == 1 {
			note += " and 1 filter of its own"
		} else if n > 1 {
			note += fmt.Sprintf(" and %d filters of its own", n)
		}
	}
	return note
}
