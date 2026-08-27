// Command soundbar-status-server exposes the global `soundbar-status` script over HTTP.
//
//	GET  /status   -> current soundbar state (soundbar-status)
//	GET  /healthz  -> liveness probe
//
// Access control (both optional, off by default):
//
//	ALLOWED_IPS  -> comma-separated IPs/CIDRs allowed to connect; unset = no restriction
//	AUTH_TOKEN   -> shared secret required as `Authorization: Bearer <token>`; unset = no check
package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// binary is the globally-installed soundbar-status script (~/.local/bin/soundbar-status).
const binary = "soundbar-status"

func main() {
	addrFlag := flag.String("addr", "", "listen address (e.g. :8080); overrides PORT env")
	flag.Parse()

	addr := resolveAddr(*addrFlag)
	allowedIPs := parseAllowedIPs(os.Getenv("ALLOWED_IPS"))
	token := os.Getenv("AUTH_TOKEN")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", handleStatus)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	if len(allowedIPs) > 0 {
		log.Printf("restricting access to: %s", os.Getenv("ALLOWED_IPS"))
	}
	if token != "" {
		log.Printf("requiring bearer token auth")
	}

	log.Printf("soundbar-status-server listening on %s", addr)
	if err := http.ListenAndServe(addr, authMiddleware(mux, allowedIPs, token)); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}

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
// every route (including /healthz, for a uniform posture). Both checks are
// configured via env and skipped when unset, so an install with neither set
// stays exactly as open as before this existed.
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
