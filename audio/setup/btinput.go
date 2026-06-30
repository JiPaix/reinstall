package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// inputDeviceNames returns the unique ATTRS{name} values from /sys/class/input.
// These are the names a udev rule matches on (e.g. "HIGHONE BDS C10 (AVRCP)").
func inputDeviceNames() []string {
	dirs, _ := filepath.Glob("/sys/class/input/input*")
	seen := map[string]bool{}
	var out []string
	for _, d := range dirs {
		b, err := os.ReadFile(filepath.Join(d, "name"))
		if err != nil {
			continue
		}
		n := strings.TrimSpace(string(b))
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// matchBTInputName auto-matches a Bluetooth device's udev input name from its
// PulseAudio description: the input name is "<desc>" or "<desc> (AVRCP)".
// Returns "" when nothing matches.
func matchBTInputName(desc string, names []string) string {
	avrcp := desc + " (AVRCP)"
	for _, n := range names {
		if n == avrcp || n == desc {
			return n
		}
	}
	return ""
}
