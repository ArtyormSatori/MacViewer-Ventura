import Foundation
import Testing
@testable import UltraViewerProtocol

/// Live probe: registers with the real UltraViewer relay through the exact
/// production code path (UltraViewerHostSession.start). Runs ONLY when the
/// environment variable MACVIEWER_LIVE_PROBE=1 is set — the dedicated,
/// manually dispatched CI workflow sets it. In every normal test run the
/// probe returns immediately, so the suite stays hermetic.
struct LiveRelayProbeTests {
    @Test("Live relay registration probe", .timeLimit(.minutes(2)))
    func liveRegistration() async throws {
        guard ProcessInfo.processInfo.environment["MACVIEWER_LIVE_PROBE"] == "1" else {
            print("PROBE SKIPPED: MACVIEWER_LIVE_PROBE is not set")
            return
        }
        print("PROBE START: registering with the live UltraViewer relay")
        let request = ClientRegistration.Request(
            deviceIdentity: "0123456789ABCDEF0123456789ABCDEF",
            password: "12345678",
            localAddress: try RelayIPv4Address("192.168.1.10"),
            computerNameUTF8Base64: Data("MacViewer-CI-Probe".utf8).base64EncodedString(),
            clientVersion: "6.6.133",
            macAddress: "02:00:4C:4F:4F:50",
            diskIdentity: "",
            operatingSystem: "0|15|0|0|0|0",
            installerReferral: 0, customPassword: "", usesProxy: false, quickSupportMetadata: "",
            userNameWireValue: "ci-probe", activeSessionID: 0, processSessionID: 0,
            preferredIDText: "0", referralIDText: "0", automaticUpdate: 0,
            systemFolderCreationTicks: "0", programFilesCreationTicks: "0",
            systemVolumeInformationCreationTicks: "0", licenseContext1: "", licenseContext2: "",
            captchaToken: "")
        let session = UltraViewerHostSession()
        let events = try await session.start(configuration: .init(registration: request))
        var registeredID: String?
        for try await event in events {
            print("PROBE EVENT: \(String(describing: event))")
            if case let .registered(id) = event {
                registeredID = id
                break
            }
        }
        print("PROBE RESULT: registeredID = \(registeredID ?? "NONE")")
        #expect(registeredID != nil)
    }
}
