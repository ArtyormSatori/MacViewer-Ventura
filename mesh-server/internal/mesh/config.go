// Package mesh implements the MacViewer Ventura 5.0 Mode-2 mesh server:
// device registry (Ed25519 identity -> 9-digit Mesh ID), invite-only
// registration, pairing grants, presence, and WebRTC signaling relay.
// The server is a rendezvous + grant issuer only; media never passes
// through it (design doc SERVER_5_0_DESIGN.md §4.2).
package mesh

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config is the whole operator-facing configuration surface. Anyone can
// self-host: there is no project infrastructure baked in, only a listen
// address, a data directory, and the seeded invite codes.
type Config struct {
	Listen  string   `json:"listen"`
	DataDir string   `json:"data_dir"`
	Invites []string `json:"invites"`
}

// DefaultConfig returns the pilot defaults (loopback only).
func DefaultConfig() Config {
	return Config{Listen: "127.0.0.1:8734", DataDir: "./data"}
}

// LoadConfig reads a JSON config file; an empty path yields defaults.
func LoadConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	if path == "" {
		return cfg, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:8734"
	}
	if cfg.DataDir == "" {
		cfg.DataDir = "./data"
	}
	return cfg, nil
}
