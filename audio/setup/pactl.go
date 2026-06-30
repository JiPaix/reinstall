package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// virtualNodes are nodes created by our own EQ filter-chain; never offer them.
var virtualNodes = map[string]bool{
	"bt_swap_sink":     true,
	"bt_swap_sink_out": true,
}

// Device is a sink or source as reported by `pactl -f json`.
type Device struct {
	Name  string
	Desc  string // human description (already de-nulled)
	Card  string // properties["device.name"] — the owning card, "" if none
	API   string // properties["device.api"], e.g. "alsa"
	Class string // properties["device.class"], e.g. "sound" | "monitor"
}

func (d Device) IsALSA() bool { return d.API == "alsa" || strings.HasPrefix(d.Name, "alsa_") }
func (d Device) IsBT() bool   { return strings.HasPrefix(d.Name, "bluez_") }

// Label is a one-line picker label, e.g. `Soundbar — bluez_output.…`.
func (d Device) Label() string { return fmt.Sprintf("%s — %s", d.Desc, d.Name) }

// Devices bundles the detected sinks, sources, and ALSA card names.
type Devices struct {
	Sinks   []Device
	Sources []Device
}

type pactlNode struct {
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Properties  map[string]string `json:"properties"`
}

func (n pactlNode) toDevice() Device {
	desc := n.Description
	if desc == "" || desc == "(null)" {
		desc = n.Name
	}
	return Device{
		Name:  n.Name,
		Desc:  desc,
		Card:  n.Properties["device.name"],
		API:   n.Properties["device.api"],
		Class: n.Properties["device.class"],
	}
}

// DetectDevices lists offerable sinks and (non-monitor) sources.
func DetectDevices() (Devices, error) {
	sinks, err := listNodes("sinks")
	if err != nil {
		return Devices{}, err
	}
	sources, err := listNodes("sources")
	if err != nil {
		return Devices{}, err
	}

	var d Devices
	for _, n := range sinks {
		if virtualNodes[n.Name] {
			continue
		}
		d.Sinks = append(d.Sinks, n.toDevice())
	}
	for _, n := range sources {
		dev := n.toDevice()
		if virtualNodes[n.Name] || dev.Class == "monitor" || strings.HasSuffix(n.Name, ".monitor") {
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
