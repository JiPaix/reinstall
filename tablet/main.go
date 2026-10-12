// Command tablet-server runs inside Termux on an Android tablet set up by
// android.sh, and is what Home Assistant talks to: what the tablet shows, and
// two orders to change it.
//
//	GET  /capabilities          -> who this tablet is and what was installed on it
//	GET  /state                 -> what is in front, screen, battery
//	POST /display/homeassistant -> bring the Home Assistant app to the front, on its page
//	POST /display/moonlight     -> start the Moonlight stream of the configured PC
//	GET  /healthz               -> liveness probe
//
// "moonlight" as a display state means the stream itself: Moonlight's stream
// screen is in front AND holds the focus. Its error box ("connection
// terminated") sits on that same screen without a stream behind it, and reads
// as "other".
//
// A watcher runs alongside: when a stream ends that nobody asked to end (the
// PC restarted Sunshine, someone left it), or when an ordered stream never
// comes up, it puts Home Assistant back in front. It only ever looks at this
// tablet's own screen: nothing here talks to the PC.
//
// Termux has no right to see the screen or the battery by itself: android.sh
// grants it DUMP and PACKAGE_USAGE_STATS over adb (dumpsys activity needs
// both), and installs Termux:API for the battery.
//
// Configuration comes from the environment (android.sh writes it):
//
//	PORT, ALLOWED_IPS, AUTH_TOKEN  -> as for the PC's servers
//	TABLET_ID, TABLET_NAME, TABLET_MODEL
//	COMPONENTS       -> comma-separated: homeassistant, moonlight, squeezelite
//	HA_PACKAGE       -> the Home Assistant app's package
//	HA_PAGE          -> the dashboard page to open, e.g. lovelace/kitchen
//	MOONLIGHT_UUID   -> the PC's id in Moonlight
//	MOONLIGHT_APP_ID -> the id of the app to stream (Sunshine's "Desktop")
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	displayHA        = "homeassistant"
	displayMoonlight = "moonlight"
	displayOther     = "other"
	displayUnknown   = "unknown" // the screen can't be read (permissions not granted)

	moonlightStream = "com.limelight/.Game"
	moonlightWindow = "com.limelight/com.limelight.Game"

	// An ordered stream has this long to come up before the watcher gives the
	// screen back to Home Assistant: Moonlight may first have to wake the PC.
	streamGrace = 45 * time.Second

	// Looks in a row (2 s apart) the stream screen may spend without the focus
	// before it counts as dead: the notification shade or a volume panel takes
	// the focus for a moment, the error box keeps it.
	focusGrace = 4
)

type config struct {
	ID, Name, Model string
	Components      []string
	HAPackage       string
	HAPage          string
	MoonlightUUID   string
	MoonlightAppID  string
}

func (c config) has(component string) bool { return slices.Contains(c.Components, component) }

// system is everything the server asks of Android, so tests can stand in for it.
type system interface {
	front() (activity, focus string, err error)
	screenOn() (bool, error)
	battery() (*battery, error)
	start(args ...string)
}

type battery struct {
	Level    int    `json:"level"`
	Plugged  bool   `json:"plugged"`
	Charging bool   `json:"charging"`
	Status   string `json:"status"`
}

type server struct {
	cfg config
	sys system

	mu      sync.Mutex
	last    string    // display at the watcher's last look
	unfocus int       // looks in a row with the stream screen in front but unfocused
	pending time.Time // an ordered stream must be up by then; zero = none ordered
	now     func() time.Time
}

func main() {
	addrFlag := flag.String("addr", "", "listen address (e.g. :8080); overrides PORT env")
	flag.Parse()

	s := &server{cfg: configFromEnv(), sys: android{}, now: time.Now}
	allowedIPs := parseAllowedIPs(os.Getenv("ALLOWED_IPS"))
	token := os.Getenv("AUTH_TOKEN")

	if len(allowedIPs) > 0 {
		log.Printf("restricting access to: %s", os.Getenv("ALLOWED_IPS"))
	}
	if token != "" {
		log.Printf("requiring bearer token auth")
	}
	go s.watch()

	addr := resolveAddr(*addrFlag)
	log.Printf("tablet-server (%s) listening on %s, components: %s", s.cfg.Name, addr, strings.Join(s.cfg.Components, ", "))
	if err := http.ListenAndServe(addr, authMiddleware(s.routes(), allowedIPs, token)); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}

func configFromEnv() config {
	c := config{
		ID:             os.Getenv("TABLET_ID"),
		Name:           os.Getenv("TABLET_NAME"),
		Model:          os.Getenv("TABLET_MODEL"),
		HAPackage:      os.Getenv("HA_PACKAGE"),
		HAPage:         os.Getenv("HA_PAGE"),
		MoonlightUUID:  os.Getenv("MOONLIGHT_UUID"),
		MoonlightAppID: os.Getenv("MOONLIGHT_APP_ID"),
	}
	for _, part := range strings.Split(os.Getenv("COMPONENTS"), ",") {
		if part = strings.TrimSpace(part); part != "" {
			c.Components = append(c.Components, part)
		}
	}
	return c
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /capabilities", s.handleCapabilities)
	mux.HandleFunc("GET /state", s.handleState)
	mux.HandleFunc("POST /display/{target}", s.handleDisplay)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})
	return mux
}

// ── state ────────────────────────────────────────────────────────────────────

// display names what is in front.
func (s *server) display() string {
	got, _ := s.look()
	return got
}

// look also tells whether Moonlight's stream screen is the one in front,
// whatever holds the focus.
func (s *server) look() (display string, streamScreen bool) {
	activity, focus, err := s.sys.front()
	if err != nil || activity == "" {
		return displayUnknown, false
	}
	return displayOf(activity, focus, s.cfg.HAPackage), activity == moonlightStream
}

func displayOf(activity, focus, haPackage string) string {
	switch {
	case activity == moonlightStream && focus == moonlightWindow:
		return displayMoonlight
	case haPackage != "" && strings.HasPrefix(activity, haPackage+"/"):
		return displayHA
	}
	return displayOther
}

type state struct {
	Display  string   `json:"display"`
	ScreenOn *bool    `json:"screen_on"`
	Battery  *battery `json:"battery"`
}

func (s *server) state() state {
	st := state{Display: s.display()}
	if on, err := s.sys.screenOn(); err == nil {
		st.ScreenOn = &on
	}
	if b, err := s.sys.battery(); err == nil {
		st.Battery = b
	}
	return st
}

// ── orders ───────────────────────────────────────────────────────────────────

// showHA brings the Home Assistant app to the front on its page.
func (s *server) showHA() {
	s.sys.start("-a", "android.intent.action.VIEW", "-d", "homeassistant://navigate/"+s.cfg.HAPage)
}

// showMoonlight opens Moonlight's shortcut for the configured PC and app,
// which starts the stream. Both extras are strings: Moonlight reads nothing
// else, and without the app id it opens its app list instead.
func (s *server) showMoonlight() {
	s.sys.start("-n", "com.limelight/.ShortcutTrampoline", "-a", "android.intent.action.VIEW",
		"--es", "UUID", s.cfg.MoonlightUUID, "--es", "AppId", s.cfg.MoonlightAppID)
}

// waitFor polls until the display is want, or the time is up; it returns the
// last display seen. Termux's `am` reports a failure even when the activity
// did start, so the screen is what tells.
func (s *server) waitFor(want string, timeout time.Duration) string {
	deadline := s.now().Add(timeout)
	for {
		got := s.display()
		if got == want || got == displayUnknown || !s.now().Before(deadline) {
			return got
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func (s *server) handleDisplay(w http.ResponseWriter, r *http.Request) {
	target := r.PathValue("target")
	if target != displayHA && target != displayMoonlight {
		writeError(w, http.StatusNotFound, "display must be homeassistant or moonlight")
		return
	}
	if !s.cfg.has(target) {
		writeError(w, http.StatusNotFound, target+" was not set up on this tablet")
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	var got string
	if target == displayMoonlight {
		log.Printf("order: moonlight")
		s.pending = s.now().Add(streamGrace)
		s.showMoonlight()
		got = s.waitFor(displayMoonlight, 15*time.Second)
	} else {
		log.Printf("order: homeassistant")
		s.pending = time.Time{}
		s.showHA()
		got = s.waitFor(displayHA, 6*time.Second)
	}
	s.last = got
	writeJSON(w, http.StatusOK, map[string]string{"display": got})
}

func (s *server) handleState(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.state())
}

func (s *server) handleCapabilities(w http.ResponseWriter, _ *http.Request) {
	components := s.cfg.Components
	if components == nil {
		components = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"api":        1,
		"id":         s.cfg.ID,
		"name":       s.cfg.Name,
		"model":      s.cfg.Model,
		"components": components,
	})
}

// ── watcher ──────────────────────────────────────────────────────────────────

// watch gives the screen back to Home Assistant when a stream is over.
func (s *server) watch() {
	if !s.cfg.has(displayHA) {
		return // nothing to go back to
	}
	for {
		if s.tick() {
			time.Sleep(2 * time.Second)
		} else {
			time.Sleep(5 * time.Second)
		}
	}
}

// tick is one look at the screen; it reports whether a stream is up or
// expected, i.e. whether to look again soon.
func (s *server) tick() bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	got, streamScreen := s.look()
	switch {
	case got == displayMoonlight:
		s.pending = time.Time{}
		s.unfocus = 0
	case got == displayOther && s.last == displayMoonlight:
		// The stream screen went away, or something sits over it: for good if
		// it is Moonlight's error box, for a moment if it is a system panel.
		if streamScreen && s.unfocus < focusGrace {
			s.unfocus++
			return true
		}
		log.Printf("the stream ended: back to Home Assistant")
		s.unfocus = 0
		s.showHA()
		got = s.waitFor(displayHA, 6*time.Second)
	case got == displayOther && !s.pending.IsZero() && s.now().After(s.pending):
		log.Printf("the ordered stream never came up: back to Home Assistant")
		s.pending = time.Time{}
		s.showHA()
		got = s.waitFor(displayHA, 6*time.Second)
	case got == displayHA:
		s.pending = time.Time{}
	}
	s.last = got
	return got == displayMoonlight || !s.pending.IsZero()
}

// ── Android, as seen from Termux ─────────────────────────────────────────────

type android struct{}

func run(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).Output()
}

var (
	// topResumedActivity=ActivityRecord{dc8dfc3 u0 com.limelight/.Game} t148}
	reActivity = regexp.MustCompile(`topResumedActivity=ActivityRecord\{\S+ u\d+ ([^\s}]+)`)
	// mCurrentFocus=Window{ef530f u0 Connexion interrompue}
	reFocus = regexp.MustCompile(`(?m)mCurrentFocus=Window\{\S+ u\d+ (.*)\}\s*$`)
)

// parseFront reads the app in front and the window holding the focus out of
// `dumpsys activity activities`. The focus is a dialog's title when one is up.
func parseFront(dump string) (activity, focus string) {
	if m := reActivity.FindStringSubmatch(dump); m != nil {
		activity = m[1]
	}
	if m := reFocus.FindStringSubmatch(dump); m != nil {
		focus = m[1]
	}
	return activity, focus
}

func (android) front() (string, string, error) {
	out, err := run("/system/bin/dumpsys", "activity", "activities")
	if err != nil {
		return "", "", err
	}
	activity, focus := parseFront(string(out))
	if activity == "" {
		// Without DUMP and PACKAGE_USAGE_STATS dumpsys prints nothing useful.
		return "", "", errors.New("no activity in dumpsys output: are DUMP and PACKAGE_USAGE_STATS granted to Termux?")
	}
	return activity, focus, nil
}

func (android) screenOn() (bool, error) {
	out, err := run("/system/bin/dumpsys", "power")
	if err != nil {
		return false, err
	}
	i := strings.Index(string(out), "mWakefulness=")
	if i < 0 {
		return false, errors.New("no mWakefulness in dumpsys power")
	}
	return strings.HasPrefix(string(out)[i+len("mWakefulness="):], "Awake"), nil
}

// parseBattery reads termux-battery-status (Termux:API).
func parseBattery(out []byte) (*battery, error) {
	var raw struct {
		Percentage int    `json:"percentage"`
		Plugged    string `json:"plugged"`
		Status     string `json:"status"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, err
	}
	if raw.Status == "" {
		return nil, errors.New("no battery status")
	}
	return &battery{
		Level:    raw.Percentage,
		Plugged:  raw.Plugged != "" && raw.Plugged != "UNPLUGGED",
		Charging: raw.Status == "CHARGING" || raw.Status == "FULL",
		Status:   raw.Status,
	}, nil
}

func (android) battery() (*battery, error) {
	out, err := run("termux-battery-status")
	if err != nil {
		return nil, err
	}
	return parseBattery(out)
}

// start runs Termux's `am start`. Its exit code says nothing (it reports a
// failure after starting the activity all right), so nothing is returned.
func (android) start(args ...string) {
	run("am", append([]string{"start"}, args...)...)
}

// ── access control (same as the PC's servers) ────────────────────────────────

// parseAllowedIPs parses a comma-separated list of IPs and/or CIDRs (mixed
// freely). A bare IP is treated as a /32 (or /128 for IPv6). Invalid entries
// are logged and skipped rather than failing startup. Empty input means no
// restriction.
func parseAllowedIPs(raw string) []*net.IPNet {
	var nets []*net.IPNet
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.Contains(part, "/") {
			if ip := net.ParseIP(part); ip != nil {
				bits := 32
				if ip.To4() == nil {
					bits = 128
				}
				part = fmt.Sprintf("%s/%d", part, bits)
			}
		}
		_, ipnet, err := net.ParseCIDR(part)
		if err != nil {
			log.Printf("ALLOWED_IPS: skipping invalid entry %q: %v", part, err)
			continue
		}
		nets = append(nets, ipnet)
	}
	return nets
}

func ipAllowed(nets []*net.IPNet, remoteAddr string) bool {
	if len(nets) == 0 {
		return true
	}
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	for _, n := range nets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// authMiddleware enforces the optional IP allowlist and bearer token ahead of
// every route (including /healthz, for a uniform posture).
func authMiddleware(next http.Handler, allowedIPs []*net.IPNet, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !ipAllowed(allowedIPs, r.RemoteAddr) {
			log.Printf("%s %s denied: %s not in ALLOWED_IPS", r.Method, r.URL.Path, r.RemoteAddr)
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		if token != "" {
			got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				log.Printf("%s %s denied: bad or missing token from %s", r.Method, r.URL.Path, r.RemoteAddr)
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// resolveAddr picks the listen address: -addr flag, then PORT env, then :7923.
func resolveAddr(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if port := os.Getenv("PORT"); port != "" {
		return ":" + port
	}
	return ":7923"
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
