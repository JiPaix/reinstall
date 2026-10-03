package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// Nodes of our own making are never offered as devices: the processed outputs
// (fxPrefix), and what earlier versions created, which is still loaded when the
// wizard runs without audio.sh having cleaned up first.
var virtualNodes = map[string]bool{
	"bt_swap_sink":     true,
	"bt_swap_sink_out": true,
}

var virtualPrefixes = []string{fxPrefix, "audio_eq.", "audio_swap."}

func isVirtual(name string) bool {
	for _, p := range virtualPrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return virtualNodes[name]
}

// Device is a sink or source as reported by `pactl -f json`.
type Device struct {
	Name  string
	Desc  string // human description (already de-nulled)
	Card  string // owning card (alsa_card.* / bluez_card.*), "" if none
	Class string // properties["device.class"], e.g. "sound" | "monitor"

	// Absent marks an output kept from the previous run that isn't connected
	// right now (a Bluetooth speaker that is off).
	Absent bool
}

func (d Device) IsBT() bool { return strings.HasPrefix(d.Name, "bluez_") }

// Hardware is a physical device — an ALSA card or a Bluetooth device. Hiding
// works at this level: a card can't lose its mic and keep its output.
type Hardware struct {
	Card string
	Desc string
	BT   bool
}

// Devices bundles the detected hardware with its sinks and sources.
type Devices struct {
	Hardware []Hardware
	Sinks    []Device
	Sources  []Device
}

type pactlNode struct {
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Properties  map[string]string `json:"properties"`
}

// cardOf returns the card a node belongs to. Bluetooth loopback sources
// (bluez_input.<address>) carry no device.name, so theirs is rebuilt from the
// node name the same way WirePlumber names the card.
func cardOf(name, deviceName string) string {
	if deviceName != "" {
		return deviceName
	}
	for _, prefix := range []string{"bluez_output.", "bluez_input."} {
		addr, ok := strings.CutPrefix(name, prefix)
		if !ok {
			continue
		}
		// bluez_output.<address>.<n>: drop the trailing node index.
		if i := strings.LastIndex(addr, "."); i >= 0 && isDigits(addr[i+1:]) {
			addr = addr[:i]
		}
		return "bluez_card." + strings.ReplaceAll(addr, ":", "_")
	}
	return ""
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func (n pactlNode) toDevice() Device {
	// pactl prints "(null)" for a description it can't encode as JSON (any
	// non-ASCII one, e.g. a translated profile name): fall back on the device's.
	desc := n.Description
	for _, alt := range []string{n.Properties["device.description"], n.Properties["node.nick"], n.Name} {
		if desc != "" && desc != "(null)" {
			break
		}
		desc = alt
	}
	return Device{
		Name:  n.Name,
		Desc:  desc,
		Card:  cardOf(n.Name, n.Properties["device.name"]),
		Class: n.Properties["device.class"],
	}
}

// DetectDevices lists the cards plus the offerable sinks and (non-monitor)
// sources. Cards include the ones whose profile is off, so a device hidden by
// a previous run is still listed.
func DetectDevices() (Devices, error) {
	cards, err := listNodes("cards")
	if err != nil {
		return Devices{}, err
	}
	sinks, err := listNodes("sinks")
	if err != nil {
		return Devices{}, err
	}
	sources, err := listNodes("sources")
	if err != nil {
		return Devices{}, err
	}

	var d Devices
	for _, n := range cards {
		desc := n.Properties["device.description"]
		if desc == "" {
			desc = n.Name
		}
		d.Hardware = append(d.Hardware, Hardware{
			Card: n.Name,
			Desc: desc,
			BT:   strings.HasPrefix(n.Name, "bluez_"),
		})
	}
	for _, n := range sinks {
		if isVirtual(n.Name) {
			continue
		}
		d.Sinks = append(d.Sinks, n.toDevice())
	}
	for _, n := range sources {
		dev := n.toDevice()
		if isVirtual(n.Name) || dev.Class == "monitor" || strings.HasSuffix(n.Name, ".monitor") {
			continue
		}
		d.Sources = append(d.Sources, dev)
	}
	return d, nil
}

func listNodes(kind string) ([]pactlNode, error) {
	out, err := exec.Command("pactl", "-f", "json", "list", kind).Output()
	if err != nil {
		return nil, fmt.Errorf("running 'pactl -f json list %s': %w", kind, err)
	}
	var nodes []pactlNode
	if err := json.Unmarshal(out, &nodes); err != nil {
		return nil, fmt.Errorf("parsing pactl %s JSON: %w", kind, err)
	}
	return nodes, nil
}
