package main

// The camera component: LensCast (com.raulshma.lenscast, F-Droid) streams the
// tablet's camera over RTSP, and this keeps it streaming.
//
// Android gives LensCast's streaming service the camera only if the service
// was (re)started while the app was on screen. At boot its BootCompletedReceiver
// starts the service from the background: the RTSP server then answers, but no
// frame ever comes out. And the lens is not saved: every start of the app
// opens the back camera. So when no frame comes back, the keeper brings
// LensCast to the front, restarts the stream there, picks the lens, then gives
// the screen back. Once started that way, the service keeps the camera across
// stream restarts from the background (LensCast's own watchdog), until the app
// process ends (reboot, low-memory kill).
//
// The health check is /snapshot: the RTSP port answering proves nothing, and
// LensCast's /api/status says "Ready" with the camera gone.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"os"
	"strings"
	"time"
)

const (
	componentCamera = "camera"

	lenscastPackage  = "com.raulshma.lenscast"
	lenscastActivity = lenscastPackage + "/.MainActivity"
	lenscastURL      = "http://127.0.0.1:8080"

	// At boot the Home Assistant session's own boot script opens the dashboard:
	// let it, rather than race it for the screen.
	cameraBootDelay = 90 * time.Second
	cameraEvery     = time.Minute
	// After a recovery that didn't bring frames back (the camera HAL can stay
	// lost until LensCast's process restarts, which Termux can't do), wait
	// before the next try: each one shows LensCast on screen for ~20 s.
	cameraRetryMin = 10 * time.Minute
	cameraRetryMax = 2 * time.Hour
)

// What GET /state reports under "camera".
const (
	cameraOK         = "ok"         // frames come out
	cameraNoFrames   = "no_frames"  // LensCast answers, no frame
	cameraAppDown    = "app_down"   // LensCast doesn't answer
	cameraRecovering = "recovering" // LensCast on screen, being restarted
	cameraFailed     = "failed"     // a recovery didn't help: retried later; a reboot fixes it
)

// camera is what the keeper asks of LensCast, so tests can stand in for it.
type camera interface {
	frames() (bool, error) // false: no frame; error: LensCast doesn't answer
	restartStream() error  // stop then start the stream
	lensOK(front bool) (bool, error)
	selectLens(front bool) error
}

// cameraState is the keeper's own, under its own lock: /state must not wait
// for a recovery that holds the screen lock for ~20 s.
type cameraState struct {
	state   string
	fails   int           // checks in a row without frames
	next    time.Time     // no recovery before then
	backoff time.Duration // the wait after the last failed recovery
}

func (s *server) cameraStatus() string {
	s.camMu.Lock()
	defer s.camMu.Unlock()
	if s.cam.state == "" {
		return "unknown"
	}
	return s.cam.state
}

func (s *server) setCamera(state string) {
	s.camMu.Lock()
	defer s.camMu.Unlock()
	if s.cam.state != state {
		log.Printf("camera: %s", state)
	}
	s.cam.state = state
}

func (s *server) pause(d time.Duration) {
	if s.sleep != nil {
		s.sleep(d)
	} else {
		time.Sleep(d)
	}
}

// keepCamera runs for as long as the server does.
func (s *server) keepCamera() {
	if !s.cfg.has(componentCamera) || s.lc == nil {
		return
	}
	s.pause(cameraBootDelay)
	for {
		s.checkCamera()
		s.pause(cameraEvery)
	}
}

// checkCamera is one look at the camera, and a recovery when two looks in a
// row (a minute apart) got no frame.
func (s *server) checkCamera() {
	ok, err := s.lc.frames()
	if ok {
		s.camMu.Lock()
		s.cam.fails, s.cam.backoff, s.cam.next = 0, 0, time.Time{}
		s.camMu.Unlock()
		s.setCamera(cameraOK)
		// Streaming, but maybe on the other lens (LensCast restarted by itself).
		if right, err := s.lc.lensOK(s.cfg.CameraFront); err == nil && !right {
			log.Printf("camera: wrong lens, switching")
			if err := s.lc.selectLens(s.cfg.CameraFront); err != nil {
				log.Printf("camera: lens: %v", err)
			}
		}
		return
	}
	if err != nil {
		s.setCamera(cameraAppDown)
	} else if s.cameraStatus() != cameraFailed {
		s.setCamera(cameraNoFrames)
	}
	s.camMu.Lock()
	s.cam.fails++
	due := s.cam.fails >= 2 && !s.now().Before(s.cam.next)
	s.camMu.Unlock()
	if due {
		s.recoverCamera()
	}
}

// recoverCamera restarts LensCast's stream with the app on screen, then gives
// the screen back. It holds the screen lock: orders wait meanwhile.
func (s *server) recoverCamera() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if got := s.display(); got == displayMoonlight {
		log.Printf("camera: a stream is on screen, the recovery waits")
		return
	}
	s.setCamera(cameraRecovering)
	s.sys.start("-n", lenscastActivity)
	s.waitUntil(10*time.Second, func() bool {
		activity, _, err := s.sys.front()
		return err == nil && strings.HasPrefix(activity, lenscastPackage+"/")
	})
	// A LensCast that wasn't running needs a moment for its web server.
	s.waitUntil(20*time.Second, func() bool {
		_, err := s.lc.frames()
		return err == nil
	})
	if err := s.lc.restartStream(); err != nil {
		log.Printf("camera: restarting the stream: %v", err)
	}
	s.waitUntil(15*time.Second, func() bool {
		ok, _ := s.lc.frames()
		return ok
	})
	if err := s.lc.selectLens(s.cfg.CameraFront); err != nil {
		log.Printf("camera: lens: %v", err)
	}

	// The screen goes back to Home Assistant, or to the home screen.
	if s.cfg.has(displayHA) {
		s.showHA()
		s.last = s.waitFor(displayHA, 6*time.Second)
	} else {
		s.sys.start("-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME")
		s.last = displayOther
	}

	// The proof: frames with LensCast in the background.
	s.pause(5 * time.Second)
	ok, _ := s.lc.frames()
	s.camMu.Lock()
	if ok {
		s.cam.fails, s.cam.backoff, s.cam.next = 0, 0, time.Time{}
	} else {
		s.cam.backoff = min(max(2*s.cam.backoff, cameraRetryMin), cameraRetryMax)
		s.cam.next = s.now().Add(s.cam.backoff)
	}
	backoff := s.cam.backoff
	s.camMu.Unlock()
	if ok {
		s.setCamera(cameraOK)
	} else {
		s.setCamera(cameraFailed)
		log.Printf("camera: still no frame, next try in %s", backoff)
	}
}

// waitUntil polls cond every second until it holds or the time is up.
func (s *server) waitUntil(timeout time.Duration, cond func() bool) bool {
	deadline := s.now().Add(timeout)
	for !cond() {
		if !s.now().Before(deadline) {
			return false
		}
		s.pause(time.Second)
	}
	return true
}

// ── LensCast's HTTP API ──────────────────────────────────────────────────────

// lenscast talks to LensCast on the tablet itself. The API token reads and
// starts/stops the stream; choosing a lens takes a login session (the token
// can't), sent without the token (a token present takes the token path).
// Writes need X-Requested-With, else LensCast answers "CSRF check failed".
type lenscast struct {
	base, user, password, token string
	client                      *http.Client
}

func lenscastFromEnv() *lenscast {
	l := &lenscast{
		base:     lenscastURL,
		user:     os.Getenv("LENSCAST_USER"),
		password: os.Getenv("LENSCAST_PASSWORD"),
		token:    os.Getenv("LENSCAST_API_TOKEN"),
		client:   &http.Client{Timeout: 10 * time.Second},
	}
	if l.token == "" {
		return nil
	}
	return l
}

func (l *lenscast) do(method, path string, body any, token bool, client *http.Client) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, l.base+path, rd)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token {
		req.Header.Set("Authorization", "Bearer "+l.token)
	}
	if client == nil {
		client = l.client
	}
	return client.Do(req)
}

func (l *lenscast) frames() (bool, error) {
	resp, err := l.do("GET", "/snapshot", nil, true, nil)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK && strings.HasPrefix(resp.Header.Get("Content-Type"), "image/"), nil
}

func (l *lenscast) post(path string) error {
	resp, err := l.do("POST", path, nil, true, nil)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	return nil
}

func (l *lenscast) restartStream() error {
	if err := l.post("/api/stream/stop"); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	return l.post("/api/stream/start")
}

type lensList struct {
	Lenses []struct {
		Index   int  `json:"index"`
		IsFront bool `json:"isFront"`
	} `json:"lenses"`
	Selected int `json:"selectedIndex"`
}

// wanted is the index of the first lens facing the right way, or -1.
func (ll lensList) wanted(front bool) int {
	for _, lens := range ll.Lenses {
		if lens.IsFront == front {
			return lens.Index
		}
	}
	return -1
}

func (l *lenscast) lenses() (lensList, error) {
	var ll lensList
	resp, err := l.do("GET", "/api/camera/lenses", nil, true, nil)
	if err != nil {
		return ll, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ll, fmt.Errorf("lenses: HTTP %d", resp.StatusCode)
	}
	return ll, json.NewDecoder(resp.Body).Decode(&ll)
}

func (l *lenscast) lensOK(front bool) (bool, error) {
	ll, err := l.lenses()
	if err != nil {
		return false, err
	}
	want := ll.wanted(front)
	return want < 0 || ll.Selected == want, nil
}

func (l *lenscast) selectLens(front bool) error {
	ll, err := l.lenses()
	if err != nil {
		return err
	}
	want := ll.wanted(front)
	if want < 0 || ll.Selected == want {
		return nil
	}
	if l.user == "" || l.password == "" {
		return errors.New("no LensCast login to choose the lens with")
	}
	jar, _ := cookiejar.New(nil)
	session := &http.Client{Timeout: 10 * time.Second, Jar: jar}
	resp, err := l.do("POST", "/api/auth/login", map[string]string{"username": l.user, "password": l.password}, false, session)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("login: HTTP %d", resp.StatusCode)
	}
	defer func() {
		if resp, err := l.do("POST", "/api/auth/logout", nil, false, session); err == nil {
			resp.Body.Close()
		}
	}()
	resp, err = l.do("POST", "/api/camera/lens", map[string]int{"index": want}, false, session)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("lens %d: HTTP %d", want, resp.StatusCode)
	}
	log.Printf("camera: lens %d selected", want)
	return nil
}
