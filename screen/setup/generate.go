package main

import (
	_ "embed"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

//go:embed swapscreen.tmpl.sh
var engineTemplate string

const profilesMarker = "#__PROFILES__"

// formatScale renders a scale with minimal digits: 1.0→"1", 2.0→"2", 1.25→"1.25".
func formatScale(s float64) string { return strconv.FormatFloat(s, 'f', -1, 64) }

// cellSpec renders one monitor as a `key=value …` token string for the bash array.
func cellSpec(p Placed) string {
	parts := []string{
		"connector=" + p.Connector,
		"mode=" + p.ModeSpec,
		"vrr=" + strconv.FormatBool(p.VRR),
		"scale=" + formatScale(p.Scale),
		"color=" + p.Color,
		"x=" + strconv.Itoa(p.X),
		"y=" + strconv.Itoa(p.Y),
	}
	if p.Primary {
		parts = append(parts, "primary=true")
	}
	return strings.Join(parts, " ")
}

// arrayLiteral renders a bash array of monitor specs.
func arrayLiteral(name string, placed []Placed) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s=(\n", name)
	for _, p := range placed {
		fmt.Fprintf(&b, "    %q\n", cellSpec(p))
	}
	b.WriteString(")\n")
	return b.String()
}

// buildProfilesBlock renders the three profile arrays. taikoExtra holds the rows
// stacked on top of the monitor grid; the full taiko layout (monitor rows +
// extra) is auto-aligned and normalized as one grid, so its cells are emitted
// explicitly (it can't reuse MONITOR_PROFILE — the monitor rows shift down to
// make room above).
func buildProfilesBlock(backend string, monitor, tv Profile, taikoExtra [][]Cell) string {
	taiko := Profile{Rows: append(append([][]Cell{}, monitor.Rows...), taikoExtra...)}

	var b strings.Builder
	// BACKEND drives the engine's apply/query dispatch (gnome=gdctl, kde=
	// kscreen-doctor) and is also read by screen.sh when it sources this block.
	fmt.Fprintf(&b, "BACKEND=%s\n\n", backend)
	b.WriteString(arrayLiteral("MONITOR_PROFILE", monitor.AutoAlign()))
	b.WriteString(arrayLiteral("TV_PROFILE", tv.AutoAlign()))
	b.WriteString(arrayLiteral("TAIKO_PROFILE", taiko.AutoAlign()))
	return b.String()
}

// Generate writes profiles.conf (the captured arrays, prefixed with BACKEND=)
// and the rendered swapscreen.sh (the engine template with that block injected).
// For the GNOME backend it also writes gdm-monitors.xml (the GDM greeter layout:
// monitor profile's primary screen only, everything else explicitly disabled);
// KDE uses SDDM, which has no equivalent, so that file is skipped there.
func Generate(profilesPath, scriptPath, gdmPath, backend string, conns []Connector, monitor, tv Profile, taikoExtra [][]Cell) error {
	block := strings.TrimRight(buildProfilesBlock(backend, monitor, tv, taikoExtra), "\n")

	header := "# Généré par swapscreen-setup — ne pas éditer à la main.\n" +
		"# Reconfigurer : relancer ./screen.sh\n\n"
	if err := writeFile(profilesPath, header+block+"\n"); err != nil {
		return err
	}

	if !strings.Contains(engineTemplate, profilesMarker) {
		return fmt.Errorf("template is missing the %q marker", profilesMarker)
	}
	script := strings.Replace(engineTemplate, profilesMarker, block, 1)
	script = injectGeneratedHeader(script)
	if err := writeFile(scriptPath, script); err != nil {
		return err
	}

	if backend == "gnome" {
		return writeFile(gdmPath, buildGDMMonitorsXML(conns, monitor))
	}
	return nil
}

// buildGDMMonitorsXML renders a mutter schema-v2 monitors.xml for the GDM
// greeter. The greeter only ever needs to show the single monitor the user
// picked as primary for the "monitor" profile — not the full desk grid — so
// that one logical monitor is forced to (0,0) and every other detected
// connector (2nd desk monitor, TV, taiko extra) is listed as disabled.
func buildGDMMonitorsXML(conns []Connector, monitor Profile) string {
	byName := make(map[string]Connector, len(conns))
	for _, c := range conns {
		byName[c.Name] = c
	}

	placed := monitor.AutoAlign()
	var primary Placed
	if len(placed) > 0 {
		primary = placed[0]
	}
	for _, p := range placed {
		if p.Primary {
			primary = p
			break
		}
	}
	pc := byName[primary.Connector]

	var b strings.Builder
	b.WriteString("<monitors version=\"2\">\n  <configuration>\n")
	b.WriteString("    <logicalmonitor>\n")
	b.WriteString("      <x>0</x>\n      <y>0</y>\n")
	fmt.Fprintf(&b, "      <scale>%s</scale>\n", formatScale(primary.Scale))
	b.WriteString("      <primary>yes</primary>\n")
	b.WriteString("      <monitor>\n        <monitorspec>\n")
	writeMonitorSpec(&b, "          ", primary.Connector, pc)
	b.WriteString("        </monitorspec>\n        <mode>\n")
	fmt.Fprintf(&b, "          <width>%d</width>\n          <height>%d</height>\n          <rate>%s</rate>\n",
		primary.W, primary.H, modeRate(primary.ModeSpec))
	b.WriteString("        </mode>\n      </monitor>\n    </logicalmonitor>\n")

	for _, c := range conns {
		if c.Name == primary.Connector {
			continue
		}
		b.WriteString("    <disabled>\n      <monitorspec>\n")
		writeMonitorSpec(&b, "        ", c.Name, c)
		b.WriteString("      </monitorspec>\n    </disabled>\n")
	}

	b.WriteString("  </configuration>\n</monitors>\n")
	return b.String()
}

func writeMonitorSpec(b *strings.Builder, indent, connector string, c Connector) {
	fmt.Fprintf(b, "%s<connector>%s</connector>\n", indent, xmlEscape(connector))
	fmt.Fprintf(b, "%s<vendor>%s</vendor>\n", indent, xmlEscape(c.Vendor))
	fmt.Fprintf(b, "%s<product>%s</product>\n", indent, xmlEscape(c.Product))
	fmt.Fprintf(b, "%s<serial>%s</serial>\n", indent, xmlEscape(c.Serial))
}

// modeRate returns the refresh-rate portion of a "WxH@rate" mode spec.
func modeRate(spec string) string {
	if i := strings.IndexByte(spec, '@'); i >= 0 {
		return spec[i+1:]
	}
	return spec
}

func xmlEscape(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// injectGeneratedHeader inserts a "do not edit" banner just after the shebang.
func injectGeneratedHeader(script string) string {
	banner := "# GENERATED by swapscreen-setup from setup/swapscreen.tmpl.sh — do not edit.\n" +
		"# Reconfigure by re-running ./screen.sh"
	if nl := strings.IndexByte(script, '\n'); nl >= 0 {
		return script[:nl+1] + banner + "\n" + script[nl+1:]
	}
	return banner + "\n" + script
}

func writeFile(path, content string) error {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return os.WriteFile(path, []byte(content), 0o644)
}
