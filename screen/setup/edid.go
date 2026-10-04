package main

import (
	"os"
	"path/filepath"
	"strings"
)

// edidName returns what the screen plugged into a connector calls itself: the
// monitor name of its EDID, else its 3-letter manufacturer id, else "" (no
// EDID to read: connector off, or not a DRM name). kscreen-doctor reports no
// vendor or model, and "HDMI-A-1" alone doesn't tell a TV from a monitor.
func edidName(connector string) string {
	matches, _ := filepath.Glob("/sys/class/drm/card*-" + connector + "/edid")
	for _, m := range matches {
		if b, err := os.ReadFile(m); err == nil {
			if name := parseEDIDName(b); name != "" {
				return name
			}
		}
	}
	return ""
}

// parseEDIDName reads the name out of an EDID base block: the 0xFC display
// descriptor (one of the four 18-byte descriptors from offset 54), falling
// back on the PNP manufacturer id packed in bytes 8-9.
func parseEDIDName(b []byte) string {
	if len(b) < 128 {
		return ""
	}
	for off := 54; off+18 <= 126; off += 18 {
		d := b[off : off+18]
		if d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 0xFC {
			// 13 bytes of text, ended by a newline and padded with spaces.
			text, _, _ := strings.Cut(string(d[5:18]), "\n")
			if name := printable(text); name != "" {
				return name
			}
		}
	}
	v := uint16(b[8])<<8 | uint16(b[9])
	id := []byte{byte(v >> 10 & 0x1f), byte(v >> 5 & 0x1f), byte(v & 0x1f)}
	for i := range id {
		if id[i] < 1 || id[i] > 26 {
			return ""
		}
		id[i] += 'A' - 1
	}
	return string(id)
}

// printable keeps the printable ASCII of s, trimmed.
func printable(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
