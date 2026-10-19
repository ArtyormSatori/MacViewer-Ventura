package mesh

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// ---------- test scaffolding ----------

func startTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := OpenStore(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	cfg := Config{
		Listen:  "127.0.0.1:0",
		DataDir: dir,
		Invites: []string{"inv-1", "inv-2", "inv-3", "inv-4", "inv-5", "inv-6"},
	}
	if err := store.SeedInvites(cfg.Invites); err != nil {
		t.Fatalf("seed invites: %v", err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(cfg, store, log)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		ts.Close()
		store.Close()
	})
	return srv, ts.URL
}

func postJSON(t *testing.T, url string, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(url, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func registerDevice(t *testing.T, base, invite, name string) (ed25519.PrivateKey, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	status, body := postJSON(t, base+"/register", map[string]any{
		"pubkey": base64.StdEncoding.EncodeToString(pub),
		"name":   name,
		"invite": invite,
	})
	if status != http.StatusOK {
		t.Fatalf("register %s: status %d body %v", name, status, body)
	}
	id, _ := body["mesh_id"].(string)
	if id == "" {
		t.Fatalf("register %s: no mesh_id in %v", name, body)
	}
	return priv, id
}

// authedPost performs the nonce round-trip and posts a signed request.
func authedPost(t *testing.T, base, path string, priv ed25519.PrivateKey, meshID string, extra map[string]any) (int, map[string]any) {
	t.Helper()
	status, body := postJSON(t, base+"/nonce", map[string]any{"mesh_id": meshID})
	if status != http.StatusOK {
		t.Fatalf("nonce for %s: status %d", meshID, status)
	}
	nonce, _ := body["nonce"].(string)
	sig := ed25519.Sign(priv, []byte(nonce))
	req := map[string]any{
		"mesh_id":   meshID,
		"nonce":     nonce,
		"signature": base64.StdEncoding.EncodeToString(sig),
	}
	for k, v := range extra {
		req[k] = v
	}
	return postJSON(t, base+path, req)
}

func pairDevices(t *testing.T, base string, privA ed25519.PrivateKey, idA string, privB ed25519.PrivateKey, idB string) {
	t.Helper()
	status, body := authedPost(t, base, "/pair/request", privA, idA, map[string]any{"peer": idB})
	if status != http.StatusOK {
		t.Fatalf("pair request: %d %v", status, body)
	}
	status, body = authedPost(t, base, "/pair/approve", privB, idB, map[string]any{"peer": idA})
	if status != http.StatusOK {
		t.Fatalf("pair approve: %d %v", status, body)
	}
}

// ---------- registration ----------

var meshIDPattern = regexp.MustCompile(`^\d{9}$`)

func TestRegisterAssignsNineDigitIDAndIsIdempotent(t *testing.T) {
	_, base := startTestServer(t)
	pub, _, _ := ed25519.GenerateKey(nil)
	payload := map[string]any{
		"pubkey": base64.StdEncoding.EncodeToString(pub),
		"name":   "Mark's MacBook Pro",
		"invite": "inv-1",
	}
	status, body := postJSON(t, base+"/register", payload)
	if status != http.StatusOK {
		t.Fatalf("first register: %d %v", status, body)
	}
	id1, _ := body["mesh_id"].(string)
	if !meshIDPattern.MatchString(id1) {
		t.Fatalf("mesh_id %q is not 9 digits", id1)
	}
	// Re-registering the same key returns the same ID, invite irrelevant.
	payload["invite"] = ""
	status, body = postJSON(t, base+"/register", payload)
	if status != http.StatusOK {
		t.Fatalf("re-register: %d %v", status, body)
	}
	if got, _ := body["mesh_id"].(string); got != id1 {
		t.Fatalf("re-register returned %q, want %q", got, id1)
	}
	// A second device gets a different ID.
	_, id2 := registerDevice(t, base, "inv-2", "Windows box")
	if id2 == id1 {
		t.Fatal("two devices share a Mesh ID")
	}
}

func TestRegisterInviteGating(t *testing.T) {
	_, base := startTestServer(t)
	pub, _, _ := ed25519.GenerateKey(nil)
	mk := func(invite string) (int, map[string]any) {
		return postJSON(t, base+"/register", map[string]any{
			"pubkey": base64.StdEncoding.EncodeToString(pub),
			"name":   "gated",
			"invite": invite,
		})
	}
	if status, body := mk(""); status != http.StatusForbidden {
		t.Fatalf("no invite: got %d %v, want 403", status, body)
	}
	if status, body := mk("no-such-code"); status != http.StatusForbidden {
		t.Fatalf("wrong invite: got %d %v, want 403", status, body)
	}
	if status, _ := mk("inv-1"); status != http.StatusOK {
		t.Fatalf("valid invite: got %d, want 200", status)
	}
	// The same invite cannot register a second, different device.
	pub2, _, _ := ed25519.GenerateKey(nil)
	status, body := postJSON(t, base+"/register", map[string]any{
		"pubkey": base64.StdEncoding.EncodeToString(pub2),
		"name":   "second",
		"invite": "inv-1",
	})
	if status != http.StatusForbidden {
		t.Fatalf("invite reuse: got %d %v, want 403", status, body)
	}
}

// ---------- auth & pairing ----------

func TestNonceAuthRejectsBadSignature(t *testing.T) {
	_, base := startTestServer(t)
	_, victimID := registerDevice(t, base, "inv-1", "victim")
	attackerPriv, _ := registerDevice(t, base, "inv-2", "attacker")

	// The attacker signs the victim's nonce with the attacker's key.
	status, body := postJSON(t, base+"/nonce", map[string]any{"mesh_id": victimID})
	if status != http.StatusOK {
		t.Fatalf("nonce: %d", status)
	}
	nonce, _ := body["nonce"].(string)
	forged := ed25519.Sign(attackerPriv, []byte(nonce))
	status, body = postJSON(t, base+"/pair/list", map[string]any{
		"mesh_id":   victimID,
		"nonce":     nonce,
		"signature": base64.StdEncoding.EncodeToString(forged),
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("forged signature: got %d %v, want 401", status, body)
	}
	// A garbage signature is rejected too.
	status, _ = postJSON(t, base+"/pair/list", map[string]any{
		"mesh_id":   victimID,
		"nonce":     nonce,
		"signature": base64.StdEncoding.EncodeToString(make([]byte, 64)),
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("garbage signature: got %d, want 401", status)
	}
}

func TestPairingRequestApproveAndReject(t *testing.T) {
	srv, base := startTestServer(t)
	privA, idA := registerDevice(t, base, "inv-1", "A")
	privB, idB := registerDevice(t, base, "inv-2", "B")
	privC, idC := registerDevice(t, base, "inv-3", "C")

	// A requests pairing with B; B sees the pending request.
	if status, body := authedPost(t, base, "/pair/request", privA, idA, map[string]any{"peer": idB}); status != http.StatusOK {
		t.Fatalf("request: %d %v", status, body)
	}
	_, body := authedPost(t, base, "/pair/list", privB, idB, nil)
	pending, _ := body["pending"].([]any)
	if len(pending) != 1 || pending[0] != idA {
		t.Fatalf("B pending = %v, want [%s]", pending, idA)
	}
	if paired, _ := srv.Store().Paired(idA, idB); paired {
		t.Fatal("devices paired before approval")
	}
	// B approves -> grant stored.
	if status, body := authedPost(t, base, "/pair/approve", privB, idB, map[string]any{"peer": idA}); status != http.StatusOK {
		t.Fatalf("approve: %d %v", status, body)
	}
	if paired, _ := srv.Store().Paired(idA, idB); !paired {
		t.Fatal("devices not paired after approval")
	}
	// C requests B; B rejects -> no grant.
	if status, _ := authedPost(t, base, "/pair/request", privC, idC, map[string]any{"peer": idB}); status != http.StatusOK {
		t.Fatal("C request failed")
	}
	if status, _ := authedPost(t, base, "/pair/reject", privB, idB, map[string]any{"peer": idC}); status != http.StatusOK {
		t.Fatal("reject failed")
	}
	if paired, _ := srv.Store().Paired(idB, idC); paired {
		t.Fatal("devices paired after rejection")
	}
}

// ---------- signaling & presence over WebSocket ----------

type wsClient struct {
	conn *websocket.Conn
	id   string
}

func dialSignal(t *testing.T, base string, priv ed25519.PrivateKey, meshID string) *wsClient {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(base, "http") + "/signal"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial signal: %v", err)
	}
	c := &wsClient{conn: conn, id: meshID}
	if err := conn.WriteJSON(wsMessage{Type: "auth", MeshID: meshID}); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	nonceMsg := c.read(t)
	if nonceMsg.Type != "nonce" {
		t.Fatalf("expected nonce, got %+v", nonceMsg)
	}
	sig := ed25519.Sign(priv, []byte(nonceMsg.Nonce))
	if err := conn.WriteJSON(wsMessage{Type: "auth", Signature: base64.StdEncoding.EncodeToString(sig)}); err != nil {
		t.Fatalf("send signature: %v", err)
	}
	ok := c.read(t)
	if ok.Type != "auth_ok" {
		t.Fatalf("expected auth_ok, got %+v", ok)
	}
	t.Cleanup(func() { conn.Close() })
	return c
}

func (c *wsClient) read(t *testing.T) wsMessage {
	t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var msg wsMessage
	if err := c.conn.ReadJSON(&msg); err != nil {
		t.Fatalf("read ws: %v", err)
	}
	return msg
}

func (c *wsClient) signal(t *testing.T, to, kind, data string) {
	t.Helper()
	err := c.conn.WriteJSON(wsMessage{
		Type: "signal", To: to, Kind: kind, Data: json.RawMessage(data),
	})
	if err != nil {
		t.Fatalf("send signal: %v", err)
	}
}

func TestSignalingRequiresPairingGrant(t *testing.T) {
	srv, base := startTestServer(t)
	privA, idA := registerDevice(t, base, "inv-1", "A")
	privB, idB := registerDevice(t, base, "inv-2", "B")

	a := dialSignal(t, base, privA, idA)
	b := dialSignal(t, base, privB, idB)

	// Unpaired: the server refuses to relay.
	a.signal(t, idB, "offer", `"sdp-offer"`)
	msg := a.read(t)
	if msg.Type != "error" || msg.Code != "not_paired" {
		t.Fatalf("unpaired signal: got %+v, want error/not_paired", msg)
	}

	// Pair them; now the same envelope is delivered.
	pairDevices(t, base, privA, idA, privB, idB)
	a.signal(t, idB, "offer", `"sdp-offer"`)
	got := b.read(t)
	if got.Type != "signal" || got.From != idA || got.Kind != "offer" || string(got.Data) != `"sdp-offer"` {
		t.Fatalf("paired signal: got %+v", got)
	}
	if n, err := srv.Store().SessionCount(); err != nil || n != 1 {
		t.Fatalf("session metadata rows = %d, %v; want 1", n, err)
	}
}

func TestPresenceFollowsSignalingConnection(t *testing.T) {
	_, base := startTestServer(t)
	privA, idA := registerDevice(t, base, "inv-1", "A")

	presence := func() bool {
		resp, err := http.Get(base + "/presence/" + idA)
		if err != nil {
			t.Fatalf("presence: %v", err)
		}
		defer resp.Body.Close()
		var body map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&body)
		online, _ := body["online"].(bool)
		return online
	}
	if presence() {
		t.Fatal("device online before connecting")
	}
	c := dialSignal(t, base, privA, idA)
	if !presence() {
		t.Fatal("device offline while signaling connection is up")
	}
	c.conn.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if !presence() {
			return // went offline as expected
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("device still online after disconnect")
}

// ---------- refusal correlation (ref) ----------

func TestSignalRefExtraction(t *testing.T) {
	cases := []struct {
		name string
		data string
		want string
	}{
		{"chat marker id", `{"mvChat":{"v":1,"type":"chat","id":"9F3C1A2E-1111-4222-8333-444455556666","text":"hi","ts":1}}`,
			"9F3C1A2E-1111-4222-8333-444455556666"},
		{"session marker sessionID", `{"mvSession":{"v":1,"type":"session-request","sessionID":"S-42","capabilities":[]}}`,
			"S-42"},
		{"sdp string has no marker", `"v=0 o=- 1 2 IN IP4 127.0.0.1"`, ""},
		{"ice object is flat, no marker", `{"candidate":"candidate:1 1 udp 1 127.0.0.1 9 typ host","sdpMid":"0","sdpMLineIndex":0}`, ""},
		{"empty data", ``, ""},
		{"malformed json", `{"mvChat":`, ""},
		{"marker without identity", `{"mvChat":{"v":1,"type":"chat","text":"hi"}}`, ""},
		{"non-string identity ignored", `{"mvChat":{"id":42}}`, ""},
		{"empty identity ignored", `{"mvChat":{"id":""}}`, ""},
	}
	for _, c := range cases {
		if got := signalRef(json.RawMessage(c.data)); got != c.want {
			t.Errorf("%s: signalRef(%s) = %q, want %q", c.name, c.data, got, c.want)
		}
	}
}

func TestSignalingRefusalCarriesCorrelationRef(t *testing.T) {
	_, base := startTestServer(t)
	privA, idA := registerDevice(t, base, "inv-1", "A")
	privB, idB := registerDevice(t, base, "inv-2", "B")

	a := dialSignal(t, base, privA, idA)

	chatData := `{"mvChat":{"v":1,"type":"chat","id":"msg-0001","text":"hello","ts":1}}`

	// Unpaired: not_paired, and the refusal echoes the chat marker.
	a.signal(t, idB, "offer", chatData)
	msg := a.read(t)
	if msg.Type != "error" || msg.Code != "not_paired" {
		t.Fatalf("unpaired chat signal: got %+v, want error/not_paired", msg)
	}
	if msg.Ref != "msg-0001" {
		t.Fatalf("unpaired chat refusal ref = %q, want %q", msg.Ref, "msg-0001")
	}

	// Unpaired with a media payload: same refusal, no ref (field
	// omitted on the wire, so it decodes as "").
	a.signal(t, idB, "offer", `"sdp-offer"`)
	msg = a.read(t)
	if msg.Type != "error" || msg.Code != "not_paired" || msg.Ref != "" {
		t.Fatalf("unpaired sdp refusal: got %+v, want error/not_paired with empty ref", msg)
	}

	// Paired but the peer never connects: peer_offline, ref echoed.
	pairDevices(t, base, privA, idA, privB, idB)
	a.signal(t, idB, "offer", chatData)
	msg = a.read(t)
	if msg.Type != "error" || msg.Code != "peer_offline" {
		t.Fatalf("offline chat signal: got %+v, want error/peer_offline", msg)
	}
	if msg.Ref != "msg-0001" {
		t.Fatalf("offline chat refusal ref = %q, want %q", msg.Ref, "msg-0001")
	}
}
