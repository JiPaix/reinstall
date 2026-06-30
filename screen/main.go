// Command swapscreen-server exposes the global `swapscreen` script over HTTP.
//
//	GET  /mode          -> current display mode  (swapscreen --show --json)
//	POST /mode/{mode}    -> switch to tv|monitor  (swapscreen --tv|--monitor --json)
//	GET  /healthz        -> liveness probe
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
	"sync"
	"time"
)

// binary is the globally-installed swapscreen script (~/.local/bin/swapscreen).
const binary = "swapscreen"

// switchMu serializes mode switches: each one drives gdctl + a Sunshine
// reconciliation loop, and two overlapping runs would fight each other.
var switchMu sync.Mutex

func main() {
	addrFlag := flag.String("addr", "", "listen address (e.g. :8080); overrides PORT env")
	flag.Parse()

	addr := resolveAddr(*addrFlag)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /mode", handleGet)
	mux.HandleFunc("POST /mode/{mode}", handleSet)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	log.Printf("swapscreen-server listening on %s", addr)
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

// runSwapscreen invokes the swapscreen binary, capturing stdout and stderr
// separately. The script prints JSON to stdout on success and a JSON error
// object to stderr on failure.
func runSwapscreen(ctx context.Context, args ...string) (stdout, stderr []byte, err error) {
	cmd := exec.CommandContext(ctx, binary, args...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err = cmd.Run()
	return outBuf.Bytes(), errBuf.Bytes(), err
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	stdout, stderr, err := runSwapscreen(ctx, "--show", "--json")
	if err != nil {
		log.Printf("GET /mode failed in %s: %v (stderr: %s)", time.Since(start), err, trim(stderr))
		writeError(w, http.StatusBadGateway, detail("swapscreen --show failed", stderr, err))
		return
	}

	log.Printf("GET /mode -> %s in %s", trim(stdout), time.Since(start))
	writeJSON(w, http.StatusOK, stdout)
}

func handleSet(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	mode := r.PathValue("mode")
	if mode != "tv" && mode != "monitor" {
		writeError(w, http.StatusBadRequest, "mode must be tv or monitor")
		return
	}

	// Only one switch at a time.
	switchMu.Lock()
	defer switchMu.Unlock()

	// Detach from the request context on purpose. A switch restarts Sunshine,
	// which grabs DRM master and perturbs the display topology mid-flight (GNOME
	// transiently re-enables an unconfigured monitor). If the client disconnects
	// — some trigger clients give up after a few seconds — killing the script
	// here would leave the displays half-reconciled (e.g. an extra monitor stuck
	// on). So run to completion under our own timeout regardless of the client.
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	stdout, stderr, err := runSwapscreen(ctx, "--"+mode, "--json")
	if err != nil {
		log.Printf("POST /mode/%s failed in %s: %v (stderr: %s)", mode, time.Since(start), err, trim(stderr))
		writeError(w, http.StatusBadGateway, detail("swapscreen --"+mode+" failed", stderr, err))
		return
	}

	log.Printf("POST /mode/%s -> %s in %s", mode, trim(stdout), time.Since(start))
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
