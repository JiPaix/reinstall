package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Every effect is a filter graph set on the device node itself
// (audioconvert.filter-graph.N): no node of its own, so nothing new shows up
// in the output list and nothing can stay selected with its device gone.
//
//   - swapped channels and the correction EQ are permanent: WirePlumber sets
//     them whenever the node appears (node.filter-graph.rules, numbered from 0).
//     The swap comes first, so a correction's per-channel part (eqdb.go) lands
//     on the driver it was meant for;
//   - the equalizer has a switch: audio-eq sets or clears it at eqGraphIndex.

// graphsConf is the WirePlumber config holding the rules.
const graphsConf = "98-device-graphs.conf"

// eqGraphIndex is the last slot audioconvert has, out of the way of the ones
// WirePlumber hands out to the rules.
const eqGraphIndex = 8

// maxGraph: an ALSA node drops a param value over 511 bytes (spa.alsa: "can't
// copy value … (max 511 bytes)"), so every graph has to fit on one short line.
const maxGraph = 511

// swapGraph crosses left and right.
const swapGraph = `{ nodes = [ { type = builtin name = l label = copy } { type = builtin name = r label = copy } ] inputs = [ "l:In" "r:In" ] outputs = [ "r:Out" "l:Out" ] }`

// eqGraph is the equalizer for one channel; audioconvert runs one instance per
// channel of the device.
func eqGraph(bands []EQBand) (string, error) {
	var b strings.Builder
	b.WriteString("{ nodes = [ { type = ladspa name = eq plugin = mbeq_1197 label = mbeq control = {")
	for _, band := range bands {
		fmt.Fprintf(&b, ` "%s" = %s`, band.Label, band.Gain)
	}
	b.WriteString(" } } ] }")
	if b.Len() > maxGraph {
		return "", fmt.Errorf("the equalizer graph is %d bytes, over the %d a device accepts: use shorter gain values", b.Len(), maxGraph)
	}
	return b.String(), nil
}

// eqProps is the Props value for `pw-cli set-param` that sets graph on a
// device, or clears it when graph is "".
func eqProps(graph string) string {
	return fmt.Sprintf(`{ params = [ "audioconvert.filter-graph.%d" "%s" ] }`,
		eqGraphIndex, strings.ReplaceAll(graph, `"`, `\"`))
}

// GraphRule is one WirePlumber rule: the permanent graphs of a device.
type GraphRule struct {
	Desc   string
	Match  string // the rule's match, in .conf syntax
	Graphs []string
	Notes  []string // what each graph is, for the comments

	presets map[string]string // preset file -> content
}

// buildRules returns one rule per output with swapped channels and/or a
// correction EQ.
func buildRules(c Choices) ([]GraphRule, error) {
	db, err := loadEQDB()
	if err != nil {
		return nil, err
	}
	var rules []GraphRule
	seen := map[string]bool{}
	for _, o := range c.Outputs {
		r := GraphRule{Desc: confString(o.Desc), presets: map[string]string{}}
		if o.Swap {
			r.Graphs = append(r.Graphs, swapGraph)
			r.Notes = append(r.Notes, "left and right swapped")
		}
		if e, ok := findCorrection(db, o); ok {
			graph, presets := correctionGraph(e)
			r.Graphs = append(r.Graphs, graph)
			r.Notes = append(r.Notes, confString(correctionNote(e)))
			r.presets = presets
		}
		if len(r.Graphs) == 0 {
			continue
		}
		for _, g := range r.Graphs {
			if len(g) > maxGraph {
				return nil, fmt.Errorf("%s: a graph is %d bytes, over the %d a device accepts", o.Desc, len(g), maxGraph)
			}
		}
		// A USB node name carries the unit's serial; the card name doesn't, so
		// the rule holds for any unit of the model, whatever its profile. A
		// Bluetooth node name is the address, and nothing else on the node
		// names the device.
		r.Match = fmt.Sprintf(`node.name = "%s"`, o.Sink)
		if o.CardName != "" && strings.HasPrefix(o.Sink, "alsa_output") {
			r.Match = fmt.Sprintf(`api.alsa.card.name = "%s", media.class = "Audio/Sink"`, confString(o.CardName))
		}
		if seen[r.Match] {
			continue
		}
		seen[r.Match] = true
		rules = append(rules, r)
	}
	return rules, nil
}

// writeRules renders the rules to WirePlumber's conf.d with their preset
// files, or removes the lot when no output needs one. It returns the path of
// the rules when written.
func writeRules(c Choices) (string, error) {
	rules, err := buildRules(c)
	if err != nil {
		return "", err
	}
	wpDir, _, _, _ := homePaths()
	dest := filepath.Join(wpDir, graphsConf)
	// The presets of a previous run must not outlive it.
	if err := os.RemoveAll(eqDir()); err != nil {
		return "", err
	}
	if len(rules) == 0 {
		if err := os.Remove(dest); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		return "", nil
	}
	for _, r := range rules {
		for file, text := range r.presets {
			if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
				return "", err
			}
			if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
				return "", err
			}
		}
	}
	if err := renderTo(dest, "device-graphs.conf.tmpl", 0o644, rules); err != nil {
		return "", err
	}
	return dest, nil
}
