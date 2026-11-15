package main

// adb on a fixed port. Android turns adb's TCP mode off at every boot, and only
// an adb client can turn it back on (`adb tcpip`): the persist property is
// refused without root. adbwifi (tablet/adbwifi) brings Wireless debugging
// back at boot, on a random port, announced only by mDNS (which Termux's adb
// can't read) and in no property Termux may read. So this looks for it among
// the local ports, connects Termux's own adb client to it, and moves adbd to
// the fixed port. Termux's adb key must have been allowed once on the
// tablet's screen ("Always allow"): android.sh asks for that.
//
// service.adb.tcp.port (readable) tells whether the fixed port is on: checked
// every minute, so a restart of adbd is caught too.

import (
	"errors"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	adbPortEvery = time.Minute
	// Where Android picks Wireless debugging's port.
	tlsPortMin, tlsPortMax = 30000, 60999
)

// adbRun runs a command (adb, getprop); tests replace it.
var adbRun = func(name string, args ...string) (string, error) {
	out, err := run(name, args...)
	return strings.TrimSpace(string(out)), err
}

// scanLocal lists the ports between lo and hi that take a connection on
// 127.0.0.1: a refusal is immediate on the device itself.
var scanLocal = func(lo, hi int) []int {
	ports := make(chan int)
	var mu sync.Mutex
	var open []int
	var wg sync.WaitGroup
	for range 256 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range ports {
				c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(p)), 300*time.Millisecond)
				if err == nil {
					c.Close()
					mu.Lock()
					open = append(open, p)
					mu.Unlock()
				}
			}
		}()
	}
	for p := lo; p <= hi; p++ {
		ports <- p
	}
	close(ports)
	wg.Wait()
	return open
}

// keepADBPort runs for as long as the server does.
func keepADBPort(port string) {
	last := ""
	for {
		msg := "adb: on port " + port
		if changed, err := ensureADBPort(port); err != nil {
			msg = "adb: " + err.Error()
		} else if changed {
			msg = "adb: moved to port " + port
		}
		if msg != last {
			log.Print(msg)
			last = msg
		}
		time.Sleep(adbPortEvery)
	}
}

// ensureADBPort moves adbd to port unless it is there already.
func ensureADBPort(port string) (changed bool, err error) {
	if got, _ := adbRun("/system/bin/getprop", "service.adb.tcp.port"); got == port {
		return false, nil
	}
	open := scanLocal(tlsPortMin, tlsPortMax)
	if len(open) == 0 {
		return false, errors.New("Wireless debugging is off (nothing listens where it would)")
	}
	// Each open port may be something else: adb tells.
	defer adbRun("adb", "kill-server")
	for _, p := range open {
		target := "127.0.0.1:" + strconv.Itoa(p)
		adbRun("adb", "connect", target)
		state, _ := adbRun("adb", "-s", target, "get-state")
		if state != "device" {
			adbRun("adb", "disconnect", target)
			continue
		}
		if out, err := adbRun("adb", "-s", target, "tcpip", port); err != nil {
			return false, fmt.Errorf("adb tcpip %s: %v %s", port, err, out)
		}
		return true, nil
	}
	// Also seen for a minute after a boot, before adbd takes connections.
	return false, errors.New("no port takes Termux's adb key yet (booting, or the key was never allowed on the tablet's screen)")
}
