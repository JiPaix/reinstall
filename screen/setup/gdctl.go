package main

import (
	"bufio"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// Mode is one display mode of a connector, with the VRR variant folded in.
type Mode struct {
	W, H           int
	Refresh        string // e.g. "164.958"
	Scales         []float64
	PreferredScale float64
	HasVRR         bool // a "+vrr" variant of this mode exists
	Current        bool // this mode (any variant) is currently active
	CurrentIsVRR   bool // the active variant is the +vrr one
	Preferred      bool
}

// Spec returns the base gdctl mode token, e.g. "2560x1440@164.958".
func (m Mode) Spec() string { return fmt.Sprintf("%dx%d@%s", m.W, m.H, m.Refresh) }

// Resolution returns "WxH", e.g. "2560x1440".
func (m Mode) Resolution() string { return fmt.Sprintf("%dx%d", m.W, m.H) }

// Connector is a physical output (DP-1, HDMI-1, …) and its modes.
type Connector struct {
	Name  string // "DP-1"
	Desc  string // "LG Electronics 27\""
	Modes []Mode
}

// Label is a human-friendly one-liner for pickers.
func (c Connector) Label() string {
	if c.Desc != "" {
		return fmt.Sprintf("%s — %s", c.Name, c.Desc)
	}
	return c.Name
}

// Resolutions lists unique "WxH" strings in detection order.
func (c Connector) Resolutions() []string {
	seen := map[string]bool{}
	var out []string
	for _, m := range c.Modes {
		r := m.Resolution()
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	return out
}

// ModesFor returns the modes matching a given "WxH" resolution.
func (c Connector) ModesFor(res string) []Mode {
	var out []Mode
	for _, m := range c.Modes {
		if m.Resolution() == res {
			out = append(out, m)
		}
	}
	return out
}

// DefaultMode picks the current mode, else the preferred, else the first.
func (c Connector) DefaultMode() Mode {
	for _, m := range c.Modes {
		if m.Current {
			return m
		}
	}
	for _, m := range c.Modes {
		if m.Preferred {
			return m
		}
	}
	if len(c.Modes) > 0 {
		return c.Modes[0]
	}
	return Mode{}
}

// DetectConnectors runs `gdctl show -v` and parses its output. The verbose form
// (not -m, which is headers-only) lists every mode together with its supported
// scales and is-current/is-preferred properties.
func DetectConnectors() ([]Connector, error) {
	out, err := exec.Command("gdctl", "show", "-v").Output()
	if err != nil {
		return nil, fmt.Errorf("running 'gdctl show -v': %w", err)
	}
	return parseGdctlShow(string(out)), nil
}

var (
	reMonitor      = regexp.MustCompile(`^Monitor (\S+)(?:\s+\((.*)\))?$`)
	reMode         = regexp.MustCompile(`^(\d+)x(\d+)@([\d.]+)(\+vrr)?$`)
	reScales       = regexp.MustCompile(`^Supported scales:\s*\[(.*)\]$`)
	rePrefScale    = regexp.MustCompile(`^Preferred scale:\s*([\d.]+)$`)
	boxDrawingTrim = "│├└─ \t"
)

// parseGdctlShow turns the box-drawing tree from `gdctl show -m` into connectors.
// It tracks the current connector and mode by line order; +vrr variants are
// folded into their base mode (HasVRR = true).
func parseGdctlShow(s string) []Connector {
	var conns []Connector
	var curConn *Connector
	var curMode *Mode
	curHeaderVRR := false

	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		content := strings.TrimLeft(strings.TrimRight(sc.Text(), " \t"), boxDrawingTrim)
		if content == "" {
			continue
		}

		if m := reMonitor.FindStringSubmatch(content); m != nil {
			conns = append(conns, Connector{Name: m[1], Desc: m[2]})
			curConn = &conns[len(conns)-1]
			curMode = nil
			continue
		}
		if curConn == nil {
			continue
		}

		if m := reMode.FindStringSubmatch(content); m != nil {
			w, _ := strconv.Atoi(m[1])
			h, _ := strconv.Atoi(m[2])
			vrr := m[4] == "+vrr"
			curMode = findOrAddMode(curConn, w, h, m[3])
			if vrr {
				curMode.HasVRR = true
			}
			curHeaderVRR = vrr
			continue
		}

		if curMode == nil {
			continue
		}
		switch {
		case reScales.MatchString(content):
			curMode.Scales = parseScales(reScales.FindStringSubmatch(content)[1])
		case rePrefScale.MatchString(content):
			curMode.PreferredScale, _ = strconv.ParseFloat(rePrefScale.FindStringSubmatch(content)[1], 64)
		case strings.HasPrefix(content, "is-current") && strings.Contains(content, "yes"):
			curMode.Current = true
			curMode.CurrentIsVRR = curHeaderVRR
		case strings.HasPrefix(content, "is-preferred") && strings.Contains(content, "yes"):
			curMode.Preferred = true
		}
	}
	return conns
}

// findOrAddMode returns the mode with the given dimensions/refresh, creating it
// if absent. Appends only happen on a new mode header, right before curMode is
// reassigned, so previously held *Mode pointers are never used after a realloc.
func findOrAddMode(c *Connector, w, h int, refresh string) *Mode {
	for i := range c.Modes {
		if c.Modes[i].W == w && c.Modes[i].H == h && c.Modes[i].Refresh == refresh {
			return &c.Modes[i]
		}
	}
	c.Modes = append(c.Modes, Mode{W: w, H: h, Refresh: refresh})
	return &c.Modes[len(c.Modes)-1]
}

// parseScales parses "1.0, 2.0" into []float64{1.0, 2.0}.
func parseScales(s string) []float64 {
	var out []float64
	for _, tok := range strings.Split(s, ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}
		if v, err := strconv.ParseFloat(tok, 64); err == nil {
			out = append(out, v)
		}
	}
	return out
}
