package main

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// A voice chain (EQ, compressor, de-esser, limiter…) is the graph of a
// microphone: set on the device node like an output's (graphs.go), so
// applications keep picking the microphone itself and record it processed —
// no second source shows up. Nothing is asked: a microphone whose model has a
// chain gets it.
//
// A chain is a filter graph in a file named after the model (chainFile). It
// is tuned by ear, for one voice on that model.

//go:embed mics/*.conf
var embeddedMics embed.FS

// userMicDir holds chains of the same format, read before the embedded ones:
// a chain can be tuned, or a model added, without waiting for a release.
func userMicDir() string {
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config/soundbar-setup/mics")
}

// chainFile names the chain of a model: "usb:1532:0555" -> "usb-1532-0555.conf".
func chainFile(model string) string {
	return strings.TrimSuffix(fileName(model), ".txt") + ".conf"
}

// micChain returns the chain of a microphone as a one-line graph, and where it
// comes from; ok is false when it has none. Only ALSA microphones get one: a
// Bluetooth one has no card name to be matched by, and its model id is often
// the chipset's.
func micChain(m Mic) (graph, from string, ok bool, err error) {
	if m.Model == "" || m.CardName == "" || !strings.HasPrefix(m.Source, "alsa_input") {
		return "", "", false, nil
	}
	name := chainFile(m.Model)
	from = filepath.Join(userMicDir(), name)
	b, err := os.ReadFile(from)
	if errors.Is(err, fs.ErrNotExist) {
		from = "built-in mics/" + name
		b, err = embeddedMics.ReadFile("mics/" + name)
		if errors.Is(err, fs.ErrNotExist) {
			return "", "", false, nil
		}
	}
	if err != nil {
		return "", "", false, err
	}
	if graph, err = oneLine(string(b)); err != nil {
		return "", "", false, fmt.Errorf("%s: %w", from, err)
	}
	return graph, from, true, nil
}

// micLabel is " — voice chain" for a microphone that gets one. As for
// correctionLabel, a broken user file only costs the label here: Render
// reports it.
func micLabel(m Mic) string {
	if _, _, ok, _ := micChain(m); !ok {
		return ""
	}
	return " — voice chain"
}

// oneLine turns a commented, multi-line graph into the single line a rule
// holds: comments dropped, blanks collapsed, strings left alone.
func oneLine(conf string) (string, error) {
	var b strings.Builder
	var open []byte // the brackets still to close
	inString, blank := false, false
	for i := 0; i < len(conf); i++ {
		ch := conf[i]
		if inString {
			b.WriteByte(ch)
			if ch == '\\' && i+1 < len(conf) {
				i++
				b.WriteByte(conf[i])
			} else if ch == '"' {
				inString = false
			}
			continue
		}
		switch ch {
		case '#':
			for i < len(conf) && conf[i] != '\n' {
				i++
			}
			blank = true
			continue
		case ' ', '\t', '\r', '\n':
			blank = true
			continue
		}
		if blank && b.Len() > 0 {
			b.WriteByte(' ')
		}
		blank = false
		switch ch {
		case '"':
			inString = true
		case '{', '[':
			open = append(open, ch+2) // '}' and ']' are two past their opener
		case '}', ']':
			if len(open) == 0 || open[len(open)-1] != ch {
				return "", fmt.Errorf("unexpected %q", ch)
			}
			open = open[:len(open)-1]
		}
		b.WriteByte(ch)
	}
	if inString || len(open) > 0 {
		return "", errors.New("a string or a bracket is left open")
	}
	if !strings.HasPrefix(b.String(), "{") {
		return "", errors.New("a graph is { nodes = [ … ] links = [ … ] … }")
	}
	return b.String(), nil
}
