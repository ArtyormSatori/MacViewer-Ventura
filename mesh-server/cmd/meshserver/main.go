// Command meshserver runs the MacViewer Ventura 5.0 Mode-2 mesh server:
// rendezvous (registry + presence), pairing grants, and WebRTC signaling.
//
// Usage: meshserver [-config config.json]
package main

import (
	"flag"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"

	"github.com/ArtyormSatori/MacViewer-Ventura/mesh-server/internal/mesh"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	cfgPath := flag.String("config", "", "path to JSON config file (defaults if empty)")
	flag.Parse()

	cfg, err := mesh.LoadConfig(*cfgPath)
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.DataDir, 0o750); err != nil {
		log.Error("data dir", "err", err)
		os.Exit(1)
	}
	store, err := mesh.OpenStore(filepath.Join(cfg.DataDir, "mesh.db"))
	if err != nil {
		log.Error("store", "err", err)
		os.Exit(1)
	}
	defer store.Close()
	if err := store.SeedInvites(cfg.Invites); err != nil {
		log.Error("seed invites", "err", err)
		os.Exit(1)
	}

	srv := mesh.NewServer(cfg, store, log)
	if n, err := srv.PruneOldSessions(); err != nil {
		log.Warn("session prune failed", "err", err)
	} else if n > 0 {
		log.Info("pruned old session metadata", "rows", n)
	}

	log.Info("mesh server listening", "addr", cfg.Listen, "data_dir", cfg.DataDir)
	if err := http.ListenAndServe(cfg.Listen, srv.Handler()); err != nil {
		log.Error("serve", "err", err)
		os.Exit(1)
	}
}
