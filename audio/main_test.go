package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubScripts puts fake soundbar-status / audio-eq scripts first on PATH.
// audio-eq keeps its state in a file, like the real one.
func stubScripts(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write("soundbar-status", `echo '{ "soundbar": true, "eq": true }'`+"\n")
	write("audio-eq", `state="`+dir+`/state"
case "$1" in
  on|off) echo "$1" > "$state" ;;
  status) ;;
  *) echo "usage" >&2; exit 2 ;;
esac
[ "$(cat "$state" 2>/dev/null)" = off ] && echo '{ "eq": false }' || echo '{ "eq": true }'
`)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func call(t *testing.T, h http.Handler, method, path, token string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	req.RemoteAddr = "192.168.1.44:5555"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code, strings.TrimSpace(rec.Body.String())
}

func TestRoutes(t *testing.T) {
	stubScripts(t)
	h := routes()

	for _, tc := range []struct {
		method, path string
		code         int
		body         string
	}{
		{"GET", "/status", 200, `{ "soundbar": true, "eq": true }`},
		{"GET", "/eq", 200, `{ "eq": true }`},
		{"POST", "/eq/off", 200, `{ "eq": false }`},
		{"GET", "/eq", 200, `{ "eq": false }`}, // the switch sticks
		{"POST", "/eq/on", 200, `{ "eq": true }`},
		{"POST", "/eq/loud", 400, `{"error":"invalid state \"loud\": must be on or off"}`},
		{"GET", "/eq/off", 405, ""}, // switching is a POST
		{"GET", "/healthz", 200, `{"status":"ok"}`},
	} {
		code, body := call(t, h, tc.method, tc.path, "")
		if code != tc.code || (tc.body != "" && body != tc.body) {
			t.Errorf("%s %s = %d %q, want %d %q", tc.method, tc.path, code, body, tc.code, tc.body)
		}
	}
}

// TestScriptFailure: a script that fails gives a 502 carrying its stderr.
func TestScriptFailure(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\necho 'no output was set up with an equalizer' >&2\nexit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "audio-eq"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)

	code, body := call(t, routes(), "POST", "/eq/on", "")
	if code != 502 || !strings.Contains(body, "no output was set up with an equalizer") {
		t.Errorf("got %d %q", code, body)
	}
}

// TestAccessControl: the EQ routes sit behind the same checks as /status.
func TestAccessControl(t *testing.T) {
	stubScripts(t)
	h := authMiddleware(routes(), parseAllowedIPs("192.168.1.44"), "secret")

	if code, _ := call(t, h, "POST", "/eq/off", ""); code != 401 {
		t.Errorf("no token: got %d, want 401", code)
	}
	if code, _ := call(t, h, "POST", "/eq/off", "wrong"); code != 401 {
		t.Errorf("wrong token: got %d, want 401", code)
	}
	if code, body := call(t, h, "POST", "/eq/off", "secret"); code != 200 || body != `{ "eq": false }` {
		t.Errorf("good token: got %d %q", code, body)
	}

	h = authMiddleware(routes(), parseAllowedIPs("10.0.0.0/8"), "secret")
	if code, _ := call(t, h, "GET", "/eq", "secret"); code != 403 {
		t.Errorf("address outside ALLOWED_IPS: got %d, want 403", code)
	}
}
