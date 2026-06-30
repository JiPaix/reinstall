// Command soundbar-status-server exposes the global `soundbar-status` script over HTTP.
//
//	GET  /status   -> current soundbar state (soundbar-status)
//	GET  /healthz  -> liveness probe
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"os/exec"
	"time"
)

// binary is the globally-installed soundbar-status script (~/.local/bin/soundbar-status).
const binary = "soundbar-status"

func main() {
	addrFlag := flag.String("addr", "", "listen address (e.g. :8080); overrides PORT env")
	flag.Parse()

	addr := resolveAddr(*addrFlag)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", handleStatus)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	log.Printf("soundbar-status-server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}

// resolveAddr picks the listen address: -addr flag, then PORT env, then :8080.
func resolveAddr(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if port := os.Getenv("PORT"); port != "" {
		return ":" + port
	}
	return ":8080"
}

// runStatus invokes the soundbar-status binary, capturing stdout and stderr
// separately. The script prints JSON ({ "soundbar": true|false }) to stdout.
func runStatus(ctx context.Context, args ...string) (stdout, stderr []byte, err error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err = cmd.Run()
	return outBuf.Bytes(), errBuf.Bytes(), err
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	stdout, stderr, err := runStatus(ctx)
	if err != nil {
		log.Printf("GET /status failed in %s: %v (stderr: %s)", time.Since(start), err, trim(stderr))
		writeError(w, http.StatusBadGateway, detail("soundbar-status failed", stderr, err))
		return
	}

	log.Printf("GET /status -> %s in %s", trim(stdout), time.Since(start))
	writeJSON(w, http.StatusOK, stdout)
}

// writeJSON forwards the script's JSON stdout verbatim (it already matches the
// desired response shape), normalizing trailing whitespace.
func writeJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(append(trim(body), '\n'))
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// detail builds an error message, preferring the script's stderr text if present.
func detail(fallback string, stderr []byte, err error) string {
	if s := trim(stderr); len(s) > 0 {
		return string(s)
	}
	return fallback + ": " + err.Error()
}

func trim(b []byte) []byte {
	return bytes.TrimSpace(b)
}
