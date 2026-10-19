package mesh

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// PresenceLease is how long a device may go without a heartbeat before it
// is reported offline (design §4.2: heartbeat 10 s, lease 30 s).
const PresenceLease = 30 * time.Second

// SessionRetention is the session-metadata retention window (design §10.8).
const SessionRetention = 30 * 24 * time.Hour

type nonceEntry struct {
	value   string
	expires time.Time
}

type peerConn struct {
	id       string
	conn     *websocket.Conn
	wmu      sync.Mutex
	lastSeen time.Time
}

func (p *peerConn) send(v any) error {
	p.wmu.Lock()
	defer p.wmu.Unlock()
	return p.conn.WriteJSON(v)
}

// Server is the mesh rendezvous: registry, pairing grants, presence and
// WebRTC signaling. It never sees media.
type Server struct {
	cfg   Config
	store *Store
	log   *slog.Logger

	mu     sync.Mutex
	nonces map[string]nonceEntry
	peers  map[string]*peerConn
}

// NewServer builds a Server over an opened store.
func NewServer(cfg Config, store *Store, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	return &Server{
		cfg:    cfg,
		store:  store,
		log:    log,
		nonces: make(map[string]nonceEntry),
		peers:  make(map[string]*peerConn),
	}
}

// Store exposes the backing store (ops and tests).
func (s *Server) Store() *Store { return s.store }

// Handler returns the HTTP routing surface.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /register", s.handleRegister)
	mux.HandleFunc("POST /nonce", s.handleNonce)
	mux.HandleFunc("POST /pair/request", s.handlePairRequest)
	mux.HandleFunc("POST /pair/list", s.handlePairList)
	mux.HandleFunc("POST /pair/approve", s.handlePairApprove)
	mux.HandleFunc("POST /pair/reject", s.handlePairReject)
	mux.HandleFunc("GET /presence/{id}", s.handlePresence)
	mux.HandleFunc("GET /signal", s.handleSignal)
	return mux
}

// PruneOldSessions removes session metadata past the retention window.
func (s *Server) PruneOldSessions() (int64, error) {
	return s.store.PruneSessions(time.Now().Add(-SessionRetention).Unix())
}

// ---------- helpers ----------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	if err := dec.Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	return true
}

func newMeshID() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(900_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%09d", n.Int64()+100_000_000), nil
}

func newNonce() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// issueNonce creates a fresh single-use auth nonce for a device.
func (s *Server) issueNonce(meshID string) (string, error) {
	n, err := newNonce()
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	s.nonces[meshID] = nonceEntry{value: n, expires: time.Now().Add(60 * time.Second)}
	s.mu.Unlock()
	return n, nil
}

// authenticate consumes the nonce and verifies the Ed25519 signature over
// the nonce string with the device's registered public key.
func (s *Server) authenticate(meshID, nonce, sigB64 string) error {
	s.mu.Lock()
	entry, ok := s.nonces[meshID]
	if ok {
		delete(s.nonces, meshID)
	}
	s.mu.Unlock()
	if !ok || entry.value != nonce || time.Now().After(entry.expires) {
		return errors.New("invalid or expired nonce")
	}
	pub, _, found, err := s.store.DeviceByID(meshID)
	if err != nil {
		return err
	}
	if !found || len(pub) != ed25519.PublicKeySize {
		return errors.New("unknown device")
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return errors.New("malformed signature")
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), []byte(nonce), sig) {
		return errors.New("bad signature")
	}
	return nil
}

// authedBody is the common shape of authenticated REST requests.
type authedBody struct {
	MeshID    string `json:"mesh_id"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
	Peer      string `json:"peer"`
}

func (s *Server) requireAuth(w http.ResponseWriter, b *authedBody) bool {
	if err := s.authenticate(b.MeshID, b.Nonce, b.Signature); err != nil {
		writeErr(w, http.StatusUnauthorized, "authentication failed")
		return false
	}
	return true
}

// ---------- HTTP handlers ----------

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type registerRequest struct {
	Pubkey string `json:"pubkey"` // base64 std encoding of the 32-byte Ed25519 public key
	Name   string `json:"name"`
	Invite string `json:"invite"`
}

// handleRegister assigns a 9-digit Mesh ID to a new device key.
// Registration is invite-only for NEW keys (design §10.4); re-registering
// an already-known key is idempotent and needs no invite.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	pub, err := base64.StdEncoding.DecodeString(req.Pubkey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		writeErr(w, http.StatusBadRequest, "pubkey must be a base64 Ed25519 public key")
		return
	}
	if req.Name == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	if id, found, err := s.store.DeviceByPubkey(pub); err != nil {
		writeErr(w, http.StatusInternalServerError, "registry lookup failed")
		return
	} else if found {
		writeJSON(w, http.StatusOK, map[string]string{"mesh_id": id})
		return
	}
	// New device: gate on a single-use invite code.
	unused, err := s.store.InviteUnused(req.Invite)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "invite lookup failed")
		return
	}
	if req.Invite == "" || !unused {
		writeErr(w, http.StatusForbidden, "a valid invite code is required")
		return
	}
	now := time.Now().Unix()
	var meshID string
	for attempt := 0; attempt < 100; attempt++ {
		candidate, err := newMeshID()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "id generation failed")
			return
		}
		err = s.store.InsertDevice(candidate, pub, req.Name, now)
		if err == nil {
			meshID = candidate
			break
		}
		if !IsUniqueViolation(err) {
			writeErr(w, http.StatusInternalServerError, "device insert failed")
			return
		}
	}
	if meshID == "" {
		writeErr(w, http.StatusInternalServerError, "could not allocate a Mesh ID")
		return
	}
	if err := s.store.MarkInviteUsed(req.Invite, meshID, now); err != nil {
		s.log.Warn("mark invite used failed", "mesh_id", meshID, "err", err)
	}
	s.log.Info("device registered", "mesh_id", meshID, "name", req.Name)
	writeJSON(w, http.StatusOK, map[string]string{"mesh_id": meshID})
}

func (s *Server) handleNonce(w http.ResponseWriter, r *http.Request) {
	var req struct {
		MeshID string `json:"mesh_id"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	_, _, found, err := s.store.DeviceByID(req.MeshID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "registry lookup failed")
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "unknown device")
		return
	}
	nonce, err := s.issueNonce(req.MeshID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "nonce generation failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"nonce": nonce})
}

// handlePairRequest records a pairing request from the caller to a peer.
func (s *Server) handlePairRequest(w http.ResponseWriter, r *http.Request) {
	var req authedBody
	if !decodeJSON(w, r, &req) || !s.requireAuth(w, &req) {
		return
	}
	if req.Peer == "" || req.Peer == req.MeshID {
		writeErr(w, http.StatusBadRequest, "peer must be another device's Mesh ID")
		return
	}
	if _, _, found, err := s.store.DeviceByID(req.Peer); err != nil || !found {
		writeErr(w, http.StatusNotFound, "unknown peer")
		return
	}
	if paired, _ := s.store.Paired(req.MeshID, req.Peer); paired {
		writeJSON(w, http.StatusOK, map[string]string{"status": "already_paired"})
		return
	}
	if err := s.store.CreatePairingRequest(req.MeshID, req.Peer, time.Now().Unix()); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not record request")
		return
	}
	s.log.Info("pairing requested", "from", req.MeshID, "to", req.Peer)
	writeJSON(w, http.StatusOK, map[string]string{"status": "requested"})
}

// handlePairList returns pending inbound pairing requests for the caller.
func (s *Server) handlePairList(w http.ResponseWriter, r *http.Request) {
	var req authedBody
	if !decodeJSON(w, r, &req) || !s.requireAuth(w, &req) {
		return
	}
	pending, err := s.store.PendingRequestsFor(req.MeshID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not list requests")
		return
	}
	if pending == nil {
		pending = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"pending": pending})
}

// handlePairApprove approves a pending request from peer, creating the
// pairing grant that authorizes signaling between the two devices.
func (s *Server) handlePairApprove(w http.ResponseWriter, r *http.Request) {
	var req authedBody
	if !decodeJSON(w, r, &req) || !s.requireAuth(w, &req) {
		return
	}
	pending, err := s.store.PendingRequestsFor(req.MeshID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not list requests")
		return
	}
	found := false
	for _, from := range pending {
		if from == req.Peer {
			found = true
		}
	}
	if !found {
		writeErr(w, http.StatusNotFound, "no pending request from that peer")
		return
	}
	now := time.Now().Unix()
	if err := s.store.DeletePairingRequest(req.Peer, req.MeshID); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not clear request")
		return
	}
	if err := s.store.AddPairing(req.MeshID, req.Peer, now); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not store grant")
		return
	}
	s.log.Info("pairing approved", "a", req.MeshID, "b", req.Peer)
	writeJSON(w, http.StatusOK, map[string]string{"status": "paired"})
}

// handlePairReject drops a pending request without creating a grant.
func (s *Server) handlePairReject(w http.ResponseWriter, r *http.Request) {
	var req authedBody
	if !decodeJSON(w, r, &req) || !s.requireAuth(w, &req) {
		return
	}
	if err := s.store.DeletePairingRequest(req.Peer, req.MeshID); err != nil {
		writeErr(w, http.StatusInternalServerError, "could not clear request")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "rejected"})
}

// handlePresence reports a device's presence: online while it holds an
// authenticated signaling connection within the heartbeat lease.
func (s *Server) handlePresence(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_, name, found, err := s.store.DeviceByID(id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "registry lookup failed")
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "unknown device")
		return
	}
	online := false
	var lastSeen int64
	s.mu.Lock()
	if p, ok := s.peers[id]; ok {
		lastSeen = p.lastSeen.Unix()
		online = time.Since(p.lastSeen) <= PresenceLease
	}
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"mesh_id": id, "name": name, "online": online, "last_seen": lastSeen,
	})
}

// ---------- WebSocket signaling ----------

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
}

type wsMessage struct {
	Type      string          `json:"type"`
	MeshID    string          `json:"mesh_id,omitempty"`
	Nonce     string          `json:"nonce,omitempty"`
	Signature string          `json:"signature,omitempty"`
	To        string          `json:"to,omitempty"`
	From      string          `json:"from,omitempty"`
	Kind      string          `json:"kind,omitempty"` // offer | answer | ice
	Data      json.RawMessage `json:"data,omitempty"`
	Code      string          `json:"code,omitempty"`
	// Ref, on an error frame answering a signal, echoes the refused
	// envelope's client-supplied marker (see signalRef) so the sender
	// can attribute the refusal when several sends are in flight.
	// Absent when the refused envelope carried no marker; older
	// clients simply ignore the field, so this is wire-compatible.
	Ref string `json:"ref,omitempty"`
}

// signalRef extracts the correlation marker from a signal envelope's
// data payload. App-plane envelopes carry their payload as an object
// holding one marker key (mvChat / mvSession) whose value is an
// object with a client-minted identity: "id" for a chat message,
// "sessionID" for a session negotiation. The first such identity, in
// sorted marker-key order, is the marker. Media-plane payloads (an
// SDP string, or a flat ICE candidate object) have no nested marker
// object and yield "" — those refusals stay uncorrelated, exactly as
// before this field existed. Malformed payloads yield "".
func signalRef(data json.RawMessage) string {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return ""
	}
	keys := make([]string, 0, len(top))
	for k := range top {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		var marker map[string]json.RawMessage
		if err := json.Unmarshal(top[k], &marker); err != nil {
			continue // not an object: cannot hold an identity
		}
		for _, field := range []string{"id", "sessionID"} {
			var value string
			if raw, ok := marker[field]; ok && json.Unmarshal(raw, &value) == nil && value != "" {
				return value
			}
		}
	}
	return ""
}

func (s *Server) handleSignal(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(1 << 20)
	defer conn.Close()

	// Step 1: the client names its device.
	var hello wsMessage
	if err := conn.ReadJSON(&hello); err != nil || hello.Type != "auth" || hello.MeshID == "" {
		_ = conn.WriteJSON(wsMessage{Type: "error", Code: "expected_auth"})
		return
	}
	if _, _, found, err := s.store.DeviceByID(hello.MeshID); err != nil || !found {
		_ = conn.WriteJSON(wsMessage{Type: "error", Code: "unknown_device"})
		return
	}
	// Step 2: prove key possession by signing a fresh server nonce.
	nonce, err := s.issueNonce(hello.MeshID)
	if err != nil {
		return
	}
	if err := conn.WriteJSON(wsMessage{Type: "nonce", Nonce: nonce}); err != nil {
		return
	}
	var authMsg wsMessage
	if err := conn.ReadJSON(&authMsg); err != nil || authMsg.Type != "auth" {
		_ = conn.WriteJSON(wsMessage{Type: "error", Code: "expected_signature"})
		return
	}
	if err := s.authenticate(hello.MeshID, nonce, authMsg.Signature); err != nil {
		_ = conn.WriteJSON(wsMessage{Type: "error", Code: "bad_signature"})
		return
	}

	peer := &peerConn{id: hello.MeshID, conn: conn, lastSeen: time.Now()}
	s.mu.Lock()
	if old, ok := s.peers[peer.id]; ok {
		_ = old.conn.Close() // one live signaling connection per device
	}
	s.peers[peer.id] = peer
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if cur, ok := s.peers[peer.id]; ok && cur == peer {
			delete(s.peers, peer.id)
		}
		s.mu.Unlock()
		s.log.Info("device offline", "mesh_id", peer.id)
	}()

	if err := peer.send(wsMessage{Type: "auth_ok", MeshID: peer.id}); err != nil {
		return
	}
	s.log.Info("device online", "mesh_id", peer.id)

	conn.SetPongHandler(func(string) error {
		s.touch(peer)
		return nil
	})

	for {
		var msg wsMessage
		if err := conn.ReadJSON(&msg); err != nil {
			return
		}
		s.touch(peer)
		switch msg.Type {
		case "ping":
			_ = peer.send(wsMessage{Type: "pong"})
		case "signal":
			s.forwardSignal(peer, msg)
		default:
			_ = peer.send(wsMessage{Type: "error", Code: "unknown_type"})
		}
	}
}

func (s *Server) touch(p *peerConn) {
	s.mu.Lock()
	p.lastSeen = time.Now()
	s.mu.Unlock()
}

// forwardSignal relays an SDP/ICE envelope to a paired peer only. The
// server never pairs devices on its own: no grant, no relay (design §4.2).
func (s *Server) forwardSignal(from *peerConn, msg wsMessage) {
	// Every refusal of this envelope echoes its correlation marker
	// ("" for marker-less envelopes, which omits the field).
	ref := signalRef(msg.Data)
	if msg.To == "" || msg.To == from.id {
		_ = from.send(wsMessage{Type: "error", Code: "bad_recipient", Ref: ref})
		return
	}
	paired, err := s.store.Paired(from.id, msg.To)
	if err != nil {
		_ = from.send(wsMessage{Type: "error", Code: "internal", Ref: ref})
		return
	}
	if !paired {
		_ = from.send(wsMessage{Type: "error", Code: "not_paired", To: msg.To, Ref: ref})
		return
	}
	s.mu.Lock()
	target, ok := s.peers[msg.To]
	s.mu.Unlock()
	if !ok || time.Since(target.lastSeen) > PresenceLease {
		_ = from.send(wsMessage{Type: "error", Code: "peer_offline", To: msg.To, Ref: ref})
		return
	}
	if err := target.send(wsMessage{
		Type: "signal", From: from.id, Kind: msg.Kind, Data: msg.Data,
	}); err != nil {
		_ = from.send(wsMessage{Type: "error", Code: "peer_offline", To: msg.To, Ref: ref})
		return
	}
	if msg.Kind == "offer" {
		if err := s.store.InsertSession(from.id, msg.To, time.Now().Unix()); err != nil {
			s.log.Warn("session metadata insert failed", "err", err)
		}
		s.log.Info("session signaled", "from", from.id, "to", msg.To)
	}
}
