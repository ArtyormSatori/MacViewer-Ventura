package mesh

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/logging"
	"github.com/pion/transport/v5/vnet"
	"github.com/pion/webrtc/v4"
)

// meshPeer is a test WebRTC client whose only signaling path is the mesh
// server under test — exactly how a Mode-2 client will use it.
type meshPeer struct {
	id   string
	peer string // the other device's Mesh ID
	ws   *websocket.Conn
	wmu  sync.Mutex
	pc   *webrtc.PeerConnection

	imu       sync.Mutex
	remoteSet bool
	pending   []webrtc.ICECandidateInit
}

// addICE buffers candidates that arrive before the remote description
// (signaling order is not guaranteed) and flushes them once it is set.
func (m *meshPeer) addICE(init webrtc.ICECandidateInit) {
	m.imu.Lock()
	defer m.imu.Unlock()
	if !m.remoteSet {
		m.pending = append(m.pending, init)
		return
	}
	_ = m.pc.AddICECandidate(init)
}

func (m *meshPeer) setRemote(desc webrtc.SessionDescription) error {
	if err := m.pc.SetRemoteDescription(desc); err != nil {
		return err
	}
	m.imu.Lock()
	defer m.imu.Unlock()
	m.remoteSet = true
	for _, c := range m.pending {
		_ = m.pc.AddICECandidate(c)
	}
	m.pending = nil
	return nil
}

func (m *meshPeer) sendSignal(kind string, data any) {
	raw, _ := json.Marshal(data)
	m.wmu.Lock()
	defer m.wmu.Unlock()
	_ = m.ws.WriteJSON(wsMessage{Type: "signal", To: m.peer, Kind: kind, Data: raw})
}

// signalLoop relays WS envelopes into the Pion peer connection until the
// socket closes.
func (m *meshPeer) signalLoop() {
	for {
		var msg wsMessage
		if err := m.ws.ReadJSON(&msg); err != nil {
			return
		}
		if msg.Type != "signal" {
			continue
		}
		switch msg.Kind {
		case "offer":
			var sdp string
			if err := json.Unmarshal(msg.Data, &sdp); err != nil {
				continue
			}
			if err := m.setRemote(webrtc.SessionDescription{
				Type: webrtc.SDPTypeOffer, SDP: sdp,
			}); err != nil {
				continue
			}
			answer, err := m.pc.CreateAnswer(nil)
			if err != nil {
				continue
			}
			if err := m.pc.SetLocalDescription(answer); err != nil {
				continue
			}
			m.sendSignal("answer", answer.SDP)
		case "answer":
			var sdp string
			if err := json.Unmarshal(msg.Data, &sdp); err != nil {
				continue
			}
			_ = m.setRemote(webrtc.SessionDescription{
				Type: webrtc.SDPTypeAnswer, SDP: sdp,
			})
		case "ice":
			var init webrtc.ICECandidateInit
			if err := json.Unmarshal(msg.Data, &init); err != nil {
				continue
			}
			m.addICE(init)
		}
	}
}

func connectMeshPeer(t *testing.T, base string, priv ed25519.PrivateKey, meshID string, vn *vnet.Net) *meshPeer {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(base, "http") + "/signal"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if err := conn.WriteJSON(wsMessage{Type: "auth", MeshID: meshID}); err != nil {
		t.Fatalf("hello: %v", err)
	}
	var nonceMsg wsMessage
	if err := conn.ReadJSON(&nonceMsg); err != nil || nonceMsg.Type != "nonce" {
		t.Fatalf("nonce handshake: %v %+v", err, nonceMsg)
	}
	sig := ed25519.Sign(priv, []byte(nonceMsg.Nonce))
	if err := conn.WriteJSON(wsMessage{
		Type: "auth", Signature: base64.StdEncoding.EncodeToString(sig),
	}); err != nil {
		t.Fatalf("sign: %v", err)
	}
	var ok wsMessage
	if err := conn.ReadJSON(&ok); err != nil || ok.Type != "auth_ok" {
		t.Fatalf("auth result: %v %+v", err, ok)
	}
	// The peer connection runs on a Pion virtual network: this sandbox
	// blocks unconnected-UDP sendto, which real ICE needs. vnet carries
	// the genuine ICE/DTLS/SCTP stack over in-memory links instead; on a
	// normal host the same client code uses real host candidates.
	se := webrtc.SettingEngine{}
	se.SetNet(vn)
	api := webrtc.NewAPI(webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("peer connection: %v", err)
	}
	m := &meshPeer{id: meshID, ws: conn, pc: pc}
	pc.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
		t.Logf("peer %s ICE state: %s", meshID, s.String())
	})
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			m.sendSignal("ice", c.ToJSON())
		}
	})
	t.Cleanup(func() {
		conn.Close()
		pc.Close()
	})
	return m
}

// TestPionDataChannelEndToEnd is the Phase-1 acceptance test: two real
// Pion WebRTC clients register, pair through the grant flow, signal ONLY
// through the mesh server, and exchange a data-channel message both ways.
func TestPionDataChannelEndToEnd(t *testing.T) {
	_, base := startTestServer(t)
	privA, idA := registerDevice(t, base, "inv-1", "viewer-mac")
	privB, idB := registerDevice(t, base, "inv-2", "host-windows")

	pairDevices(t, base, privA, idA, privB, idB)

	router, err := vnet.NewRouter(&vnet.RouterConfig{
		CIDR:          "10.0.0.0/24",
		LoggerFactory: logging.NewDefaultLoggerFactory(),
	})
	if err != nil {
		t.Fatalf("vnet router: %v", err)
	}
	netA, err := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.0.0.1"}})
	if err != nil {
		t.Fatalf("vnet A: %v", err)
	}
	netB, err := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"10.0.0.2"}})
	if err != nil {
		t.Fatalf("vnet B: %v", err)
	}
	if err := router.AddNet(netA); err != nil {
		t.Fatalf("add net A: %v", err)
	}
	if err := router.AddNet(netB); err != nil {
		t.Fatalf("add net B: %v", err)
	}
	if err := router.Start(); err != nil {
		t.Fatalf("start router: %v", err)
	}
	defer router.Stop()

	a := connectMeshPeer(t, base, privA, idA, netA)
	b := connectMeshPeer(t, base, privB, idB, netB)
	a.peer, b.peer = idB, idA
	go a.signalLoop()
	go b.signalLoop()

	aGot := make(chan string, 1)
	bGot := make(chan string, 1)

	// B answers on whatever data channel A opens.
	b.pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			bGot <- string(msg.Data)
			_ = dc.SendText("hello-from-b")
		})
	})

	dc, err := a.pc.CreateDataChannel("mesh-test", nil)
	if err != nil {
		t.Fatalf("create data channel: %v", err)
	}
	dc.OnOpen(func() {
		_ = dc.SendText("hello-from-a")
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		aGot <- string(msg.Data)
	})

	offer, err := a.pc.CreateOffer(nil)
	if err != nil {
		t.Fatalf("create offer: %v", err)
	}
	if err := a.pc.SetLocalDescription(offer); err != nil {
		t.Fatalf("set local: %v", err)
	}
	a.sendSignal("offer", offer.SDP)

	timeout := time.After(20 * time.Second)
	gotA, gotB := false, false
	for !gotA || !gotB {
		select {
		case msg := <-bGot:
			if msg != "hello-from-a" {
				t.Fatalf("B received %q, want hello-from-a", msg)
			}
			gotB = true
		case msg := <-aGot:
			if msg != "hello-from-b" {
				t.Fatalf("A received %q, want hello-from-b", msg)
			}
			gotA = true
		case <-timeout:
			t.Fatalf("timed out: B got message=%v, A got reply=%v", gotB, gotA)
		}
	}
}
