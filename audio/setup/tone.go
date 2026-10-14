package main

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

// The keepalive tone of an output that was never tuned: high enough not to be
// heard, loud enough for most devices to count it as sound.
const (
	defaultToneHz  = 18000
	defaultToneVol = 5.0

	// The tone is generated at 44.1 kHz: nothing above half of that exists.
	toneRate  = 44100
	minToneHz = 20
	maxToneHz = 22000
)

func (o Output) toneHz() int {
	if o.ToneHz == 0 {
		return defaultToneHz
	}
	return o.ToneHz
}

func (o Output) toneVol() float64 {
	if o.ToneVol == 0 {
		return defaultToneVol
	}
	return o.ToneVol
}

// toneVolume turns a volume in percent into ffmpeg's volume factor. ffmpeg's
// sine source peaks at 1/8 of full scale, so 100 % is still a quiet -18 dBFS:
// a typo can't blast the device.
func toneVolume(percent float64) string {
	return strconv.FormatFloat(percent/100, 'f', -1, 64)
}

// The tone's volume is what reaches the device, whatever the output's own
// volume. Most Bluetooth speakers leave that volume to the PC (no absolute
// volume): it scales every sample played there, the tone's too — at 19 % a
// tone at 5 % reached the soundbar at -90 dBFS, and it fell asleep. So the
// tone is played louder by the inverse of the volume applied to the samples,
// but never past full scale before it: when the volume is raised in one go the
// tone is too strong until it is replayed, and a clipped tone can be heard.
// Below that point (about 18 % for a tone at 5 %) the tone weakens with the
// volume. audio-watch does the same, and replays the tone when the volume
// moves.

// toneGain is ffmpeg's volume factor for a tone of vol percent on a device
// whose samples are scaled by soft (1 when the device applies its volume).
func toneGain(vol, soft float64) string {
	f := vol / 100
	if floor := f / 8; soft < floor { // where the boosted sine reaches full scale
		soft = floor
	}
	return strconv.FormatFloat(f/soft, 'g', 6, 64)
}

// softVolume is the volume applied to a sink's samples, read on its node; 1
// when it can't be read, which boosts nothing.
func softVolume(sink string) float64 {
	run := func(name string, args ...string) string {
		cmd := exec.Command(name, args...)
		cmd.Env = append(os.Environ(), "LC_ALL=C") // a decimal point, untranslated keys
		out, _ := cmd.Output()
		return string(out)
	}
	id := nodeID(run("pactl", "list", "sinks"), sink)
	if id == "" {
		return 1
	}
	return parseSoftVolume(run("pw-cli", "enum-params", id, "Props"))
}

// nodeID finds a sink's object.id in `pactl list sinks`.
func nodeID(list, sink string) string {
	on := false
	for _, line := range strings.Split(list, "\n") {
		f := strings.Fields(line)
		switch {
		case len(f) == 2 && f[0] == "Name:":
			on = f[1] == sink
		case on && len(f) == 3 && f[0] == "object.id":
			return strings.Trim(f[2], `"`)
		}
	}
	return ""
}

// parseSoftVolume reads softVolumes in `pw-cli enum-params <id> Props`: the
// louder channel, 1 when there is none.
func parseSoftVolume(props string) float64 {
	in, loudest := false, 0.0
	for _, line := range strings.Split(props, "\n") {
		switch f := strings.Fields(line); {
		case strings.Contains(line, "Props:softVolumes"):
			in = true
		case in && strings.Contains(line, "Prop:"):
			in = false
		case in && len(f) == 2 && f[0] == "Float":
			if v, err := strconv.ParseFloat(strings.ReplaceAll(f[1], ",", "."), 64); err == nil && v > loudest {
				loudest = v
			}
		}
	}
	if loudest == 0 {
		return 1
	}
	return loudest
}

// toneSpec is the tone as it is typed: "<kHz>-<percent>", e.g. "18-5".
func toneSpec(hz int, vol float64) string {
	return strconv.FormatFloat(float64(hz)/1000, 'f', -1, 64) + "-" + strconv.FormatFloat(vol, 'f', -1, 64)
}

func toneLabel(hz int, vol float64) string {
	return fmt.Sprintf("%s kHz at %s %%",
		strconv.FormatFloat(float64(hz)/1000, 'f', -1, 64), strconv.FormatFloat(vol, 'f', -1, 64))
}

// parseTone reads "<kHz>-<percent>" ("18-5", "17.5 3", "12,5-10").
func parseTone(s string) (hz int, vol float64, err error) {
	parts := strings.FieldsFunc(strings.ReplaceAll(s, ",", "."), func(r rune) bool {
		return r == '-' || r == ' ' || r == '/'
	})
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("type the frequency in kHz, a dash, the volume in %% — e.g. 18-5")
	}
	khz, err := strconv.ParseFloat(parts[0], 64)
	if err != nil {
		return 0, 0, fmt.Errorf("%q is not a frequency in kHz", parts[0])
	}
	vol, err = strconv.ParseFloat(parts[1], 64)
	if err != nil {
		return 0, 0, fmt.Errorf("%q is not a volume in %%", parts[1])
	}
	hz = int(math.Round(khz * 1000))
	if hz < minToneHz || hz > maxToneHz {
		return 0, 0, fmt.Errorf("frequency out of range: %g to %g kHz", float64(minToneHz)/1000, float64(maxToneHz)/1000)
	}
	if vol <= 0 || vol > 100 {
		return 0, 0, fmt.Errorf("volume out of range: above 0, up to 100 %%")
	}
	return hz, vol, nil
}

// tonePlayer plays the keepalive tone on one output, the way audio-watch does
// (ffmpeg piped into pw-cat), for as long as the wizard lets it.
type tonePlayer struct {
	sink string
	quit chan struct{} // closed to end the tone that is playing
	done chan struct{}
}

func (p *tonePlayer) playing() bool { return p.quit != nil }

func (p *tonePlayer) play(hz int, vol float64) error {
	p.stop()
	started := make(chan error, 1)
	quit, done := make(chan struct{}), make(chan struct{})
	go func() {
		// The wizard can leave through os.Exit at any prompt, and the tone must
		// not outlive it: hence Pdeathsig. That signal follows the thread that
		// forked, not the process, so this goroutine keeps its thread until the
		// tone is stopped.
		runtime.LockOSThread()
		defer close(done)
		ff, pw, err := startTone(p.sink, hz, vol)
		started <- err
		if err != nil {
			return
		}
		<-quit
		for _, c := range []*exec.Cmd{ff, pw} {
			c.Process.Kill()
			c.Wait()
		}
	}()
	if err := <-started; err != nil {
		return err
	}
	p.quit, p.done = quit, done
	return nil
}

func (p *tonePlayer) stop() {
	if p.quit == nil {
		return
	}
	close(p.quit)
	<-p.done
	p.quit, p.done = nil, nil
}

// startTone sizes the tone for the device's volume as it is now: the tuner
// replays it at every edit, not when the volume moves. Float, because at its
// most boosted the sine peaks at exactly full scale, a step past what s16 holds.
func startTone(sink string, hz int, vol float64) (ff, pw *exec.Cmd, err error) {
	ff = exec.Command("ffmpeg", "-nostdin", "-loglevel", "fatal",
		"-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=%d:sample_rate=%d", hz, toneRate),
		"-af", "aformat=sample_fmts=flt,volume="+toneGain(vol, softVolume(sink)), "-f", "f32le", "-")
	pw = exec.Command("pw-cat", "--playback", "--raw", "--format", "f32",
		"--rate", strconv.Itoa(toneRate), "--channels", "1", "--target", sink,
		"-P", "{ application.name = audio-keepalive node.name = audio-keepalive-tuning node.dont-reconnect = true node.dont-move = true }", "-")
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	defer r.Close()
	defer w.Close()
	ff.Stdout, pw.Stdin = w, r
	for _, c := range []*exec.Cmd{ff, pw} {
		c.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	}
	if err := pw.Start(); err != nil {
		return nil, nil, fmt.Errorf("pw-cat: %w", err)
	}
	if err := ff.Start(); err != nil {
		pw.Process.Kill()
		pw.Wait()
		return nil, nil, fmt.Errorf("ffmpeg: %w", err)
	}
	return ff, pw, nil
}

// tuneKeepalive lets each output with a keepalive have its tone tuned by ear.
// An output that isn't connected keeps the tone it had.
func tuneKeepalive(w *wizard, outputs []Output, absent map[string]bool) {
	for i, o := range outputs {
		if !o.Keepalive || absent[o.Sink] {
			continue
		}
		tune := false
		ask(huh.NewConfirm().
			Title(w.title("Keepalive tone — " + o.Desc)).
			Description("Currently " + toneLabel(o.toneHz(), o.toneVol()) + ".\n" +
				"Try other frequencies and volumes, with the tone playing on the device?\n" +
				"Worth it when the device still powers off, or when you can hear the tone.").
			Affirmative("Tune it").Negative("Keep it").Value(&tune))
		if !tune {
			continue
		}
		hz, vol := runTuner(o)
		outputs[i].ToneHz, outputs[i].ToneVol = hz, vol
	}
}

const tunerHelp = "Frequency in kHz, a dash, volume in % — e.g. 18-5.\n" +
	"The device still powers off: lower the frequency or raise the volume.\n" +
	"You can hear the tone: raise the frequency or lower the volume."

// runTuner plays the output's tone and returns the one the user settles on.
func runTuner(o Output) (int, float64) {
	p := &tonePlayer{sink: o.Sink}
	defer p.stop()
	if accessible {
		return tuneByLine(o, p)
	}
	m := newTuner(o, p)
	out, err := tea.NewProgram(m).Run()
	if err != nil {
		fatalf("cancelled: %v", err)
	}
	t := out.(tuner)
	if t.aborted {
		p.stop()
		fatalf("cancelled: user aborted")
	}
	return t.hz, t.vol
}

// tuneByLine is the tuner without a TUI: one tone per line, an empty line
// keeps the one that is playing.
func tuneByLine(o Output, p *tonePlayer) (int, float64) {
	hz, vol := o.toneHz(), o.toneVol()
	note := ""
	for {
		if !p.playing() {
			if err := p.play(hz, vol); err != nil {
				note = "could not play the tone: " + err.Error() + "\n"
			}
		}
		var v string
		ask(huh.NewInput().
			Title(fmt.Sprintf("%sPlaying %s on %s. Another one (e.g. 18-5), or nothing to keep it", note, toneLabel(hz, vol), o.Desc)).
			Value(&v))
		if strings.TrimSpace(v) == "" {
			return hz, vol
		}
		h, vl, err := parseTone(v)
		if err != nil {
			note = err.Error() + "\n"
			continue
		}
		if h != hz || vl != vol {
			p.stop()
		}
		hz, vol, note = h, vl, ""
	}
}

// tuner is the live screen: the tone follows what is typed, a moment after the
// last key so that "10-50" never plays as "10-5" on the way.
type tuner struct {
	desc    string
	in      textinput.Model
	player  *tonePlayer
	seq     int // bumped at every edit: only the last one retunes
	hz      int // what is playing, and what Enter returns
	vol     float64
	status  string
	aborted bool
}

type retuneMsg int

const retuneDelay = 400 * time.Millisecond

func newTuner(o Output, p *tonePlayer) tuner {
	in := textinput.New()
	in.Prompt = "> "
	in.CharLimit = 16
	in.SetValue(toneSpec(o.toneHz(), o.toneVol()))
	in.CursorEnd()
	in.Focus()
	t := tuner{desc: o.Desc, in: in, player: p, hz: o.toneHz(), vol: o.toneVol()}
	t.retune()
	return t
}

// retune plays what the field holds, if it is a tone.
func (t *tuner) retune() {
	hz, vol, err := parseTone(t.in.Value())
	if err != nil {
		t.status = "… " + err.Error() + " (still playing " + toneLabel(t.hz, t.vol) + ")"
		return
	}
	if !t.player.playing() || hz != t.hz || vol != t.vol {
		if err := t.player.play(hz, vol); err != nil {
			t.status = "✗ could not play the tone: " + err.Error()
			return
		}
	}
	t.hz, t.vol = hz, vol
	t.status = "♪ playing " + toneLabel(hz, vol)
}

func (t tuner) Init() tea.Cmd { return textinput.Blink }

func (t tuner) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case retuneMsg:
		if int(msg) == t.seq {
			t.retune()
		}
		return t, nil
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyCtrlC:
			t.aborted = true
			return t, tea.Quit
		case tea.KeyEnter:
			// What was typed last may not have played yet.
			t.seq++
			t.retune()
			if _, _, err := parseTone(t.in.Value()); err != nil {
				return t, nil
			}
			return t, tea.Quit
		}
	}
	before := t.in.Value()
	var cmd tea.Cmd
	t.in, cmd = t.in.Update(msg)
	if t.in.Value() == before {
		return t, cmd
	}
	t.seq++
	seq := t.seq
	return t, tea.Batch(cmd, tea.Tick(retuneDelay, func(time.Time) tea.Msg { return retuneMsg(seq) }))
}

func (t tuner) View() string {
	title := lipgloss.NewStyle().Bold(true).Render("Keepalive tone — " + t.desc)
	faint := lipgloss.NewStyle().Faint(true)
	return title + "\n" + faint.Render(tunerHelp) + "\n\n" +
		t.in.View() + "\n" + t.status + "\n\n" +
		faint.Render("the tone follows what you type · enter keeps it") + "\n"
}
