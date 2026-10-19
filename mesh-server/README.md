# MacViewer Ventura — Mesh Server (Mode 2, Phase 1)

The rendezvous server for MacViewer Ventura 5.0's self-hosted mode.
It is a **registry + pairing-grant issuer + WebRTC signaling relay +
presence tracker**. Media never passes through it: once two paired
clients have exchanged SDP/ICE here, their WebRTC media and data
channels run peer-to-peer (or over a separate TURN server), encrypted
end to end. The design is deliberately narrow: the server knows
device public keys, pairing grants, and presence — nothing else.
Identity is a local Ed25519 keypair on each device (no accounts and
no passwords live on the server), registration is invite-only, and
media always takes the WebRTC route — peer-to-peer with DTLS-SRTP
encryption end to end — instead of being relayed through or stored
on this server.

Anyone can self-host it — there is no project infrastructure baked in.
Configuration is one small JSON file: listen address, data directory,
and the invite codes you choose to seed.

## Build & run

Requires Go 1.26 or newer (the `go` directive in `go.mod`).

```sh
go build -o meshserver ./cmd/meshserver
cp config.example.json config.json   # edit invites before first run
./meshserver -config config.json
```

State lives in `<data_dir>/mesh.db` (SQLite). Logs are structured JSON
on stderr and contain metadata only — never payloads or keys.

Without `-config`, defaults apply: listen `127.0.0.1:8734`, data dir
`./data`, no invites (nobody can register until you seed codes).

## Concepts

- **Device identity** — an Ed25519 keypair generated on the device; the
  private key never leaves it. The server stores only the public key.
- **Mesh ID** — a 9-digit ID assigned at registration and shown to users
  grouped 3-3-3. Re-registering the same public key returns the same ID.
- **Invite-only registration** — a *new* key can register only with a
  single-use invite code from the config. Codes are consumed on use.
- **Pairing grant** — device A requests pairing with device B's Mesh ID;
  B approves (or rejects) over the authenticated API. Only then may the
  two devices signal each other. The server never pairs devices itself.
- **Authentication** — every authenticated call first fetches a
  single-use nonce from `POST /nonce` and signs it with the device key
  (Ed25519); the WebSocket handshake uses the same proof.
- **Presence** — a device is online while it holds an authenticated
  signaling connection and has heartbeated within the 30 s lease
  (clients ping every ~10 s).
- **Session metadata** — one row per signaled session (pair + start
  time), retained 30 days, pruned at startup.

## API surface

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /healthz` | — | Liveness: `{"status":"ok"}` |
| `POST /register` | invite (new keys) | `{pubkey, name, invite}` → `{mesh_id}` |
| `POST /nonce` | — | `{mesh_id}` → `{nonce}` (60 s, single-use) |
| `POST /pair/request` | signed | `{mesh_id, nonce, signature, peer}` |
| `POST /pair/list` | signed | List pending inbound pairing requests |
| `POST /pair/approve` | signed | Approve `peer`'s request → creates the grant |
| `POST /pair/reject` | signed | Drop `peer`'s request |
| `GET /presence/{mesh_id}` | — | `{mesh_id, name, online, last_seen}` |
| `GET /signal` (WebSocket) | nonce handshake | WebRTC signaling relay |

Signaling protocol (JSON envelopes over the WebSocket):

1. Client → `{type:"auth", mesh_id}`; server → `{type:"nonce", nonce}`;
   client → `{type:"auth", signature}` (base64 Ed25519 signature over
   the nonce string); server → `{type:"auth_ok"}`.
2. Client → `{type:"signal", to, kind, data}` where `kind` is `offer`,
   `answer`, or `ice` and `data` is the opaque SDP string / ICE
   candidate JSON. The server forwards it to `to` as
   `{type:"signal", from, kind, data}` **only if a pairing grant
   exists**; otherwise it replies `{type:"error", code:"not_paired"}`
   (or `peer_offline` when the peer is not connected).
3. `{type:"ping"}` keeps presence fresh; server replies
   `{type:"pong"}` (WebSocket-level pings also count).

## Tests

```sh
go test ./...
```

Unit tests cover ID assignment + idempotency, invite gating, pairing
request/approve/reject, forged-signature rejection, signaling without a
grant, and presence transitions. `TestPionDataChannelEndToEnd` boots the
real server and connects two Pion WebRTC clients through it: register →
pair → signal → data channel message in both directions.

Note on the integration test: it runs Pion over a virtual network
(`pion/transport/vnet`) because the CI sandbox blocks unconnected UDP
`sendto`, which raw ICE requires. The WebRTC stack under test (ICE,
DTLS, SCTP) is entirely real; only the link layer is virtual. On a
normal host the same client flow works over real host candidates.

## Layout

```
cmd/meshserver/    entry point (-config flag)
internal/mesh/     config, SQLite store (inline migrations), HTTP/WS server, tests
```
