import CoreGraphics
import Foundation
import MeshClient
import MeshWebRTC
import WebRTC

/// The app layer's seam over the WebRTC media plane (Phase 3,
/// chunk 4 / M1 part 3b).
///
/// `MeshPeerSession` (MeshWebRTC target) is a concrete class
/// bound to the real libwebrtc objects. The media coordinator
/// only ever talks to this protocol, so its tests drive a fake —
/// the same seam pattern chunks 1–3 used for the server API,
/// the signaling client, and the chat transport. The real
/// `MeshPeerSession` conforms with no adapter code: its public
/// API already matches member for member.
protocol MeshPeerSessioning: AnyObject {
    var role: MeshPeerRole { get }
    var state: MeshPeerConnectionState { get }
    var states: AsyncStream<MeshPeerConnectionState> { get }
    var controlMessages: AsyncStream<Data> { get }
    var onRemoteVideoTrack: (@Sendable (RTCVideoTrack) -> Void)? { get set }

    /// Initiator only: create the offer and start negotiating.
    func start() async throws
    /// Feed one inbound signaling envelope (media plane only —
    /// the coordinator pre-routes, see MeshMediaCoordinator).
    func handleSignal(_ signal: SignalEnvelope)
    /// Queue one encoded control message on `mv-control`.
    func sendControl(_ data: Data)
    /// Host side: create the screen track + capture object.
    /// MUST be called before the peer's offer is fed to
    /// `handleSignal` (the part-2 ordering contract — there is
    /// no renegotiation). Returns nil on repeat calls.
    func makeScreenCapture() -> MeshScreenCapturing?
    /// The local candidate type of the pair carrying traffic
    /// (Direct/Relay badge source).
    func fetchSelectedCandidatePairType() async -> MeshCandidateType?
    /// Flattened getStats entries (link-stats readout source).
    func fetchStatisticsEntries() async -> [MeshStatsEntry]
    /// Idempotent teardown.
    func close()
}

extension MeshPeerSession: MeshPeerSessioning {
    func makeScreenCapture() -> MeshScreenCapturing? {
        // addScreenTrack() is itself idempotent in the core; the
        // facade guards repeat calls so a second capture object
        // can never be stacked on the same track.
        guard screenTrack == nil else { return nil }
        let track = addScreenTrack()
        return RealScreenCapture(capturer: track.capturer)
    }
}

/// The host's screen-capture half of a media session, abstracted
/// so coordinator tests can fake it (the real one drives
/// ScreenCaptureKit, which needs a live display and the Screen
/// Recording permission).
protocol MeshScreenCapturing: AnyObject {
    /// The pixel size actually being streamed, once started —
    /// the input applier maps normalized input against this.
    var streamedSize: MeshDisplaySize? { get }
    /// Fires when the capture dies on its own after a successful
    /// start (display unplugged, permission revoked…). The
    /// coordinator surfaces it in the host status strip.
    var onFailure: ((String) -> Void)? { get set }
    /// Starts capturing the main display. Throws before anything
    /// is captured when no display is available or the system
    /// refuses (e.g. Screen Recording permission missing).
    func startMainDisplay() async throws
    func stop() async
}

/// The real capture: ScreenCaptureKit's main display, capped at
/// 1920×1080 (aspect preserved, even dimensions — the H.264
/// encoder's requirement), 30 fps. Quality / monitor switching
/// is a later part; this is the sensible M1 default.
///
/// `@unchecked Sendable` on the same terms as the core's own
/// classes: the mutable state is written by the coordinator's
/// calls and read back on the main actor; the failure callback
/// is set once, before capture starts.
final class RealScreenCapture: MeshScreenCapturing, @unchecked Sendable {
    static let maxWidth = 1920
    static let maxHeight = 1080
    static let framesPerSecond = 30

    private let source: ScreenCaptureSource
    private(set) var streamedSize: MeshDisplaySize?
    var onFailure: ((String) -> Void)?

    init(capturer: MeshVideoCapturer) {
        source = ScreenCaptureSource(capturer: capturer)
    }

    func startMainDisplay() async throws {
        let displays = try await ScreenCaptureSource.availableDisplays()
        let mainID = CGMainDisplayID()
        guard let display = displays.first(where: { $0.id == mainID })
                ?? displays.first else {
            throw ScreenCaptureError.displayUnavailable(mainID)
        }
        let size = Self.streamSize(width: display.width, height: display.height)
        streamedSize = MeshDisplaySize(width: size.width, height: size.height)
        source.onStateChange = { [weak self] state in
            if case .failed(let message) = state {
                self?.onFailure?(message)
            }
        }
        try await source.start(displayID: display.id,
                               width: size.width, height: size.height,
                               framesPerSecond: Self.framesPerSecond)
    }

    func stop() async {
        await source.stop()
    }

    /// The capture size for a display: native when it fits the
    /// cap, otherwise scaled down to fit with the aspect ratio
    /// preserved; both dimensions forced even and at least 2.
    static func streamSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        let scale = min(1.0, Double(maxWidth) / Double(width),
                        Double(maxHeight) / Double(height))
        let scaledWidth = Int((Double(width) * scale).rounded(.down)) & ~1
        let scaledHeight = Int((Double(height) * scale).rounded(.down)) & ~1
        return (max(2, scaledWidth), max(2, scaledHeight))
    }
}

/// The seam over the host-side input executor, so coordinator
/// tests can observe gating without posting real CGEvents.
/// `MeshInputApplier` (MeshWebRTC) already matches.
protocol MeshInputApplying: AnyObject {
    /// The negotiated gate: while false, planned input is
    /// dropped (and counted) inside the applier.
    var controlAllowed: Bool { get set }
    /// Decode + apply one `mv-control` payload. False when the
    /// payload was malformed.
    @discardableResult
    func apply(data: Data) -> Bool
    /// Release every held key/button (session teardown,
    /// capture-size change, gate revoke).
    func releaseAll()
}

extension MeshInputApplier: MeshInputApplying {}
