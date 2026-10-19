# MeshClient — MacViewer Ventura 5.0 Mode 2, Swift client core (Phase 2)

The control-plane client for the self-hosted mesh: Ed25519 device
identity, the mesh server's REST API (register, nonce-signature auth,
pairing, presence), and the WebSocket signaling channel
(offer/answer/ice envelopes between paired devices). **No WebRTC
media in this phase** — signaling envelopes only; the media engine
plugs into these envelopes later.

The wire contract is the Phase-1 Go server in `../mesh-server`
(`internal/mesh/server.go` is authoritative; this client matches it
field for field). Nothing in `../src` or the Linux tree is touched;
app integration comes in a later phase.

## Layout

```
Package.swift                     swift-tools 5.9, macOS 13+, dep: apple/swift-crypto 3.x
Sources/MeshClient/
  MeshID.swift                    9-digit Mesh ID value type (validating, 3-3-3 display)
  MeshError.swift                 typed errors for every server failure mode
  MeshIdentity.swift              Ed25519 keypair (swift-crypto Curve25519.Signing)
                                  + MeshIdentityStore protocol: File store (key file
                                  mode 0600) and InMemory store for tests
  MeshServerClient.swift          async REST client (actor): register / nonce+sign auth /
                                  pair request·list·approve·reject / presence
                                  + PairingRecord (local learned pairings; file + memory)
  SignalingEnvelope.swift         WS wire message (mirrors server's wsMessage) + JSONValue
                                  for the opaque `data` field (SDP string / ICE object)
  WebSocketTransport.swift        transport protocol + RFC 6455 codec (pure, tested)
                                  + POSIX-socket RFC 6455 client + Darwin
                                  URLSessionWebSocketTask adapter (#if canImport(Darwin))
  MeshSignalingClient.swift       WS connect + nonce-signature handshake, sends signals,
                                  surfaces peer signals as AsyncStream, 10 s heartbeat ping
Sources/mesh-smoke/main.swift     CLI driving one device (register / pair-* / presence /
                                  signal-listen / signal-send); prints PASS lines
Tests/MeshClientTests/            33 XCTest cases: identity persistence + 0600 perms,
                                  recorded-payload decoding, error mapping, envelope
                                  coding, RFC 6455 codec
run-smoke.sh                      end-to-end two-device smoke against the real Go server
```

## WebSocket transport choice

**Hand-rolled minimal RFC 6455 client over POSIX sockets** — chosen
over vapor/websocket-kit (swift-nio). The signaling surface is only
text frames + ping/pong + close; pulling in the whole NIO stack for
that adds Swift-version friction for zero protocol gain. The codec is
pure functions (unit-tested: masked frames, 16/64-bit lengths, split
feeds) and the smoke below proves interop with the server's
gorilla/websocket stack.

Limits: this transport is `ws://` only. The Darwin adapter
(`URLSessionWebSocketTransport`, compiled only where
`canImport(Darwin)`) covers the future macOS app including `wss://`;
the pilot server runs on loopback/LAN or behind a tunnel this phase.
`WebSocketTransportFactory.makeDefault()` picks per platform.

## How the pieces map to the future app

- **Identity**: the app creates one `MeshIdentity` per device via
  `MeshIdentity.loadOrCreate(using:)` with a Keychain-backed
  `MeshIdentityStore` (the app layer adds it; this package deliberately
  contains no Keychain code). The file store suits CLI/Linux use.
- **Server URL**: one `MeshServerClient(baseURL:)` per app session.
  Server address is a user setting in 5.0 (project default or
  self-hosted), so the base URL is injected, never hardcoded.
- **Registration**: on first Mode-2 use, `register(identity:name:invite:)`
  with the invite the user received; persist the returned `MeshID`
  (the file store keeps it in `mesh-id.txt`). Re-registering a known
  key is idempotent and needs no invite.
- **Pairing UI** (per `../UI_5_0_DESIGN.md`): connect-by-Mesh-ID →
  `requestPairing`; requests area → `listPendingPairings` +
  `approvePairing`/`rejectPairing`; paired-devices list →
  `listPairedDevices()` (local record — see friction note 1) with
  `presence(of:)` per row for the online dot.
- **Session setup (M1+)**: `MeshSignalingClient.connect()`, then feed
  `signals` into the WebRTC engine; ICE/SDP payloads ride the
  envelope's `data` verbatim (`JSONValue.string` for SDP,
  `JSONValue.object` for candidates). `serverErrors` surfaces typed
  refusals (not paired / peer offline) to the UI.

## Commands

Toolchain (this machine): Swift 6.0.3 at
`~/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin`.

```sh
cd ~/workspace/macviewer-ventura/mesh-client
export PATH=~/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH

swift build          # library + mesh-smoke executable
swift test           # 33 unit tests
sh run-smoke.sh      # end-to-end smoke (builds ../mesh-server with Go,
                     # boots it on a random loopback port with test
                     # invites, runs two devices through register ->
                     # pair -> presence -> signal round-trip; prints
                     # PASS lines and "SMOKE RESULT: PASS")
```

`run-smoke.sh` honors `GO` / `SWIFT` env overrides for toolchain paths.

## Server-API friction found (reported, not fixed — server is authoritative)

1. **No "list my pairing grants" endpoint.** The store has the data
   (`Paired(a,b)`) but no route exposes it, so `listPairedDevices()`
   can only be a client-side record of pairings learned from
   `approvePairing`, an `.alreadyPaired` request result, or a signal
   that arrived through the grant-gated relay. A `POST /pair/grants`
   (signed) would make the server the source of truth.
2. **One outstanding nonce per device.** `issueNonce` overwrites the
   single stored nonce, so an interleaved REST auth and WS handshake
   for the same device can invalidate each other's challenge. This
   client serializes its REST calls (actor) and fetches each nonce
   immediately before use; a server-side nonce set (or per-flow nonce
   scope) would remove the hazard.
3. **Mixed base64 dialects.** `pubkey`/`signature` are base64
   StdEncoding, but the nonce is base64 RawURLEncoding (URL-safe
   alphabet, unpadded). Clients must treat the nonce as an opaque
   string — the signature is over the string bytes, so any
   re-encoding breaks verification.
4. **REST errors are free-text messages, not codes.** The client maps
   (HTTP status, message) pairs to typed errors; a server rewording
   would silently degrade them to `.server(status:message:)`. The WS
   side already has stable `code`s — REST should grow a `code` field.
5. **Pending list is bare IDs** — no requester name or timestamp;
   clients resolve names via a presence lookup per ID.
6. Minor: README says `GET /presence/{mesh_id}` while the mux pattern
   in server.go is `/presence/{id}` (same path, cosmetic); pair
   `reject` returns 200 even when nothing was pending, so "rejected"
   and "no request existed" are indistinguishable (harmless).
