<div align="center">

# MacViewer for macOS 13 Ventura

**Control a Windows machine running UltraViewer from your Ventura Mac.**

[Vietnamese (primary documentation)](README.md) · **English**

### [Download the latest Ventura build](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)

</div>

---

This repository is a fork of [DeanOpen/MacViewer](https://github.com/DeanOpen/MacViewer) (upstream 0.3.4) patched to run on **macOS 13 Ventura** — upstream requires macOS 14. All upstream features are preserved.

Differences from upstream:

- Runs on macOS 13 Ventura (Intel + Apple Silicon universal build).
- The Sectigo R46 root used by UltraViewer's relay is bundled in the app (Ventura's trust store predates it), so no Keychain certificate import is needed.
- Remote control is enabled by default when a session connects, and the "Prefer quality" picture preset is applied automatically.
- In-app self-update verifies downloads against the published SHA-256 checksums and installs without the Gatekeeper "unidentified developer" prompt (from ventura.3 onward; the first install of ventura.3 still needs one right-click → Open).
- Unattended access for the Mac-as-host direction, VNI/Unicode keyboard modes, Bayer dithering and adaptive host capture pacing.

Full documentation is in Vietnamese: install guide [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md), porting notes [VENTURA.md](VENTURA.md), security audit [SECURITY_AUDIT.md](SECURITY_AUDIT.md), roadmap [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md).

This is an unofficial open-source project, not affiliated with UltraViewer. MIT license (see [LICENSE](LICENSE)); third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The `8bit.dat` data file originates from UltraViewer and is not MIT-licensed.
