package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func TestParseTone(t *testing.T) {
	good := []struct {
		in  string
		hz  int
		vol float64
	}{
		{"18-5", 18000, 5},
		{"10-5", 10000, 5},
		{" 17.5 - 2.5 ", 17500, 2.5},
		{"12,5-10", 12500, 10},
		{"0.05 100", 50, 100},
	}
	for _, c := range good {
		hz, vol, err := parseTone(c.in)
		if err != nil || hz != c.hz || vol != c.vol {
			t.Errorf("parseTone(%q) = %d, %g, %v; want %d, %g", c.in, hz, vol, err, c.hz, c.vol)
		}
	}
	// What the field holds on the way to a tone, and what makes no sound.
	for _, in := range []string{"", "1", "18-", "-5", "18-5-1", "x-5", "18-x", "23-5", "0-5", "18-0", "18-101"} {
		if _, _, err := parseTone(in); err == nil {
			t.Errorf("parseTone(%q) should fail", in)
		}
	}
}

// TestToneSpecRoundTrip: what the tuner pre-fills parses back to the same tone.
func TestToneSpecRoundTrip(t *testing.T) {
	for _, c := range []struct {
		hz  int
		vol float64
	}{{defaultToneHz, defaultToneVol}, {12500, 2.5}, {50, 100}} {
		hz, vol, err := parseTone(toneSpec(c.hz, c.vol))
		if err != nil || hz != c.hz || vol != c.vol {
			t.Errorf("%d Hz at %g %%: spec %q parsed as %d, %g, %v", c.hz, c.vol, toneSpec(c.hz, c.vol), hz, vol, err)
		}
	}
	if got := toneVolume(defaultToneVol); got != "0.05" {
		t.Errorf("default volume factor = %s, want the 0.05 audio-watch always used", got)
	}
}

// TestTunerFollowsTyping drives the live screen with stand-ins for ffmpeg and
// pw-cat: the tone follows the field, a moment after the last key, and only
// when the field holds a tone.
func TestTunerFollowsTyping(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	for _, name := range []string{"ffmpeg", "pw-cat"} {
		script := "#!/bin/sh\necho \"" + name + " $*\" >> " + log + "\nexec sleep 60\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// The device's volume, applied in software: 5 %.
	stubs := map[string]string{
		"pactl":  "#!/bin/sh\nprintf 'Sink #7\\n\\tName: test_sink\\n\\tProperties:\\n\\t\\tobject.id = \"42\"\\n'\n",
		"pw-cli": "#!/bin/sh\n[ \"$*\" = 'enum-params 42 Props' ] && printf '" + softVolumesProps + "'\n",
	}
	for name, script := range stubs {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))

	p := &tonePlayer{sink: "test_sink"}
	defer p.stop()
	var m tea.Model = newTuner(Output{Sink: "test_sink", Desc: "Test"}, p)
	var cmd tea.Cmd
	send := func(msg tea.Msg) { m, cmd = m.Update(msg) }
	typ := func(s string) {
		for _, r := range s {
			send(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		}
	}
	erase := func(n int) {
		for ; n > 0; n-- {
			send(tea.KeyMsg{Type: tea.KeyBackspace})
		}
	}
	settle := func() { send(retuneMsg(m.(tuner).seq)) } // the delay after the last key
	// The stand-ins are killed as soon as the next tone starts: each check
	// waits for the players of the current one to have logged their arguments.
	started := 0
	playing := func(hz int, vol float64, fresh bool) {
		t.Helper()
		if got := m.(tuner); got.hz != hz || got.vol != vol || !p.playing() {
			t.Fatalf("want %d Hz at %g %%, got %d Hz at %g %% (playing=%v, status %q)", hz, vol, got.hz, got.vol, p.playing(), got.status)
		}
		if fresh {
			started++
		}
		want := fmt.Sprintf("sine=frequency=%d:sample_rate=44100 -af aformat=sample_fmts=flt,volume=%s", hz, toneGain(vol, 0.05))
		for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
			b, _ := os.ReadFile(log)
			got := string(b)
			if strings.Count(got, "ffmpeg ") == started && strings.Count(got, "pw-cat ") == started &&
				strings.Contains(got, want) && strings.Contains(got, "--target test_sink") {
				return
			}
			if strings.Count(got, "ffmpeg ") > started || time.Now().After(deadline) {
				t.Fatalf("after %d tone(s), expected the players to have run with %q:\n%s", started, want, got)
			}
		}
	}

	playing(defaultToneHz, defaultToneVol, true) // it opens on the output's tone
	erase(len("18-5"))
	typ("10-5")
	send(retuneMsg(m.(tuner).seq - 1)) // the timer of an earlier key: ignored
	playing(defaultToneHz, defaultToneVol, false)
	settle()
	playing(10000, 5, true)

	typ("0") // "10-50"
	settle()
	playing(10000, 50, true)

	erase(2) // "10-": not a tone, the last one keeps playing
	settle()
	playing(10000, 50, false)
	send(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Fatal("Enter on a field that holds no tone must not leave")
	}

	typ("2") // "10-2", confirmed before the delay has passed
	send(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("Enter on a tone should leave")
	}
	playing(10000, 2, true)
	if view := m.View(); !strings.Contains(view, "playing 10 kHz at 2 %") || !strings.Contains(view, "Test") {
		t.Errorf("view doesn't show what plays:\n%s", view)
	}

	p.stop()
	if p.playing() {
		t.Error("stop left the tone playing")
	}
}

// softVolumesProps is how `pw-cli enum-params <id> Props` shows a volume
// applied in software (5 %, balance a little to the right), between other
// float arrays that must not be read for it.
const softVolumesProps = `  Object: size 1872, type Spa:Pod:Object:Param:Props (262146), id Spa:Enum:ParamId:Props (2)
    Prop: key Spa:Pod:Object:Param:Props:channelVolumes (65544), flags 00000000
      Array: child.size 4, child.type Spa:Float
        Float 0.700000
        Float 0.800000
    Prop: key Spa:Pod:Object:Param:Props:softVolumes (65552), flags 00000000
      Array: child.size 4, child.type Spa:Float
        Float 0.045000
        Float 0.050000
    Prop: key Spa:Pod:Object:Param:Props:monitorVolumes (65549), flags 00000000
      Array: child.size 4, child.type Spa:Float
        Float 1.000000
        Float 1.000000
`

func TestSoftVolume(t *testing.T) {
	if got := parseSoftVolume(softVolumesProps); got != 0.05 {
		t.Errorf("softVolumes read as %g, want the louder channel, 0.05", got)
	}
	if got := parseSoftVolume(strings.ReplaceAll(softVolumesProps, "0.0", "0,0")); got != 0.05 {
		t.Errorf("with a decimal comma: %g, want 0.05", got)
	}
	if got := parseSoftVolume("Error: unknown object\n"); got != 1 {
		t.Errorf("nothing to read: %g, want 1 (no boost)", got)
	}
	list := "Sink #3\n\tName: other_sink\n\tProperties:\n\t\tobject.id = \"40\"\n" +
		"Sink #7\n\tName: test_sink\n\tDescription: Test\n\tProperties:\n\t\tnode.name = \"test_sink\"\n\t\tobject.id = \"42\"\n"
	if got := nodeID(list, "test_sink"); got != "42" {
		t.Errorf("nodeID = %q, want 42", got)
	}
	if got := nodeID(list, "gone_sink"); got != "" {
		t.Errorf("nodeID of a missing sink = %q, want nothing", got)
	}
}

// TestToneGain: the tone reaches the device at its own volume whatever the
// device's, and never goes past full scale before that volume.
func TestToneGain(t *testing.T) {
	for _, c := range []struct {
		vol, soft float64
		want      string
	}{
		{5, 1, "0.05"},           // volume applied by the device: as tuned
		{5, 0.05, "1"},           // 37 %: 26 dB louder
		{5, 0.006859, "7.28969"}, // 19 %, the soundbar as found
		{5, 0.00625, "8"},        // about 18 %: full scale before the volume
		{5, 0.000125, "8"},       // 5 %: no further
		{50, 0.05, "8"},          // a louder tone stops sooner
		{100, 0.000125, "8"},     // the loudest one too
		{2, 0, "8"},              // a volume at zero
	} {
		if got := toneGain(c.vol, c.soft); got != c.want {
			t.Errorf("toneGain(%g %%, %g) = %s, want %s", c.vol, c.soft, got, c.want)
		}
	}
}
