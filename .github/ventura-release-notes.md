## MacViewer 0.3.4 for macOS Ventura — v0.3.4-ventura.2

Feature + compatibility update for macOS 13 Ventura (Intel + Apple Silicon).

**New in this build**
- The app now bundles the Sectigo R46 root certificate: install and connect right away — no Keychain certificate import needed (that step was only for ventura.1).
- Unattended access: auto-approve after correct password proof, optional launch-at-login, and sleep prevention while sharing.
- Keyboard: new VNI Vietnamese and Unicode input modes next to the classic US keycode mode (Settings → Keyboard).
- Smoother picture: Bayer dithering for the protocol's 16-bit color, and adaptive host capture pacing (50–1000 ms instead of a fixed 250 ms).

**Install:** see HUONG_DAN_CAI_DAT.md in this repo; for this build you can skip section 2 (certificate import).

Verified by CI: the full test suite (including a test pinning the bundled R46 certificate's SHA-256 fingerprint) runs before packaging. Use SHA256SUMS-Ventura.txt to verify downloads.
