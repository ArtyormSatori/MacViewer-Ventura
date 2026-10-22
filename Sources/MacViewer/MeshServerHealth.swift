import Foundation
import MeshClient

/// Availability of the configured mesh server, as Mode 2 can prove
/// it (redesign spec §3.2). Every case is something the app actually
/// observed: a health probe, a registration answer, or a failed
/// attempt — never a guess.
enum MeshServerAvailability: Equatable {
    /// Nothing probed yet in this run.
    case unknown
    /// A health probe is in flight.
    case checking
    /// The server answered: the health probe passed, or a
    /// registration just succeeded against it.
    case online
    /// The BUILT-IN DEFAULT server's health probe failed. Shipped
    /// installs are expected to sit here until the project deploys
    /// the server at the default address (spec §3.3) — this is an
    /// honest state to present quietly, not an error.
    case defaultNotAvailable
    /// A custom server could not be reached.
    case unreachable
    /// The server itself refused a registration because it requires
    /// an invite code. Only ever set from that actual refusal.
    case inviteRequired
}

/// The outcome of a personal-server connection test (spec §3.4a).
/// Deliberately narrow: it reports only what the probe proved.
enum MeshConnectionTestOutcome: Equatable {
    /// The server answered its health endpoint; `latencyMilliseconds`
    /// is the measured round trip of that probe.
    case reachable(latencyMilliseconds: Int)
    /// No MacViewer server answered at the address.
    case unreachable
    /// The server signaled that registration requires an invite.
    /// The production probe cannot learn this without side effects
    /// (a registration attempt would create a device on the server),
    /// so it never fabricates it; the case exists so any probe that
    /// CAN prove it — and the session model's registration path,
    /// which hears the real refusal — share one honest vocabulary.
    case inviteRequired
}

/// Seam for the personal-server connection test, so the Settings
/// frame's logic is unit-testable without a network.
protocol MeshServerConnectionTesting: Sendable {
    func testConnection(to url: URL) async -> MeshConnectionTestOutcome
}

/// Production connection tester: a single `GET /healthz` against the
/// candidate address, timed. It proves reachability and latency only
/// — it does NOT claim anything about the server's registration
/// policy (that cannot be probed without registering) and there is
/// no TURN leg to report (the current server has none).
struct MeshHealthConnectionTester: MeshServerConnectionTesting {
    /// Injectable so tests can drive the tester without a network.
    var healthCheck: @Sendable (URL) async -> Bool = { url in
        await MeshServerClient(baseURL: url).health()
    }

    func testConnection(to url: URL) async -> MeshConnectionTestOutcome {
        let start = ContinuousClock.now
        guard await healthCheck(url) else { return .unreachable }
        let elapsed = ContinuousClock.now - start
        let milliseconds = Int(elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return .reachable(latencyMilliseconds: max(0, milliseconds))
    }
}
