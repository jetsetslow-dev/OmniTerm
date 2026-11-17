package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/jetsetslow-dev/omniterm/tunnel/omnitunnel"
	"github.com/slackhq/nebula/config"
)

func TestGeneratedPhoneIdentityWorksWithTheCarrier(t *testing.T) {
	dir := t.TempDir()
	if err := generateConfigs(dir, "10.0.2.2:4242"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "phone.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if message := omnitunnel.CheckNebula(string(raw)); message != "" {
		t.Fatal(message)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatal("generated identity is not private")
	}
	for _, name := range []string{"lighthouse", "node"} {
		c := &config.C{}
		if err := c.Load(filepath.Join(dir, name+".json")); err != nil {
			t.Fatal(err)
		}
		if c.GetBool("lighthouse.am_lighthouse", false) != (name == "lighthouse") {
			t.Fatal("wrong discovery role")
		}
	}
}
