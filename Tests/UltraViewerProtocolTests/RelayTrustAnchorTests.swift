import Foundation
import Testing
import Security
import CryptoKit
@testable import UltraViewerProtocol

struct RelayTrustAnchorTests {
    @Test("Bundled Sectigo R46 anchor parses with the expected subject")
    func anchorParses() throws {
        let certificate = try #require(RelayTrustAnchors.certificates.first)
        #expect(RelayTrustAnchors.certificates.count == 1)
        #expect(SecCertificateCopySubjectSummary(certificate) as String?
            == "Sectigo Public Server Authentication Root R46")
    }

    @Test("Bundled anchor matches the published R46 SHA-256 fingerprint")
    func anchorFingerprint() throws {
        let certificate = try #require(RelayTrustAnchors.certificates.first)
        let der = SecCertificateCopyData(certificate) as Data
        #expect(der.count == 1422)
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "7bb647a62aeeac88bf257aa522d01ffea395e0ab45c73f93f65654ec38f25a06")
    }
}
