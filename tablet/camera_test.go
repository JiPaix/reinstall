package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeLens is LensCast as seen on the kitchen tablet (2026-11-15): a stream
// (re)started while the app is on screen gets the camera, one started from the
// background never does.
type fakeLens struct {
	tablet   *fake
	up       bool // the web server answers
	hasCam   bool // the streaming service got the camera
	broken   bool // the camera HAL is lost: nothing brings frames back
	selected int  // 0 = back, 1 = front, as on the TB128FU
	restarts int
	lensSets int
}

func (l *fakeLens) frames() (bool, error) {
	if !l.up {
		return false, errAppDown
	}
	return l.hasCam && !l.broken, nil
}

func (l *fakeLens) restartStream() error {
	l.restarts++
	l.hasCam = strings.HasPrefix(firstWord(l.tablet.dump), lenscastPackage+"/")
	return nil
}

func (l *fakeLens) lensOK(front bool) (bool, error) { return (l.selected == 1) == front, nil }

func (l *fakeLens) selectLens(front bool) error {
	if ok, _ := l.lensOK(front); !ok {
		l.lensSets++
		l.selected = 1 - l.selected
	}
	return nil
}

var errAppDown = errors.New("connection refused")

func firstWord(dump string) string {
	activity, _ := parseFront(dump)
	return activity
}

// cameraServer is the kitchen tablet with the camera component, on a clock
// that only moves when the server sleeps.
func cameraServer(f *fake, l *fakeLens) *server {
	s := newServer(f)
	s.cfg.Components = append(s.cfg.Components, componentCamera)
	s.cfg.CameraFront = true
	l.tablet = f
	s.lc = l
	clock := time.Date(2026, 11, 15, 0, 37, 0, 0, time.UTC)
	s.now = func() time.Time { return clock }
	s.sleep = func(d time.Duration) { clock = clock.Add(d) }
	return s
}

func count(lines []string, part string) int {
	n := 0
	for _, line := range lines {
		if strings.Contains(line, part) {
			n++
		}
	}
	return n
}

// After a boot: the server answers, no frame, back lens. Two looks without a
// frame, then LensCast on screen, the stream restarted there, the front lens,
// and the dashboard back.
func TestCameraAfterBoot(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	l := &fakeLens{up: true}
	s := cameraServer(f, l)

	s.checkCamera()
	if got := s.cameraStatus(); got != cameraNoFrames || count(f.started, lenscastActivity) != 0 {
		t.Fatalf("one look without a frame: %s, started %v", got, f.started)
	}
	s.checkCamera()
	if got := s.cameraStatus(); got != cameraOK {
		t.Fatalf("after the recovery: %s", got)
	}
	if l.restarts != 1 || l.selected != 1 || count(f.started, lenscastActivity) != 1 {
		t.Errorf("restarts %d, lens %d, LensCast started %d time(s)", l.restarts, l.selected, count(f.started, lenscastActivity))
	}
	if !strings.Contains(f.started[len(f.started)-1], "homeassistant://navigate/lovelace/kitchen") || s.display() != displayHA {
		t.Errorf("the dashboard should be back: %v", f.started)
	}

	// From then on a stream restart from the background keeps the camera.
	s.checkCamera()
	if l.restarts != 1 || s.cameraStatus() != cameraOK {
		t.Errorf("a healthy camera was touched: %d restarts", l.restarts)
	}
}

// LensCast not running at all: the same recovery starts it.
func TestCameraAppDown(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	l := &fakeLens{}
	s := cameraServer(f, l)
	// What `am start` does to a LensCast that wasn't running: its web server
	// comes up (the fake's start can't, so the camera interface stands in).
	s.checkCamera()
	if got := s.cameraStatus(); got != cameraAppDown {
		t.Fatalf("got %s", got)
	}
	l.up = true // started by the next recovery's am start
	s.checkCamera()
	if got := s.cameraStatus(); got != cameraOK {
		t.Errorf("got %s", got)
	}
}

// A lost camera HAL: the recovery can't help. It is tried again after 10 min,
// then 20, and LensCast isn't flashed on screen at every look meanwhile.
func TestCameraBackoff(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	l := &fakeLens{up: true, broken: true}
	s := cameraServer(f, l)

	s.checkCamera()
	s.checkCamera()
	if got := s.cameraStatus(); got != cameraFailed || l.restarts != 1 {
		t.Fatalf("got %s after %d restarts", got, l.restarts)
	}
	for range 8 { // 8 min of looks
		s.checkCamera()
		s.pause(cameraEvery)
	}
	if l.restarts != 1 || s.cameraStatus() != cameraFailed {
		t.Errorf("retried within the backoff: %d restarts, %s", l.restarts, s.cameraStatus())
	}
	for range 3 {
		s.checkCamera()
		s.pause(cameraEvery)
	}
	if l.restarts != 2 || s.cam.backoff != 20*time.Minute {
		t.Errorf("after 10 min: %d restarts, backoff %s", l.restarts, s.cam.backoff)
	}
	if s.display() != displayHA {
		t.Error("the dashboard should be back after each try")
	}

	// Rebooted: frames again, the backoff is forgotten.
	l.broken = false
	s.checkCamera()
	if s.cameraStatus() != cameraOK || s.cam.backoff != 0 || s.cam.fails != 0 {
		t.Errorf("after a fix: %s, backoff %s, fails %d", s.cameraStatus(), s.cam.backoff, s.cam.fails)
	}
}

// A Moonlight stream on screen isn't cut for the camera.
func TestCameraWaitsForStream(t *testing.T) {
	f := &fake{dump: dumpStream, obey: true}
	l := &fakeLens{up: true}
	s := cameraServer(f, l)
	s.checkCamera()
	s.checkCamera()
	if count(f.started, lenscastActivity) != 0 || f.dump != dumpStream {
		t.Errorf("the stream was interrupted: %v", f.started)
	}
}

// Streaming, but on the back camera (LensCast restarted by itself): the lens
// is switched without bringing anything on screen.
func TestCameraWrongLens(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	l := &fakeLens{up: true, hasCam: true}
	s := cameraServer(f, l)
	s.checkCamera()
	if l.selected != 1 || l.lensSets != 1 || len(f.started) != 0 {
		t.Errorf("lens %d after %d switch(es), started %v", l.selected, l.lensSets, f.started)
	}
}

func TestCameraInState(t *testing.T) {
	f := &fake{dump: dumpHA, obey: true}
	s := cameraServer(f, &fakeLens{up: true, hasCam: true, selected: 1})
	if st := s.state(); st.Camera != "unknown" {
		t.Errorf("before the first look: %q", st.Camera)
	}
	s.checkCamera()
	b, _ := json.Marshal(s.state())
	if !strings.Contains(string(b), `"camera":"ok"`) {
		t.Errorf("state: %s", b)
	}
	// Without the component the field isn't there at all.
	b, _ = json.Marshal(newServer(f).state())
	if strings.Contains(string(b), "camera") {
		t.Errorf("state without a camera: %s", b)
	}
}

// The HTTP side, against a LensCast that checks what the real one checks.
func TestLensCastClient(t *testing.T) {
	selected, loggedIn, loggedOut := 0, false, false
	frame := false
	mux := http.NewServeMux()
	bearer := func(r *http.Request) bool { return r.Header.Get("Authorization") == "Bearer tok" }
	mux.HandleFunc("GET /snapshot", func(w http.ResponseWriter, r *http.Request) {
		if !bearer(r) {
			w.WriteHeader(401)
			return
		}
		if !frame {
			w.WriteHeader(404)
			w.Write([]byte("No frame available"))
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write([]byte{0xff, 0xd8})
	})
	mux.HandleFunc("GET /api/camera/lenses", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"lenses":[{"index":0,"label":"Wide","isFront":false},{"index":1,"label":"Front","isFront":true}],"selectedIndex":` +
			map[int]string{0: "0", 1: "1"}[selected] + `}`))
	})
	mux.HandleFunc("POST /api/stream/{op}", func(w http.ResponseWriter, r *http.Request) {
		if !bearer(r) || r.Header.Get("X-Requested-With") == "" {
			w.WriteHeader(403)
			return
		}
		frame = r.PathValue("op") == "start"
	})
	mux.HandleFunc("POST /api/auth/login", func(w http.ResponseWriter, r *http.Request) {
		var c map[string]string
		json.NewDecoder(r.Body).Decode(&c)
		if c["username"] != "homeassistant" || c["password"] != "pw" {
			w.WriteHeader(401)
			return
		}
		loggedIn = true
		http.SetCookie(w, &http.Cookie{Name: "session", Value: "s1", Path: "/"})
	})
	mux.HandleFunc("POST /api/auth/logout", func(w http.ResponseWriter, r *http.Request) { loggedOut = true })
	mux.HandleFunc("POST /api/camera/lens", func(w http.ResponseWriter, r *http.Request) {
		// A token present takes the token path, which can't choose a lens.
		if r.Header.Get("Authorization") != "" {
			w.WriteHeader(403)
			return
		}
		if c, err := r.Cookie("session"); err != nil || c.Value != "s1" || r.Header.Get("X-Requested-With") == "" {
			w.WriteHeader(401)
			return
		}
		var b map[string]int
		json.NewDecoder(r.Body).Decode(&b)
		selected = b["index"]
	})
	ts := httptest.NewServer(mux)
	defer ts.Close()

	l := &lenscast{base: ts.URL, user: "homeassistant", password: "pw", token: "tok", client: ts.Client()}
	if ok, err := l.frames(); ok || err != nil {
		t.Errorf("no frame yet: %v %v", ok, err)
	}
	if err := l.restartStream(); err != nil {
		t.Fatal(err)
	}
	if ok, err := l.frames(); !ok || err != nil {
		t.Errorf("after a start: %v %v", ok, err)
	}
	if ok, _ := l.lensOK(true); ok {
		t.Error("the back lens isn't the front one")
	}
	if err := l.selectLens(true); err != nil || selected != 1 || !loggedIn || !loggedOut {
		t.Errorf("select: %v, selected %d, login %v, logout %v", err, selected, loggedIn, loggedOut)
	}
	if ok, _ := l.lensOK(true); !ok {
		t.Error("front lens now")
	}
	ts.Close()
	if _, err := l.frames(); err == nil {
		t.Error("LensCast gone should be an error")
	}
}
