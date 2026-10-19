package mesh

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"

	_ "modernc.org/sqlite"
)

// migrations are applied in order; the current version is len(migrations)
// and is tracked in the meta table. Never edit an applied migration.
var migrations = []string{
	// v1: registry, invites, pairing, session metadata.
	`
	CREATE TABLE IF NOT EXISTS devices (
		mesh_id    TEXT PRIMARY KEY,
		pubkey     BLOB NOT NULL UNIQUE,
		name       TEXT NOT NULL,
		created_at INTEGER NOT NULL
	);
	CREATE TABLE IF NOT EXISTS invites (
		code     TEXT PRIMARY KEY,
		used_by  TEXT,
		used_at  INTEGER
	);
	CREATE TABLE IF NOT EXISTS pairing_requests (
		from_id    TEXT NOT NULL,
		to_id      TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		PRIMARY KEY (from_id, to_id)
	);
	CREATE TABLE IF NOT EXISTS pairings (
		a_id       TEXT NOT NULL,
		b_id       TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		PRIMARY KEY (a_id, b_id)
	);
	CREATE TABLE IF NOT EXISTS sessions (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		a_id       TEXT NOT NULL,
		b_id       TEXT NOT NULL,
		started_at INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);
	`,
}

// Store is the SQLite-backed state of one mesh server instance.
type Store struct {
	db *sql.DB
}

// OpenStore opens (creating if needed) the SQLite database at path and
// applies any pending migrations.
func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	if _, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)`); err != nil {
		return fmt.Errorf("meta table: %w", err)
	}
	var cur string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'schema_version'`).Scan(&cur)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("read schema version: %w", err)
	}
	version := 0
	if cur != "" {
		fmt.Sscanf(cur, "%d", &version)
	}
	for i := version; i < len(migrations); i++ {
		if _, err := s.db.Exec(migrations[i]); err != nil {
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
		if _, err := s.db.Exec(
			`INSERT INTO meta(key, value) VALUES('schema_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
			fmt.Sprint(i+1)); err != nil {
			return fmt.Errorf("record schema version: %w", err)
		}
	}
	return nil
}

// SeedInvites inserts config-provided invite codes that are not yet known.
func (s *Store) SeedInvites(codes []string) error {
	for _, c := range codes {
		if c == "" {
			continue
		}
		if _, err := s.db.Exec(`INSERT OR IGNORE INTO invites(code) VALUES(?)`, c); err != nil {
			return fmt.Errorf("seed invite: %w", err)
		}
	}
	return nil
}

// InviteUnused reports whether code exists and has not been consumed.
func (s *Store) InviteUnused(code string) (bool, error) {
	var usedBy sql.NullString
	err := s.db.QueryRow(`SELECT used_by FROM invites WHERE code = ?`, code).Scan(&usedBy)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return !usedBy.Valid, nil
}

// MarkInviteUsed consumes an invite code for meshID.
func (s *Store) MarkInviteUsed(code, meshID string, now int64) error {
	_, err := s.db.Exec(`UPDATE invites SET used_by = ?, used_at = ? WHERE code = ? AND used_by IS NULL`, meshID, now, code)
	return err
}

// DeviceByPubkey returns the Mesh ID registered for pubkey, if any.
func (s *Store) DeviceByPubkey(pubkey []byte) (string, bool, error) {
	var id string
	err := s.db.QueryRow(`SELECT mesh_id FROM devices WHERE pubkey = ?`, pubkey).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return id, true, nil
}

// DeviceByID returns the public key and display name for a Mesh ID.
func (s *Store) DeviceByID(meshID string) (pubkey []byte, name string, ok bool, err error) {
	err = s.db.QueryRow(`SELECT pubkey, name FROM devices WHERE mesh_id = ?`, meshID).Scan(&pubkey, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, err
	}
	return pubkey, name, true, nil
}

// InsertDevice registers a new device. A UNIQUE constraint error (mesh_id
// or pubkey collision) is returned as-is so the caller can retry ID rolls.
func (s *Store) InsertDevice(meshID string, pubkey []byte, name string, now int64) error {
	_, err := s.db.Exec(`INSERT INTO devices(mesh_id, pubkey, name, created_at) VALUES(?,?,?,?)`,
		meshID, pubkey, name, now)
	return err
}

// IsUniqueViolation reports whether err is a SQLite UNIQUE constraint error.
func IsUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

func canonicalPair(a, b string) (string, string) {
	if a < b {
		return a, b
	}
	return b, a
}

// CreatePairingRequest records (or refreshes) a pending pairing request.
func (s *Store) CreatePairingRequest(fromID, toID string, now int64) error {
	_, err := s.db.Exec(
		`INSERT INTO pairing_requests(from_id, to_id, created_at) VALUES(?,?,?)
		 ON CONFLICT(from_id, to_id) DO UPDATE SET created_at = excluded.created_at`,
		fromID, toID, now)
	return err
}

// PendingRequestsFor lists the Mesh IDs with a pending request to meshID.
func (s *Store) PendingRequestsFor(meshID string) ([]string, error) {
	rows, err := s.db.Query(`SELECT from_id FROM pairing_requests WHERE to_id = ? ORDER BY created_at`, meshID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// DeletePairingRequest removes a pending request (used by approve/reject).
func (s *Store) DeletePairingRequest(fromID, toID string) error {
	_, err := s.db.Exec(`DELETE FROM pairing_requests WHERE from_id = ? AND to_id = ?`, fromID, toID)
	return err
}

// AddPairing stores an approved pairing grant (canonical order).
func (s *Store) AddPairing(aID, bID string, now int64) error {
	a, b := canonicalPair(aID, bID)
	_, err := s.db.Exec(
		`INSERT INTO pairings(a_id, b_id, created_at) VALUES(?,?,?) ON CONFLICT DO NOTHING`,
		a, b, now)
	return err
}

// Paired reports whether an approved pairing grant exists for the pair.
func (s *Store) Paired(aID, bID string) (bool, error) {
	a, b := canonicalPair(aID, bID)
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM pairings WHERE a_id = ? AND b_id = ?`, a, b).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// InsertSession records session metadata (start of a signaled session).
// Only metadata is ever stored — no payloads, no keys (design §4.2).
func (s *Store) InsertSession(aID, bID string, now int64) error {
	a, b := canonicalPair(aID, bID)
	_, err := s.db.Exec(`INSERT INTO sessions(a_id, b_id, started_at) VALUES(?,?,?)`, a, b, now)
	return err
}

// SessionCount returns how many session metadata rows exist (tests/ops).
func (s *Store) SessionCount() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&n)
	return n, err
}

// PruneSessions deletes session metadata older than the retention cutoff
// (30 days per design §10.8) and returns the number of rows removed.
func (s *Store) PruneSessions(before int64) (int64, error) {
	res, err := s.db.Exec(`DELETE FROM sessions WHERE started_at < ?`, before)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
