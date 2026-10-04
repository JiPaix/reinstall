package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// Choices is everything the wizard asks. It is saved between runs so the next
// one can offer each layout back instead of asking it all over again.
type Choices struct {
	Backend    string   `json:"backend"`
	Monitor    Profile  `json:"monitor"`
	TV         Profile  `json:"tv"`
	TaikoExtra [][]Cell `json:"taiko_extra,omitempty"`
	// TVs are the connectors handled as TVs by the engine (KDE only): woken
	// before a switch, put to sleep after, and pinned by screen.sh.
	TVs []string `json:"tvs"`
}

// choicesPath is where the answers are kept between runs.
func choicesPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "swapscreen-setup", "choices.json")
}

// LoadChoices returns the previous run's answers, or a zero Choices when there
// are none (or they can't be read: they only pre-fill the prompts).
func LoadChoices() Choices {
	var c Choices
	b, err := os.ReadFile(choicesPath())
	if err != nil || json.Unmarshal(b, &c) != nil {
		return Choices{}
	}
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

// layoutUsable tells whether a saved layout can be offered back: it places at
// least one screen, and each one is detected and still has the saved mode.
func layoutUsable(rows [][]Cell, conns []Connector) bool {
	n := 0
	for _, row := range rows {
		for _, cell := range row {
			n++
			i := slices.IndexFunc(conns, func(c Connector) bool { return c.Name == cell.Connector })
			if i < 0 || !slices.ContainsFunc(conns[i].Modes, func(m Mode) bool { return m.Spec() == cell.ModeSpec }) {
				return false
			}
		}
	}
	return n > 0
}

// describeRows renders a layout the way it sits on the desk: top row first,
// one line per row, "★" on the primary.
func describeRows(rows [][]Cell) string {
	var b strings.Builder
	for r := len(rows) - 1; r >= 0; r-- {
		cells := make([]string, len(rows[r]))
		for i, c := range rows[r] {
			s := fmt.Sprintf("%s %s ×%s", c.Connector, c.ModeSpec, formatScale(c.Scale))
			if c.Color == "bt2100" {
				s += " HDR"
			}
			if c.VRR {
				s += " VRR"
			}
			if c.Primary {
				s += " ★"
			}
			cells[i] = s
		}
		fmt.Fprintf(&b, "  %s\n", strings.Join(cells, "  |  "))
	}
	return b.String()
}

// summary is what the review screen shows before anything is written.
func summary(c Choices) string {
	var b strings.Builder
	fmt.Fprintf(&b, "monitor\n%s\ntv\n%s", describeRows(c.Monitor.Rows), describeRows(c.TV.Rows))
	if len(c.TaikoExtra) > 0 {
		fmt.Fprintf(&b, "\ntaiko: the monitor layout, with on top\n%s", describeRows(c.TaikoExtra))
	}
	if c.Backend == "kde" {
		tvs := "none"
		if len(c.TVs) > 0 {
			tvs = strings.Join(c.TVs, ", ")
		}
		fmt.Fprintf(&b, "\nHandled as TVs: %s\n", tvs)
	}
	b.WriteString("\n★ primary")
	return b.String()
}
