import Foundation
import Security

/// Additional trust anchor for the UltraViewer relay connection.
///
/// The relay's certificate chain ends at Sectigo Public Server
/// Authentication Root R46. Apple only added that root to the system trust
/// store in macOS 14.4, so on macOS 13 (Ventura) platform verification of the
/// relay cannot build the chain and the connection fails even though the
/// certificate is genuine. The app therefore carries the root itself and
/// adds it as an *additional* anchor when verifying the relay; the system
/// anchors and the certificate-name policy still apply unchanged.
///
/// The embedded certificate is the self-signed R46 root (1,422 bytes DER),
/// SHA-256 fingerprint
/// 7B:B6:47:A6:2A:EE:AC:88:BF:25:7A:A5:22:D0:1F:FE:A3:95:E0:AB:45:C7:3F:93:
/// F6:56:54:EC:38:F2:5A:06.
public enum RelayTrustAnchors {
    /// The bundled anchor certificates, parsed once.
    public static let certificates: [SecCertificate] = {
        guard let der = Data(base64Encoded: sectigoR46Base64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return []
        }
        return [certificate]
    }()

    /// Adds the bundled anchors to a trust object while keeping the system
    /// anchors in force. Best effort: returns false when there is nothing to
    /// add or the Security calls fail, leaving platform behaviour unchanged.
    @discardableResult
    public static func apply(to trust: SecTrust) -> Bool {
        let anchors = certificates
        guard !anchors.isEmpty else { return false }
        guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess else {
            return false
        }
        return SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess
    }

    /// Base64 of the DER encoding of the Sectigo Public Server
    /// Authentication Root R46 certificate.
    private static let sectigoR46Base64 = """
MIIFijCCA3KgAwIBAgIQdY39i658BwD6qSWn4cetFDANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQG
EwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBT
ZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNNDYwMzIxMjM1
OTU5WjBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1T
ZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwggIiMA0GCSqGSIb3
DQEBAQUAA4ICDwAwggIKAoICAQCTvtU2UnXYASOgHEdCSe5jtrch/cSV1UgrJnwUUxDaef0rty2k
1Cz66jLdScK5vQ9IPXtamFSvnl0xdE8H/FAh3aTPaE8bEmNtJZlMKpnzSDBh+oF8HqcIStw+Kxwf
GExxqjWMrfhu6DtK2eWUAtaJhBOqbchPM8xQljeSM9xfiOefVNlI8JhD1mb9nxc4Q8UBUQvX4yMP
FF1bFOdLvt30yNoDN9HWOaEhUTCDsG3XME6WW5HwcCSrv0WBZEMNvSE6Lzzpng3LILVCJ8zab5vu
ZDCQOc2TZYEhMbUjUDM3IuM47fgxMMxF/mL50V0yeUKH32rMVhlATc6qu/m1dkmU8Sf4kaWD5Qaz
Yw6A3OASVYCmO2a0OYctyPDQ0RTp5A1NDvZdV3LFOxxHVp3i1fuBYYzMTYCQNFu31xR13NgESJ/A
wSiItOkcyqex8Va3e0lMWeUgFaiEAin6OJRpmkkGj80feRQXEgyDet4fsZfu+Zd4KKTIRJLpfSYF
plhym3kT2BFfrsU4YjRosoYwjviQYZ4ybPUHNs2iTG7sijbt8uaZFURww3y8nDnAtOFr94MlI1fZ
EoDlSfB1D++N6xybVCi0ITz8fAr/73trdf+LHaAZBav6+CuBQug4urv7qv094PPK306Xlynt8xhW
6aWWrL3DkJiy4Pmi1KZHQ3xtzwIDAQABo0IwQDAdBgNVHQ4EFgQUVnNYZJX5khqwEioEYnmhQBWI
IUkwDgYDVR0PAQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAC9c
mTz8Bl6MlC5w6tIyMY208FHVvArzZJ8HXtXBc2hkeqK5Duj5XYUtqDdFqij0lgVQYKlJfp/imTYp
E0RHap1VIDzYm/EDMrraQKFz6oOht0SmDpkBm+S8f74TlH7Kph52gDY9hAaLMyZlbcp+nv4fjFg4
exqDsQ+8FxG75gbMY/qB8oFM2gsQa6H61SilzwZAFv97fRheORKkU55+MkIQpiGRqRxOF3yEvJ+M
0ejf5lG5Nkc/kLnHvALcWxxPDkjBJYOcCj+esQMzEhonrPcibCTRAUH4WAP+JWgiH5paPHxsnnVI
84HxZmduTILA7rpXDhjvLpr3Etiga+kFpaHpaPi8TD8SHkXoUsCjvxInebnMMTzD9joiFgOgyY9m
pFuiTdaBJQbpdqQACj7LzTWb4OE4y2BThihCQRxEV+ioratF4yUQvNs+ZUH7G6aXD+u5dHn5Hrwd
Vw1Hr8Mvn4dGp+smWg9WY7ViYG4A++MnESLn/pmPNPW56MORcr3Ywx65LvKRRFHQV80MNNVIIb/b
E/FmJUNS0nAiNs2fxBx1IK1jcmMGDw4nztJqDby1ORrp0XZ60Vzk50lJLVU3aPAaOpg+VBeHVOmm
J1CJeyAvP/+/oYtKR5j/K3tJPsMpRmAYQqszKbrAKbkTidOIijlBO8n9pu0f9GBj39ItVQGL
"""
}
