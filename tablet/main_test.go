package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// What `dumpsys activity activities` printed on a Lenovo TB128FU (Android 13),
// cut down to the lines around the two that are read.
const (
	dumpHA = `  mFocusedApp=ActivityRecord{405c22c u0 io.homeassistant.companion.android/.webview.WebViewActivity} t148}
    topResumedActivity=ActivityRecord{405c22c u0 io.homeassistant.companion.android/.webview.WebViewActivity} t148}
  ResumedActivity: ActivityRecord{405c22c u0 io.homeassistant.companion.android/.webview.WebViewActivity} t148}
  mCurrentFocus=Window{9fc2ac4 u0 io.homeassistant.companion.android/io.homeassistant.companion.android.webview.WebViewActivity}
`
	dumpStream = `    topResumedActivity=ActivityRecord{81a22f1 u0 com.limelight/.Game} t152}
  mCurrentFocus=Window{3d0a1c7 u0 com.limelight/com.limelight.Game}
`
	dumpErrorBox = `    topResumedActivity=ActivityRecord{81a22f1 u0 com.limelight/.Game} t152}
  mCurrentFocus=Window{ef530f u0 Connexion interrompue}
`
	dumpPCList = `    topResumedActivity=ActivityRecord{77b1a90 u0 com.limelight/.PcView} t152}
  mCurrentFocus=Window{12ab34c u0 com.limelight/com.limelight.PcView}
`
)

func TestParseFrontAndDisplay(t *testing.T) {
	const ha = "io.homeassistant.companion.android"
	for _, c := range []struct {
		name, dump, activity, focus, display string
	}{
		{"dashboard", dumpHA, ha + "/.webview.WebViewActivity", ha + "/" + ha + ".webview.WebViewActivity", displayHA},
		{"stream", dumpStream, "com.limelight/.Game", "com.limelight/com.limelight.Game", displayMoonlight},
		// The error box sits on the stream screen: not a stream.
		{"error box", dumpErrorBox, "com.limelight/.Game", "Connexion interrompue", displayOther},
		{"Moonlight's PC list", dumpPCList, "com.limelight/.PcView", "com.limelight/com.limelight.PcView", displayOther},
		{"nothing readable", "", "", "", displayOther},
	} {
		activity, focus := parseFront(c.dump)
		if activity != c.activity || focus != c.focus {
			t.Errorf("%s: parsed %q / %q, want %q / %q", c.name, activity, focus, c.activity, c.focus)
		}
		if got := displayOf(activity, focus, ha); got != c.display {
			t.Errorf("%s: display %q, want %q", c.name, got, c.display)
		}
	}
	// No Home Assistant on the tablet: its app in front is just "other".
	if got := displayOf("io.homeassistant.companion.android/.x", "", ""); got != displayOther {
		t.Errorf("without the component, got %q", got)
	}
}

func TestParseBattery(t *testing.T) {
	b, err := parseBattery([]byte(`{"present":true,"plugged":"PLUGGED_AC","status":"NOT_CHARGING","percentage":48,"level":48}`))
	if err != nil || b.Level != 48 || !b.Plugged || b.Charging || b.Status != "NOT_CHARGING" {
		t.Errorf("protected battery on its charger: %+v, %v", b, err)
	}
	b, _ = parseBattery([]byte(`{"plugged":"UNPLUGGED","status":"DISCHARGING","percentage":77}`))
	if b.Plugged || b.Charging || b.Level != 77 {
		t.Errorf("unplugged: %+v", b)
	}
	if _, err := parseBattery([]byte(`not json`)); err == nil {
		t.Error("garbage should fail")
	}
}

// fake is a tablet whose screen the test sets, and which obeys `am start`.
type fake struct {
	dump     string
	started  []string
	obey     bool // an order changes what is in front
	frontErr error
}

func (f *fake) front() (string, string, error) {
	if f.frontErr != nil {
		return "", "", f.frontErr
	}
	a, w := parseFront(f.dump)
	return a, w, nil
}
func (f *fake) screenOn() (bool, error) { return true, nil }
func (f *fake) battery() (*battery, error) {
	return &battery{Level: 48, Plugged: true, Status: "NOT_CHARGING"}, nil
}
func (f *fake) start(args ...string) {
	line := strings.Join(args, " ")
	f.started = append(f.started, line)
	if !f.obey {
		return
	}
	if strings.Contains(line, "ShortcutTrampoline") {
		f.dump = dumpStream
	} else {
		f.dump = dumpHA
	}
}

func newServer(f *fake) *server {
	return &server{
		cfg: config{
			ID: "abc", Name: "Kitchen", Model: "Lenovo TB128FU",
			Components: []string{"homeassistant", "moonlight", "squeezelite"},
			HAPackage:  "io.homeassistant.companion.android", HAPage: "lovelace/kitchen",
			MoonlightUUID: "UUID-1", MoonlightAppID: "42",
		},
		sys: f, now: time.Now,
	}
}

func TestOrders(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	s := newServer(f)
	h := s.routes()
	call := func(method, path string) (int, string) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		return rec.Code, strings.TrimSpace(rec.Body.String())
	}

	if code, body := call("POST", "/display/moonlight"); code != 200 || body != `{"display":"moonlight"}` {
		t.Fatalf("moonlight order: %d %s", code, body)
	}
	if want := "-n com.limelight/.ShortcutTrampoline -a android.intent.action.VIEW --es UUID UUID-1 --es AppId 42"; f.started[0] != want {
		t.Errorf("moonlight started with %q", f.started[0])
	}
	if code, body := call("POST", "/display/homeassistant"); code != 200 || body != `{"display":"homeassistant"}` {
		t.Fatalf("homeassistant order: %d %s", code, body)
	}
	if want := "-a android.intent.action.VIEW -d homeassistant://navigate/lovelace/kitchen"; f.started[1] != want {
		t.Errorf("homeassistant started with %q", f.started[1])
	}

	if code, body := call("GET", "/state"); code != 200 ||
		body != `{"display":"homeassistant","screen_on":true,"battery":{"level":48,"plugged":true,"charging":false,"status":"NOT_CHARGING"}}` {
		t.Errorf("state: %d %s", code, body)
	}
	if code, body := call("GET", "/capabilities"); code != 200 ||
		body != `{"api":1,"components":["homeassistant","moonlight","squeezelite"],"id":"abc","model":"Lenovo TB128FU","name":"Kitchen"}` {
		t.Errorf("capabilities: %d %s", code, body)
	}
	if code, _ := call("POST", "/display/netflix"); code != http.StatusNotFound {
		t.Errorf("unknown display: %d", code)
	}
	if code, _ := call("GET", "/display/moonlight"); code != http.StatusMethodNotAllowed {
		t.Errorf("an order is a POST: %d", code)
	}

	// A tablet set up without Moonlight refuses the order instead of opening nothing.
	s.cfg.Components = []string{"homeassistant"}
	n := len(f.started)
	if code, body := call("POST", "/display/moonlight"); code != http.StatusNotFound || !strings.Contains(body, "not set up") || len(f.started) != n {
		t.Errorf("moonlight on a tablet without it: %d %s", code, body)
	}
}

// TestWatcher walks the watcher through what was seen on the real tablet.
func TestWatcher(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	s := newServer(f)
	backToHA := func() int {
		n := 0
		for _, line := range f.started {
			if strings.Contains(line, "homeassistant://") {
				n++
			}
		}
		return n
	}

	// Home Assistant in front: nothing to do, no need to look again soon.
	if s.tick() || backToHA() != 0 {
		t.Fatal("idle on the dashboard: the watcher should rest")
	}

	// A stream somebody started by hand on the tablet.
	f.dump = dumpStream
	if !s.tick() || backToHA() != 0 {
		t.Fatal("a stream is up: look again soon, change nothing")
	}

	// Something takes the focus for a moment (notification shade): no reaction.
	f.dump = strings.Replace(dumpStream, "com.limelight/com.limelight.Game}", "NotificationShade}", 1)
	s.tick()
	s.tick()
	f.dump = dumpStream
	s.tick()
	if backToHA() != 0 {
		t.Fatal("a passing loss of focus must not end the stream")
	}

	// Sunshine restarts on the PC: the error box comes up and stays.
	f.dump = dumpErrorBox
	for i := 0; i < focusGrace; i++ {
		if !s.tick() || backToHA() != 0 {
			t.Fatalf("look %d on the error box: too early to give up", i+1)
		}
	}
	s.tick()
	if backToHA() != 1 || s.last != displayHA {
		t.Fatalf("the error box stayed: Home Assistant should be back (orders %d, last %q)", backToHA(), s.last)
	}

	// The stream screen is left for another app: back at once.
	f.dump = dumpStream
	s.tick()
	f.dump = dumpPCList
	s.tick()
	if backToHA() != 2 {
		t.Fatalf("stream left for Moonlight's list: back at once (orders %d)", backToHA())
	}

	// An ordered stream that never comes up (PC off).
	f.obey = false
	f.dump = dumpPCList
	clock := time.Now()
	s.now = func() time.Time { return clock }
	s.last, s.pending = displayOther, clock.Add(streamGrace)
	if !s.tick() || backToHA() != 2 {
		t.Fatal("within the grace period: wait")
	}
	clock = clock.Add(streamGrace + time.Second)
	f.obey = true
	s.tick()
	if backToHA() != 3 || !s.pending.IsZero() {
		t.Fatalf("grace period over: Home Assistant back (orders %d)", backToHA())
	}

	// Moonlight's list opened by hand, no stream ordered: left alone.
	f.dump = dumpPCList
	s.tick()
	s.tick()
	if backToHA() != 3 {
		t.Fatal("no stream was up or ordered: nothing to undo")
	}
}

func TestStateWithoutPermissions(t *testing.T) {
	s := newServer(&fake{frontErr: http.ErrAbortHandler})
	if got := s.display(); got != displayUnknown {
		t.Errorf("unreadable screen: %q", got)
	}
	if s.tick() {
		t.Error("an unreadable screen is no reason to act")
	}
}

func TestAuthMiddleware(t *testing.T) {
	h := authMiddleware(newServer(&fake{dump: dumpHA}).routes(), parseAllowedIPs("192.0.2.10, 198.51.100.0/24"), "")
	for addr, want := range map[string]int{
		"192.0.2.10:5555":    http.StatusOK,
		"198.51.100.7:5555":  http.StatusOK,
		"203.0.113.1:5555":   http.StatusForbidden,
		"[2001:db8::1]:5555": http.StatusForbidden,
	} {
		req := httptest.NewRequest("GET", "/healthz", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("%s: %d, want %d", addr, rec.Code, want)
		}
	}
}
