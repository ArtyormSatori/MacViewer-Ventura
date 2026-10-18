## MacViewer 0.3.4 for macOS Ventura — v0.3.4-ventura.3

Update + compatibility build for macOS 13 Ventura (Intel + Apple Silicon).

**New in this build**
- Self-update fixed for this fork: when a newer Ventura release exists, the app now detects it, downloads it, verifies the DMG against the published SHA-256 checksums, installs it in place and relaunches — no "unidentified developer" prompt for updates installed this way. (Installing ventura.3 itself still needs the one-time right-click → Open; every update after that is prompt-free.)
- Viewer defaults for controlling a Windows UltraViewer host: remote control is ON as soon as the session connects, and the "Prefer quality" picture preset (70) is applied automatically on connect.
- Everything from ventura.2: bundled Sectigo R46 root (no Keychain import needed), unattended access, VNI/Unicode keyboard modes, Bayer dithering, adaptive host capture pacing.

**Install:** see HUONG_DAN_CAI_DAT.md in this repo; for this build you can skip section 2 (certificate import).

Verified by CI: the full test suite runs before packaging. Use SHA256SUMS-Ventura.txt to verify downloads.
