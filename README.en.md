# MacViewer Ventura

An UltraViewer client for macOS — control a Windows machine from your Mac, and vice versa. Fork of [MacViewer 0.3.4](https://github.com/DeanOpen/MacViewer) by DeanOpen, patched to run on **macOS 13 Ventura and later** (Intel + Apple Silicon).

[Download the latest release](https://github.com/ArtyormSatori/MacViewer-Ventura/releases/latest)

Differences from upstream: deployment target macOS 13; the Sectigo R46 root used by UltraViewer's relay is bundled as an additional trust anchor (Ventura's trust store predates it); remote control and the "Prefer quality" preset are on by default at connect; checksum-verified in-app self-update that strips quarantine from the staged copy (no Gatekeeper prompt for updates, from ventura.3); unattended access for the host direction; VNI/Unicode keyboard modes; Bayer dithering and adaptive host capture pacing; Keychain items stored as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Product name is **MacViewer Ventura**, versioned 4.0+ on the unchanged 0.3.4 base.

Full documentation is in Vietnamese: [README.md](README.md) · install guide [HUONG_DAN_CAI_DAT.md](HUONG_DAN_CAI_DAT.md) · porting notes [VENTURA.md](VENTURA.md) · security audit [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

Unofficial open-source project, not affiliated with UltraViewer. MIT license; third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the `8bit.dat` data file originates from UltraViewer and is not MIT-licensed.
