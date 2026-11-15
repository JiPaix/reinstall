package main

import (
	"net"
	"strings"
	"testing"
)

// fakeADB is the tablet's adbd as Termux's adb sees it: Wireless debugging on
// tlsPort, something else listening on otherPort.
type fakeADB struct {
	tcpPort, tlsPort, otherPort string
	authorized                  bool
	calls                       []string
}

func (f *fakeADB) run(name string, args ...string) (string, error) {
	line := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, line)
	switch {
	case strings.HasSuffix(line, "getprop service.adb.tcp.port"):
		return f.tcpPort, nil
	case strings.HasPrefix(line, "adb -s 127.0.0.1:"+f.tlsPort+" get-state") && f.authorized:
		return "device", nil
	case strings.Contains(line, "get-state"):
		return "", nil
	case strings.HasPrefix(line, "adb -s 127.0.0.1:"+f.tlsPort+" tcpip "):
		f.tcpPort = args[len(args)-1]
		return "restarting in TCP mode port: " + f.tcpPort, nil
	}
	return "", nil
}

func withFakes(t *testing.T, f *fakeADB, open []int) {
	oldRun, oldScan := adbRun, scanLocal
	adbRun, scanLocal = f.run, func(int, int) []int { return open }
	t.Cleanup(func() { adbRun, scanLocal = oldRun, oldScan })
}

func TestADBPortAfterBoot(t *testing.T) {
	f := &fakeADB{tlsPort: "41234", otherPort: "37000", authorized: true}
	withFakes(t, f, []int{37000, 41234})
	changed, err := ensureADBPort("5555")
	if !changed || err != nil || f.tcpPort != "5555" {
		t.Fatalf("changed %v, err %v, port %q, calls %v", changed, err, f.tcpPort, f.calls)
	}
	if !strings.Contains(strings.Join(f.calls, "\n"), "adb disconnect 127.0.0.1:37000") {
		t.Errorf("the port that isn't adb should be let go: %v", f.calls)
	}
	// Next minute: already there, nothing scanned or run but the property.
	f.calls = nil
	if changed, err := ensureADBPort("5555"); changed || err != nil || len(f.calls) != 1 {
		t.Errorf("second pass: %v %v %v", changed, err, f.calls)
	}
}

func TestADBPortRefused(t *testing.T) {
	f := &fakeADB{tlsPort: "41234"}
	withFakes(t, f, []int{41234})
	if _, err := ensureADBPort("5555"); err == nil || !strings.Contains(err.Error(), "never allowed") {
		t.Errorf("an unallowed key: %v", err)
	}
	withFakes(t, f, nil)
	if _, err := ensureADBPort("5555"); err == nil || !strings.Contains(err.Error(), "off") {
		t.Errorf("Wireless debugging off: %v", err)
	}
}

func TestScanLocal(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	defer l.Close()
	p := l.Addr().(*net.TCPAddr).Port
	got := scanLocal(p-2, p+2)
	if len(got) != 1 || got[0] != p {
		t.Errorf("scan found %v, want [%d]", got, p)
	}
}
