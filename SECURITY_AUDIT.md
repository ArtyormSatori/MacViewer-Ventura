# Security audit — MacViewer 0.3.4 (audited 2026-10-18)

Scope: full source review of the attack surfaces a remote-control app
exposes: network transports, legacy protocol cryptography, credential
storage, host-side consent and input injection, parser limits against
malicious peers, and the update mechanism. "Fixed" items are committed in
this repository; "inherent" items are properties of the UltraViewer
protocol itself and cannot be changed by any compatible client.

## Fixed in this fork

1. **Keychain accessibility for saved partner passwords**
   (`PartnerCredentialStore`): items were stored without an explicit
   `kSecAttrAccessible`, leaving the protection level to the platform
   default. They are now stored as
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on both add and update:
   readable only while this Mac is unlocked, never migrated or restored
   to another device. (Already non-synchronizable and service-scoped.)
   This fix applies cleanly to upstream as well.

2. **Ventura build pipeline** (`.github/workflows/ventura-release.yml`):
   the one build-time binary (`8bit.dat`) is fetched from the upstream
   repository at a pinned commit and verified against a pinned SHA-256
   before use.

## Verified strong (no change needed)

- **Relay connections are always TLS** with platform verification plus a
  pinned certificate *name* (`SecPolicyCreateSSL` +
  `SecTrustEvaluateWithError`) for the UltraViewer service endpoints;
  the SNI routing label cannot substitute for identity.
- **Host consent is explicit and revocable**: incoming sessions require
  local approval; view-only vs control is a separate grant, re-checked
  per input batch (`isControlAllowed`), and all pressed keys/buttons are
  released when control is revoked or the session ends.
- **Host-side password proof**: the host verifies
  `MD5(nonce + password)` itself (`HostLoginRequest.verify`) — the
  password is never sent to the host, and the nonce blocks replay.
- **Parser hardening against malicious peers**: every inbound format has
  explicit caps — frame/payload lengths (16 MB), zstd decompressed size
  (128 MB), screen dimensions (8192 / 16 Mpx), chat text (64 KB),
  multipart parts — with overflow-safe arithmetic in the pixel buffers.
- **Saved credentials live only in the Keychain** (no UserDefaults/file
  fallback, by design and by test); secrets are not written to logs.
- **Updater integrity**: releases are accepted only from `github.com`,
  and self-install requires a valid designated-requirement signature
  with a stable team identifier; ad-hoc builds cannot self-install and
  fall back to opening the disk image for a manual install.
- **LAN direct listener** is bounded (expiry timer, LAN addresses only)
  and its payloads are encrypted with the session key.

## Inherent to the UltraViewer protocol (cannot be fixed client-side)

- **Legacy ciphers**: the command channel uses 3DES with a SHA1-derived
  key and fixed IV; screen envelopes use AES-CBC without a MAC. This is
  the recovered wire format of UltraViewer itself — changing it breaks
  interoperability with every UltraViewer server and client. Relay legs
  are additionally wrapped in TLS (above).
- **8-digit numeric host password** (~10^8 space): UltraViewer's account
  convention. Online guessing is limited by the relay and the nonce
  challenge, but users should treat the ID+password pair like a key:
  do not publish them. (This fork's planned unattended mode will use a
  separate, longer passphrase for Mac-to-Mac access.)
- **Relay trust**: session setup metadata passes through UltraViewer's
  relay servers, as with the original product.
- **Clipboard sharing defaults to on** (upstream behaviour, matching
  UltraViewer on Windows): during a session, text copied on either side
  is shared with the other side. It can be turned off in Settings;
  the session UI shows its state.

## Ventura build note

This fork's release is ad-hoc signed (no Apple Developer certificate),
so macOS Gatekeeper will warn on first launch; verify downloads against
`SHA256SUMS-Ventura.txt` published with each release.
