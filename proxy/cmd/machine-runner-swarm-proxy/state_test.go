package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStoreWritePersistsState(t *testing.T) {
	dir := t.TempDir()
	st, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := newClass("class-a", filepath.Join(dir, "token"))
	c.latched["10.0.0.1"] = true
	if err := st.write([]*class{c}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, stateMarker)); err != nil {
		t.Fatalf("marker: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(dir, stateFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "10.0.0.1") {
		t.Fatalf("state does not hold the latch: %s", b)
	}
}
