package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
)

// reKsModeName pulls WxH@refresh out of a kscreen mode name like "2560x1440@165".
var reKsModeName = regexp.MustCompile(`^(\d+)x(\d+)@([\d.]+)`)

// kdeBaseScales are the scales offered on KDE. Unlike mutter, kscreen-doctor
// advertises no per-mode scale list (KDE accepts arbitrary fractions), so offer
// a sane set; the output's current scale is merged in by kdeScalesFor.
var kdeBaseScales = []float64{1, 1.25, 1.5, 1.75, 2, 2.5, 3}

// jsonStr unmarshals a JSON value that may be a string OR a number into a Go
// string (kscreen writes mode ids as strings, but be liberal). It just drops
// surrounding quotes, so `"50"` and `50` both become `50`.
type jsonStr string

func (s *jsonStr) UnmarshalJSON(b []byte) error {
	*s = jsonStr(bytes.Trim(b, `"`))
	return nil
}

type ksSize struct {
	Width  int `json:"width"`
	Height int `json:"height"`
}

type ksMode struct {
	ID          jsonStr `json:"id"`
	Name        string  `json:"name"`
	RefreshRate float64 `json:"refreshRate"`
	Size        ksSize  `json:"size"`
}

type ksOutput struct {
	Name           string    `json:"name"`
	Connected      bool      `json:"connected"`
	CurrentModeID  jsonStr   `json:"currentModeId"`
	PreferredModes []jsonStr `json:"preferredModes"`
	Scale          float64   `json:"scale"`
	Modes          []ksMode  `json:"modes"`

	// VrrPolicy is only serialized for VRR-capable outputs, so nil means the
	// output can't do VRR — the same distinction `kscreen-doctor -o` renders as
	// "Vrr: Never" (capable, policy off) vs "Vrr: incapable". There is no
	// `capabilities` field to consult.
	VrrPolicy *int `json:"vrrPolicy"`

	// Same convention for HDR/WCG: the keys are absent on incapable outputs
	// ("HDR: incapable" in `-o`) and false on capable ones that are just off,
	// so non-nil means capable.
	HDR *bool `json:"hdr"`
	WCG *bool `json:"wcg"`
}

type ksConfig struct {
	Outputs []ksOutput `json:"outputs"`
}

// detectKscreen runs `kscreen-doctor -j` and maps its connected outputs to the
// same Connector/Mode model the gdctl backend produces. The stored `mode` token
// is kscreen's own mode name (e.g. "2560x1440@165" for a 164.958 Hz mode) — the
// exact string `kscreen-doctor output.<c>.mode.<name>` accepts.
func detectKscreen() ([]Connector, error) {
	out, err := exec.Command("kscreen-doctor", "-j").Output()
	if err != nil {
		return nil, fmt.Errorf("running 'kscreen-doctor -j': %w", err)
	}
	var cfg ksConfig
	if err := json.Unmarshal(out, &cfg); err != nil {
		return nil, fmt.Errorf("parsing 'kscreen-doctor -j' output: %w", err)
	}

	var conns []Connector
	for _, o := range cfg.Outputs {
		if !o.Connected {
			continue
		}
		scales := kdeScalesFor(o.Scale)
		// bt2100 enables both HDR and WCG, so it needs both capabilities.
		hdr := o.HDR != nil && o.WCG != nil
		c := Connector{Name: o.Name, HDR: &hdr}
		for _, m := range o.Modes {
			w, h, refresh := ksModeFields(m)
			if w == 0 || h == 0 {
				continue
			}
			// kscreen lists several distinct modes under one name (e.g. 60.00
			// and 59.94 are both "3840x2160@60"); fold them like the gdctl
			// backend does so the picker shows each refresh once.
			mode := findOrAddMode(&c, w, h, refresh)
			mode.Scales = scales
			mode.PreferredScale = o.Scale
			if o.VrrPolicy != nil {
				mode.HasVRR = true
			}
			if m.ID != "" && m.ID == o.CurrentModeID {
				mode.Current = true
			}
			if slices.Contains(o.PreferredModes, m.ID) {
				mode.Preferred = true
			}
		}
		conns = append(conns, c)
	}
	return conns, nil
}

// kdeScalesFor returns the scales to offer, merging in the output's current one
// (KDE allows arbitrary fractions — e.g. 1.7 — that aren't in the base list).
func kdeScalesFor(current float64) []float64 {
	scales := slices.Clone(kdeBaseScales)
	if current > 0 && !slices.Contains(scales, current) {
		scales = append(scales, current)
		slices.Sort(scales)
	}
	return scales
}

// ksModeFields returns width, height, and the refresh string for a kscreen mode.
// It prefers the canonical `name`, whose refresh is rounded to a whole number
// (164.958 Hz -> "2560x1440@165"), so Mode.Spec() reproduces exactly the token
// kscreen-doctor accepts; connector_modes_kde in the engine rounds `-o` output
// the same way so validate_profile can compare them.
func ksModeFields(m ksMode) (int, int, string) {
	if sm := reKsModeName.FindStringSubmatch(m.Name); sm != nil {
		w, _ := strconv.Atoi(sm[1])
		h, _ := strconv.Atoi(sm[2])
		return w, h, sm[3]
	}
	if m.Size.Width == 0 || m.Size.Height == 0 {
		return 0, 0, ""
	}
	return m.Size.Width, m.Size.Height, strconv.FormatFloat(math.Round(m.RefreshRate), 'f', -1, 64)
}
