package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// sampleChoices is a representative selection: a Bluetooth soundbar with every
// extra, a headset with a swap only, a plain ALSA output.
func sampleChoices() Choices {
	return Choices{
		Outputs: []Output{
			{Sink: "bluez_output.AA_BB.1", Desc: `Sound "bar"`, EQ: true, Swap: true, Keepalive: true},
			{Sink: "bluez_output.CC_DD.1", Desc: "Headset", Swap: true},
			{Sink: "alsa_output.pci-0000_0b_00.1.analog-stereo", Desc: "Speakers"},
		},
		EQGains:       defaultEQ,
		StatusSink:    "bluez_output.AA_BB.1",
		StatusDesc:    `Sound "bar"`,
		DisabledBT:    []string{"bluez_card.EE_FF"},
		DisabledCards: []string{"alsa_card.usb-Webcam-02"},
		DefaultSource: "alsa_input.usb-Mic-00.mono-fallback",
		DefaultDesc:   "USB Mic's",
	}
}

// render runs Render against a throwaway $HOME and returns readers for the
// files under it and under the staging dir.
func render(t *testing.T, c Choices) (home, staged func(string) string) {
	t.Helper()
	for _, o := range c.Outputs {
		if o.EQ {
			if _, err := findMbeq(); err != nil {
				t.Skip("mbeq plugin not installed; skipping")
			}
		}
	}
	homeDir, staging := t.TempDir(), t.TempDir()
	t.Setenv("HOME", homeDir)

	written, err := Render(c, staging)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if len(written) == 0 {
		t.Fatal("Render returned no files")
	}
	reader := func(dir string) func(string) string {
		return func(rel string) string {
			b, err := os.ReadFile(filepath.Join(dir, rel))
			if err != nil {
				t.Fatalf("read %s: %v", rel, err)
			}
			return string(b)
		}
	}
	return reader(homeDir), reader(staging)
}

// TestRenderProducesExpectedBodies renders the templates from a representative
// set of choices and checks each generated file for its key substitutions.
func TestRenderProducesExpectedBodies(t *testing.T) {
	home, staged := render(t, sampleChoices())
	homeDir := os.Getenv("HOME")

	wp := home(".config/wireplumber/wireplumber.conf.d/99-device-priorities.conf")
	mustContain(t, "wireplumber", wp,
		`linking.allow-moving-streams  = true`,
		`monitor.bluez.rules = [`,
		// Every device carries its own rank, extras or not.
		"node.name = \"bluez_output.AA_BB.1\" }]\n    actions = { update-props = { priority.session = 2200 } }",
		"node.name = \"bluez_output.CC_DD.1\" }]\n    actions = { update-props = { priority.session = 2100 } }",
		`device.name = "bluez_card.EE_FF"`, // hidden BT: the device, not a node
		`device.disabled = true`,
		`monitor.alsa.rules = [`,
		"node.name = \"alsa_output.pci-0000_0b_00.1.analog-stereo\" }]\n    actions = { update-props = { priority.session = 2000 } }",
		`device.name = "alsa_card.usb-Webcam-02"`,
		`device.profile = "off"`,
		`node.name = "~alsa_input.*"`, // mics never suspend
		`session.suspend-timeout-seconds = 0`,
		`node.name = "alsa_input.usb-Mic-00.mono-fallback"`, // pinned default mic
		`priority.session = 3000`,
	)
	if strings.Contains(wp, "default-policy.move") {
		t.Error("default-policy.move is the WirePlumber 0.4 name; 0.5 ignores it")
	}

	// Swapped channels: a graph on the device node, set by WirePlumber.
	graphs := home(".config/wireplumber/wireplumber.conf.d/98-device-graphs.conf")
	mustContain(t, "device graphs", graphs,
		"node.filter-graph.rules = [",
		"# Sound 'bar'\n", // quotes defused
		`matches = [{ node.name = "bluez_output.AA_BB.1" }]`,
		`matches = [{ node.name = "bluez_output.CC_DD.1" }]`,
		`inputs = [ "l:In" "r:In" ] outputs = [ "r:Out" "l:Out" ]`,
	)
	if n := strings.Count(graphs, "matches ="); n != 2 {
		t.Errorf("want a rule for each of the two swapped outputs, got %d", n)
	}
	if strings.Contains(graphs, "mbeq") {
		t.Error("the equalizer has a switch: it must not be a permanent rule")
	}
	for _, gone := range []string{".config/soundbar-setup/fx", ".config/pipewire/pipewire.conf.d/audio-filters.conf"} {
		if _, err := os.Stat(filepath.Join(homeDir, gone)); !os.IsNotExist(err) {
			t.Errorf("%s: no effect is an output of its own any more", gone)
		}
	}

	watch := home(".local/bin/audio-watch")
	mustContain(t, "audio-watch", watch,
		"EQ=(\n  \"bluez_output.AA_BB.1\"\n)",
		"KEEPALIVE=(\n  \"bluez_output.AA_BB.1\"\n)",
		"RANKED=(\n  \"bluez_output.AA_BB.1\"\n  \"bluez_output.CC_DD.1\"\n  \"alsa_output.pci-0000_0b_00.1.analog-stereo\"\n)",
		`/.local/bin/audio-eq apply "$sink"`,
	)
	if strings.Contains(watch, "audio_fx") || strings.Contains(watch, "pipewire -c") {
		t.Error("audio-watch must not run outputs of its own")
	}
	mustContain(t, "audio-watch.service", home(".config/systemd/user/audio-watch.service"),
		filepath.Join(homeDir, ".local/bin/audio-watch"), "Restart=always")

	// The equalizer: a graph audio-eq sets on the device, or clears.
	eq := home(".local/bin/audio-eq")
	mustContain(t, "audio-eq", eq,
		"OUTPUTS=(\n  \"bluez_output.AA_BB.1\"\n)", // the headset has no equalizer
		`ON='{ params = [ "audioconvert.filter-graph.8" "{ nodes = [ { type = ladspa name = eq plugin = mbeq_1197 label = mbeq control = { \"50Hz gain (low shelving)\" = -15.0 \"100Hz gain\" = -12.0`,
		`\"20000Hz gain\" = -3.0 } } ] }" ] }'`,
		`OFF='{ params = [ "audioconvert.filter-graph.8" "" ] }'`,
	)

	mustContain(t, "soundbar-status", home(".local/bin/soundbar-status"),
		`src="bluez_output.AA_BB.1.monitor"`, `/.local/bin/audio-eq status`, `"eq": %s`)

	mustContain(t, "vars.sh", staged("vars.sh"),
		`HAS_BT=true`,
		`HAS_EQ=true`,
		`STATUS_SINK='bluez_output.AA_BB.1'`,
		`STATUS_DESC='Sound "bar"'`,
		`'1. Sound "bar" (EQ + L/R swapped) — keepalive'`,
		`'2. Headset (L/R swapped)'`,
		`'3. Speakers'`,
		`DISABLED_CARDS=( 'alsa_card.usb-Webcam-02' )`,
		`DEFAULT_SOURCE='alsa_input.usb-Mic-00.mono-fallback'`,
		`DEFAULT_SOURCE_DESC='USB Mic'\''s'`,
	)
}

// TestRenderPlainOutput: no extras anywhere means no graph rule, empty
// lists in the scripts, and no Bluetooth flag.
func TestRenderPlainOutput(t *testing.T) {
	home, staged := render(t, Choices{
		Outputs:    []Output{{Sink: "alsa_output.pci.analog-stereo", Desc: "Speakers"}},
		StatusSink: "alsa_output.pci.analog-stereo",
		StatusDesc: "Speakers",
	})

	if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), ".config/wireplumber/wireplumber.conf.d/98-device-graphs.conf")); !os.IsNotExist(err) {
		t.Error("no extras: no graph rule expected")
	}
	mustContain(t, "audio-watch", home(".local/bin/audio-watch"), "EQ=(\n)", "KEEPALIVE=(\n)")
	mustContain(t, "audio-eq", home(".local/bin/audio-eq"), "OUTPUTS=(\n)")
	mustContain(t, "vars.sh", staged("vars.sh"), `HAS_BT=false`, `HAS_EQ=false`, `DISABLED_CARDS=( )`, `DEFAULT_SOURCE=''`)

	wp := home(".config/wireplumber/wireplumber.conf.d/99-device-priorities.conf")
	mustContain(t, "wireplumber", wp, `node.name = "~alsa_input.*"`, `priority.session = 2000`)
	if strings.Contains(wp, "monitor.bluez.rules") {
		t.Error("no Bluetooth rule expected")
	}
}

// TestRenderDropsStaleRules: a rule from a previous run goes away when its
// device no longer asks for it, and so does what earlier versions left.
func TestRenderDropsStaleRules(t *testing.T) {
	c := sampleChoices()
	home, _ := render(t, c)
	const conf = ".config/wireplumber/wireplumber.conf.d/98-device-graphs.conf"
	mustContain(t, "first render", home(conf), "bluez_output.CC_DD.1")
	old := filepath.Join(os.Getenv("HOME"), ".config/soundbar-setup/fx/bluez_output.CC_DD.1.conf")
	if err := os.MkdirAll(filepath.Dir(old), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(old, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	c.Outputs[1].Swap = false
	if _, err := Render(c, t.TempDir()); err != nil {
		t.Fatalf("Render: %v", err)
	}
	if strings.Contains(home(conf), "bluez_output.CC_DD.1") {
		t.Error("the headset's swap should be gone")
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("the processed output of an earlier version should be gone")
	}
}

// TestEQGraphFits: the equalizer graph has to fit what a device node accepts.
func TestEQGraphFits(t *testing.T) {
	gains := make([]string, len(eqBandLabels))
	for i := range gains {
		gains[i] = "-24.5"
	}
	bands, err := eqBands(gains)
	if err != nil {
		t.Fatal(err)
	}
	if g, err := eqGraph(bands); err != nil {
		t.Errorf("%v\n%s", err, g)
	}
	if len(swapGraph) > maxGraph {
		t.Error("the swap graph is too long")
	}
}

// TestPriorities: ranks are distinct, ordered, never in the stock range.
func TestPriorities(t *testing.T) {
	for _, count := range []int{1, 3, 12} {
		last := 1 << 30
		for rank := 0; rank < count; rank++ {
			p := outputPrio(rank, count)
			if p >= last {
				t.Errorf("count %d: rank %d (%d) should be below rank %d (%d)", count, rank, p, rank-1, last)
			}
			if p < outputPrioBase {
				t.Errorf("count %d: rank %d got %d, below the base %d", count, rank, p, outputPrioBase)
			}
			last = p
		}
	}
}

// TestChoicesRoundTrip: Render saves the answers, LoadChoices gives them back.
func TestChoicesRoundTrip(t *testing.T) {
	c := sampleChoices()
	render(t, c)

	got := LoadChoices()
	if len(got.Outputs) != len(c.Outputs) || got.StatusSink != c.StatusSink ||
		got.DefaultSource != c.DefaultSource || len(got.DisabledBT) != 1 {
		t.Fatalf("round trip lost data: %+v", got)
	}
	if o, ok := got.output("bluez_output.AA_BB.1"); !ok || !o.EQ || !o.Swap || !o.Keepalive || len(got.EQGains) != len(eqBandLabels) {
		t.Errorf("soundbar extras not restored: %+v", o)
	}

	t.Setenv("HOME", t.TempDir())
	if got := LoadChoices(); len(got.Outputs) != 0 {
		t.Errorf("no saved file should give zero Choices, got %+v", got)
	}
}

func TestCardOf(t *testing.T) {
	for _, tc := range []struct{ name, deviceName, want string }{
		{"alsa_output.usb-X.analog-stereo", "alsa_card.usb-X", "alsa_card.usb-X"},
		{"bluez_output.10_87_3E_42_41_A6.1", "", "bluez_card.10_87_3E_42_41_A6"},
		{"bluez_input.10:87:3E:42:41:A6", "", "bluez_card.10_87_3E_42_41_A6"},
		{"alsa_output.no-card", "", ""},
	} {
		if got := cardOf(tc.name, tc.deviceName); got != tc.want {
			t.Errorf("cardOf(%q, %q) = %q, want %q", tc.name, tc.deviceName, got, tc.want)
		}
	}
}

// TestGeneratedScriptsParse renders the shell scripts and confirms each is
// valid shell via `bash -n`.
func TestGeneratedScriptsParse(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	_, _ = render(t, sampleChoices())
	home := os.Getenv("HOME")

	for _, s := range []string{"audio-watch", "audio-eq", "soundbar-status"} {
		path := filepath.Join(home, ".local/bin", s)
		if out, err := exec.Command("bash", "-n", path).CombinedOutput(); err != nil {
			t.Errorf("%s failed bash -n: %v\n%s", s, err, out)
		}
		if info, err := os.Stat(path); err != nil || info.Mode().Perm()&0o100 == 0 {
			t.Errorf("%s should be executable", s)
		}
	}
}

// TestRenderRejectsBadGain: a gain that isn't a number must stop the render
// rather than reach the PipeWire config.
func TestRenderRejectsBadGain(t *testing.T) {
	if _, err := findMbeq(); err != nil {
		t.Skip("mbeq plugin not installed; skipping")
	}
	t.Setenv("HOME", t.TempDir())
	c := sampleChoices()
	c.EQGains = append([]string{"loud"}, defaultEQ[1:]...)
	if _, err := Render(c, t.TempDir()); err == nil {
		t.Error("expected an error for a non-numeric gain")
	}
}

func mustContain(t *testing.T, label, body string, subs ...string) {
	t.Helper()
	for _, s := range subs {
		if !strings.Contains(body, s) {
			t.Errorf("%s: expected to contain %q\n--- body ---\n%s", label, s, body)
		}
	}
}

// TestIsVirtual: the nodes earlier versions made are never offered as devices.
func TestIsVirtual(t *testing.T) {
	for name, want := range map[string]bool{
		"audio_fx.bluez_output.AA_BB.1":   true,
		"audio_eq.bluez_output.AA_BB.1":   true,
		"audio_swap.bluez_output.AA_BB.1": true,
		"bt_swap_sink":                    true,
		"bluez_output.AA_BB.1":            false,
		"alsa_output.usb-X.analog-stereo": false,
	} {
		if got := isVirtual(name); got != want {
			t.Errorf("isVirtual(%q) = %v, want %v", name, got, want)
		}
	}
}

// TestRenderCorrectionEQ checks the correction rule of a known model: matched
// by card name (no serial), after the swap in the same rule, and gone with the
// output.
func TestRenderCorrectionEQ(t *testing.T) {
	const (
		conf   = ".config/wireplumber/wireplumber.conf.d/98-device-graphs.conf"
		preset = ".config/soundbar-setup/eq/usb-1532-0555.txt"
		// The right driver of this headset plays louder than the left one.
		presetRight = ".config/soundbar-setup/eq/usb-1532-0555-right.txt"
	)
	c := sampleChoices()
	c.Outputs = append(c.Outputs, Output{
		Sink:     "alsa_output.usb-1532_Razer_BlackShark_V2_Pro_2.4_O001-00.analog-stereo",
		Desc:     "Razer BlackShark V2 Pro 2.4",
		Model:    "usb:1532:0555",
		CardName: "Razer BlackShark V2 Pro 2.4",
		Swap:     true,
	})
	home, staged := render(t, c)

	body := home(conf)
	mustContain(t, "correction", body,
		"node.filter-graph.rules",
		`api.alsa.card.name = "Razer BlackShark V2 Pro 2.4", media.class = "Audio/Sink"`,
		// Every channel gets the preset, then the right one (2) its own.
		`label = param_eq config = { filename = "`+filepath.Join(os.Getenv("HOME"), preset)+
			`" filename2 = "`+filepath.Join(os.Getenv("HOME"), presetRight)+`" }`,
		"; right ear -1.5 dB and 1 filter of its own",
	)
	mustContain(t, "preset", home(preset),
		"Preamp: -6.62 dB\n",
		"Filter 1: ON LSC Fc 105 Hz Gain 7 dB Q 0.7\n",
		"Filter 10: ON HSC Fc 10000 Hz Gain -0.9 dB Q 0.7\n",
	)
	if strings.Contains(home(preset), "Filter 11") {
		t.Error("the right ear's filter leaked into the shared preset")
	}
	// The right ear's file is the whole preset again, 1.5 dB lower, plus its
	// own filter: param_eq replaces a channel, it doesn't add to it.
	mustContain(t, "right preset", home(presetRight),
		"Preamp: -8.12 dB\n",
		"Filter 1: ON LSC Fc 105 Hz Gain 7 dB Q 0.7\n",
		"Filter 10: ON HSC Fc 10000 Hz Gain -0.9 dB Q 0.7\n",
		"Filter 11: ON HSC Fc 6000 Hz Gain 0.8 dB Q 0.7\n",
	)
	if swap, eq := strings.Index(body, `"r:Out" "l:Out"`), strings.Index(body, "param_eq"); swap < 0 || eq < swap {
		t.Error("want the swap, then the correction, in the Razer's rule")
	}
	if strings.Contains(body, "O001") {
		t.Error("the rule must not depend on the unit's serial")
	}
	mustContain(t, "vars.sh", staged("vars.sh"), "correction EQ: Razer BlackShark V2 Pro (2023)")

	// Same $HOME, the headset gone: its rule goes too.
	if _, err := Render(sampleChoices(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(home(conf), "Razer") {
		t.Error("a correction outlived its output")
	}
	for _, f := range []string{preset, presetRight} {
		if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), f)); !os.IsNotExist(err) {
			t.Errorf("%s outlived its output", f)
		}
	}
}

// TestUserEQDB: the user's database adds models, and a Bluetooth entry can be
// tied to the device name.
func TestUserEQDB(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := os.MkdirAll(filepath.Dir(userEQDBPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	db := `[{"id": "bluetooth:05d6:000a", "device": "Headset", "name": "Mine", "preamp": -1,
	         "filters": [{"type": "PK", "fc": 1000, "gain": 2, "q": 1}]}]`
	if err := os.WriteFile(userEQDBPath(), []byte(db), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Choices{Outputs: []Output{
		{Sink: "bluez_output.CC_DD.1", Desc: "Headset", Model: "bluetooth:05d6:000a"},
		{Sink: "bluez_output.EE_FF.1", Desc: "Same chipset", Model: "bluetooth:05d6:000a"},
	}}
	got, err := buildRules(c)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Match != `node.name = "bluez_output.CC_DD.1"` {
		t.Errorf("got %+v", got)
	}

	if err := os.WriteFile(userEQDBPath(), []byte(`[{"id": "usb:1:2", "filters": [{"type": "XX", "fc": 1, "q": 1}]}]`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := buildRules(c); err == nil {
		t.Error("an unknown filter type must be rejected")
	}
}

// TestEQChannels: an entry can correct one ear apart from the other; an entry
// without that keeps the single preset file.
func TestEQChannels(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	shared := []EQFilter{{Type: "PK", Fc: 1000, Gain: 2, Q: 1}}
	plain := EQEntry{ID: "usb:1:2", Name: "Plain", Preamp: -2, Filters: shared}
	graph, presets := correctionGraph(plain)
	if len(presets) != 1 || strings.Contains(graph, "filename1") || strings.Contains(graph, "filename2") {
		t.Errorf("plain entry: graph %s, %d presets", graph, len(presets))
	}
	if strings.Contains(correctionNote(plain), "ear") {
		t.Errorf("plain entry: note %q", correctionNote(plain))
	}

	// An empty part is no part: no file, no key.
	plain.Left = &EQChannel{}
	if _, presets := correctionGraph(plain); len(presets) != 1 {
		t.Errorf("an empty channel part wrote %d presets", len(presets))
	}

	both := plain
	both.Left = &EQChannel{Preamp: -0.3}
	both.Right = &EQChannel{Filters: []EQFilter{{Type: "LSC", Fc: 200, Gain: -1, Q: 0.7}}}
	graph, presets = correctionGraph(both)
	base := filepath.Join(eqDir(), "usb-1-2")
	want := `config = { filename = "` + base + `.txt" filename1 = "` + base + `-left.txt" filename2 = "` + base + `-right.txt" }`
	if !strings.Contains(graph, want) {
		t.Errorf("graph %s\nwant %s", graph, want)
	}
	if len(graph) > maxGraph {
		t.Errorf("graph is %d bytes", len(graph))
	}
	mustContain(t, "left", presets[base+"-left.txt"], "Preamp: -2.3 dB\n", "Filter 1: ON PK Fc 1000 Hz")
	if strings.Contains(presets[base+"-left.txt"], "Filter 2") {
		t.Error("the left ear got the right ear's filter")
	}
	mustContain(t, "right", presets[base+"-right.txt"], "Preamp: -2 dB\n", "Filter 2: ON LSC Fc 200 Hz Gain -1 dB Q 0.7\n")
	if got := len(both.Filters); got != 1 {
		t.Errorf("building the presets changed the entry: %d shared filters", got)
	}

	bad := `[{"id": "usb:1:2", "filters": [{"type": "PK", "fc": 1000, "gain": 2, "q": 1}],
	          "right": {"filters": [{"type": "PK", "fc": 0, "gain": 1, "q": 1}]}}]`
	if _, err := parseEQDB([]byte(bad), "test"); err == nil {
		t.Error("a bad filter in a channel part must be rejected")
	}
}

func TestModelID(t *testing.T) {
	cases := []struct {
		bus, vendor, product, want string
	}{
		{"usb", "0x1532", "0x0555", "usb:1532:0555"},
		{"bluetooth", "bluetooth:05d6", "0x000a", "bluetooth:05d6:000a"},
		{"bluetooth", "usb:054C", "0x9cc", "bluetooth:054c:09cc"},
		{"pci", "0x1002", "0xab40", ""},
		{"usb", "", "0x0555", ""},
	}
	for _, tc := range cases {
		got := modelID(map[string]string{
			"device.bus": tc.bus, "device.vendor.id": tc.vendor, "device.product.id": tc.product,
		})
		if got != tc.want {
			t.Errorf("modelID(%s, %s, %s) = %q, want %q", tc.bus, tc.vendor, tc.product, got, tc.want)
		}
	}
}
