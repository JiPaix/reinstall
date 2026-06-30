package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestRenderProducesExpectedBodies renders the templates from a representative
// set of choices and checks each generated file for its key substitutions.
func TestRenderProducesExpectedBodies(t *testing.T) {
	if _, err := findMbeq(); err != nil {
		t.Skip("mbeq plugin not installed on this machine; skipping render test")
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	staging := t.TempDir()

	c := Choices{
		PrimarySink:   "bluez_output.AA_BB.1",
		PrimaryDesc:   "Soundbar",
		Priorities:    []string{"alsa_output.pci-0000_0b_00.1.analog-stereo", "bluez_output.CC_DD.1"},
		DisabledBT:    []string{"bluez_output.EE_FF.1"},
		DisabledCards: []string{"alsa_card.usb-Webcam-02"},
		EQGains:       defaultEQ,
		IsBT:          true,
		BTInputName:   "Soundbar (AVRCP)",
	}

	written, err := Render(c, staging)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if len(written) == 0 {
		t.Fatal("Render returned no files")
	}

	read := func(rel string) string {
		b, err := os.ReadFile(filepath.Join(home, rel))
		if err != nil {
			t.Fatalf("read %s: %v", rel, err)
		}
		return string(b)
	}

	wp := read(".config/wireplumber/wireplumber.conf.d/99-device-priorities.conf")
	mustContain(t, "wireplumber", wp,
		`monitor.bluez.rules = [`,
		`node.name = "bluez_output.CC_DD.1"`, // a fallback BT priority
		`priority.session = 1500`,            // index 1 → 2000 - 500
		`node.name = "bluez_output.EE_FF.1"`, // disabled BT
		`device.disabled = true`,
		`monitor.alsa.rules = [`,
		`node.name = "alsa_output.pci-0000_0b_00.1.analog-stereo"`,
		`priority.session = 2000`, // index 0
		`device.name = "alsa_card.usb-Webcam-02"`,
		`device.profile = "off"`,
	)

	eq := read(".config/pipewire/pipewire.conf.d/soundbar-eq.conf")
	mustContain(t, "eq", eq,
		"label  = mbeq",
		`"50Hz gain (low shelving)" = -15`,
		`"20000Hz gain" = -3`,
		`target.object     = "bluez_output.AA_BB.1"`,
	)
	if strings.Count(eq, `"50Hz gain (low shelving)" = -15`) != 2 {
		t.Error("EQ band should appear in both eq_l and eq_r nodes")
	}

	status := read(".local/bin/soundbar-status")
	mustContain(t, "status", status, `src="bluez_output.AA_BB.1.monitor"`)

	keep := read(".config/systemd/user/soundbar-keepalive.service")
	mustContain(t, "keepalive.service", keep, `PULSE_SINK=bluez_output.AA_BB.1`)

	udevBody, err := os.ReadFile(filepath.Join(staging, "99-soundbar-keepalive.rules"))
	if err != nil {
		t.Fatalf("read staged udev: %v", err)
	}
	mustContain(t, "udev", string(udevBody), `ATTRS{name}=="Soundbar (AVRCP)"`)

	vars, err := os.ReadFile(filepath.Join(staging, "vars.sh"))
	if err != nil {
		t.Fatalf("read vars.sh: %v", err)
	}
	mustContain(t, "vars.sh", string(vars), `IS_BT=true`, `alsa_card.usb-Webcam-02`)
}

// TestRenderNonBTOmitsUdev: a non-Bluetooth primary produces no udev rule.
func TestRenderNonBTOmitsUdev(t *testing.T) {
	if _, err := findMbeq(); err != nil {
		t.Skip("mbeq plugin not installed; skipping")
	}
	t.Setenv("HOME", t.TempDir())
	staging := t.TempDir()

	_, err := Render(Choices{
		PrimarySink: "alsa_output.pci.analog-stereo",
		EQGains:     defaultEQ,
		IsBT:        false,
	}, staging)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if _, err := os.Stat(filepath.Join(staging, "99-soundbar-keepalive.rules")); !os.IsNotExist(err) {
		t.Error("non-BT primary should not stage a udev rule")
	}
	vars, _ := os.ReadFile(filepath.Join(staging, "vars.sh"))
	mustContain(t, "vars.sh", string(vars), `IS_BT=false`, `UDEV_RULE_FILE=""`)
}

// TestGeneratedScriptsParse renders the three shell scripts and confirms each
// is valid shell via `bash -n`.
func TestGeneratedScriptsParse(t *testing.T) {
	if _, err := findMbeq(); err != nil {
		t.Skip("mbeq plugin not installed; skipping")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := Render(Choices{
		PrimarySink: "bluez_output.AA_BB.1", EQGains: defaultEQ, IsBT: false,
	}, t.TempDir()); err != nil {
		t.Fatalf("Render: %v", err)
	}
	for _, name := range []string{"soundbar-loopback", "soundbar-keepalive", "soundbar-status"} {
		path := filepath.Join(home, ".local/bin", name)
		if out, err := exec.Command("bash", "-n", path).CombinedOutput(); err != nil {
			t.Errorf("bash -n %s failed: %v\n%s", name, err, out)
		}
	}
}

func mustContain(t *testing.T, label, body string, subs ...string) {
	t.Helper()
	for _, s := range subs {
		if !strings.Contains(body, s) {
			t.Errorf("%s output missing %q\n--- got ---\n%s", label, s, body)
		}
	}
}
