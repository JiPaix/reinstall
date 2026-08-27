// Command poweroff-server exposes a single "shut this machine down" action
// over HTTP, so it can be triggered even when no one is logged in (e.g. a
// Home Assistant automation over Tailscale).
//
//	POST /shutdown -> systemctl poweroff (graceful: stops units, syncs disks)
//	GET  /healthz  -> liveness probe
//
// Unlike swapscreen-server/soundbar-status-server (unprivileged --user
// services), this runs as a root system service — `systemctl poweroff` needs
// root, and it must be reachable with no session/login at all. The attack
// surface is deliberately a single action with no arguments.
//
// Access control (both optional, off by default):
//
//	ALLOWED_IPS  -> comma-separated IPs/CIDRs allowed to connect; unset = no restriction
//	AUTH_TOKEN   -> shared secret required as `Authorization: Bearer <token>`; unset = no check
package main

import (
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
	"sync/atomic"
)

// shuttingDown latches once a shutdown has been queued, so a retried POST
// (e.g. a client that timed out waiting and retries) doesn't spawn a second
// `systemctl poweroff` — it just gets the same "shutting down" response.
var shuttingDown atomic.Bool

func main() {
	addrFlag := flag.String("addr", "", "listen address (e.g. :8080); overrides PORT env")
	flag.Parse()

	addr := resolveAddr(*addrFlag)
	allowedIPs := parseAllowedIPs(os.Getenv("ALLOWED_IPS"))
	token := os.Getenv("AUTH_TOKEN")

	mux := http.NewServeMux()
	mux.HandleFunc("POST /shutdown", handleShutdown)
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

	log.Printf("poweroff-server listening on %s", addr)
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

// handleShutdown asks systemd for a normal, graceful poweroff: it stops units
// (including any user sessions) and syncs disks in dependency order, same as
// running `systemctl poweroff` at a shell — not a forced/immediate cut.
//
// It responds before running the command, not after: a full poweroff (all
// units stopped, disks synced) routinely takes longer than a typical HTTP
// client timeout (e.g. Home Assistant's default 4s), so waiting for it would
// make the request read as a failure even though the shutdown proceeded.
// `--no-block` on top means the command itself returns as soon as the job is
// queued rather than waiting for it to finish, so it can't reintroduce that
// same wait from the other side.
//
// The shuttingDown latch makes repeat POSTs (a client retrying after its own
// timeout) idempotent: only the first actually invokes systemctl.
func handleShutdown(w http.ResponseWriter, r *http.Request) {
	if !shuttingDown.CompareAndSwap(false, true) {
		log.Printf("POST /shutdown from %s: already shutting down, ignoring", r.RemoteAddr)
		writeJSON(w, http.StatusAccepted, map[string]string{"status": "shutting down"})
		return
	}

	log.Printf("POST /shutdown from %s: queuing systemctl poweroff", r.RemoteAddr)
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "shutting down"})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	go func() {
		if err := exec.Command("systemctl", "poweroff", "--no-block").Run(); err != nil {
			log.Printf("systemctl poweroff failed: %v", err)
		}
	}()
}

func writeJSON(w http.ResponseWriter, status int, body map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
