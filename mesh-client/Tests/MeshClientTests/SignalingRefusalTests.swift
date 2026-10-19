import XCTest
@testable import MeshClient

/// Refusal correlation (core-fixes part): the server echoes the
/// refused envelope's client-supplied marker as `ref` on its error
/// frames, and `MeshSignalingClient` publishes it alongside the
/// typed error on `serverRefusals`, so a consumer with several
/// sends in flight can attribute the refusal exactly.
final class SignalingRefusalTests: XCTestCase {

    // MARK: Envelope codec

    func testErrorFrameWithRefDecodes() throws {
        // The exact frame shape the server now emits for a refused
        // chat envelope (see signalRef in server.go).
        let wire = #"{"type":"error","code":"not_paired","to":"987654321","ref":"9F3C1A2E-1111-4222-8333-444455556666"}"#
        let envelope = try SignalingEnvelope.decodeJSON(wire)
        XCTAssertEqual(envelope.type, .error)
        XCTAssertEqual(envelope.code, "not_paired")
        XCTAssertEqual(envelope.ref, "9F3C1A2E-1111-4222-8333-444455556666")
    }

    func testErrorFrameWithoutRefDecodesAsNil() throws {
        // A frame from a server that predates the field.
        let envelope = try SignalingEnvelope.decodeJSON(
            #"{"type":"error","to":"987654321","code":"peer_offline"}"#)
        XCTAssertEqual(envelope.code, "peer_offline")
        XCTAssertNil(envelope.ref)
    }

    func testEnvelopeEncodingOmitsNilRef() throws {
        let bare = SignalingEnvelope(type: .error, code: "not_paired")
        XCTAssertFalse(try bare.encodedJSON().contains("\"ref\""))
        let marked = SignalingEnvelope(type: .error, code: "not_paired", ref: "msg-1")
        XCTAssertTrue(try marked.encodedJSON().contains(#""ref":"msg-1""#))
        XCTAssertEqual(try SignalingEnvelope.decodeJSON(marked.encodedJSON()), marked)
    }

    // MARK: Client streams

    func testSignalingClientPublishesCorrelatedRefusals() async throws {
        let transport = ScriptedTransport()
        // Handshake frames, buffered by the fake until connect()
        // consumes them in order.
        transport.inject(#"{"type":"nonce","nonce":"AAECAwQFBgc"}"#)
        transport.inject(#"{"type":"auth_ok","mesh_id":"123456789"}"#)

        let client = MeshSignalingClient(
            serverBaseURL: URL(string: "http://127.0.0.1:18734")!,
            identity: MeshIdentity(),
            meshID: try MeshID(validating: "123456789"),
            transport: transport)
        try await client.connect()

        let errors = LockedList<MeshError>()
        let refusals = LockedList<SignalingRefusal>()
        let errorTask = Task { for await e in client.serverErrors { errors.append(e) } }
        let refusalTask = Task { for await r in client.serverRefusals { refusals.append(r) } }
        defer { errorTask.cancel(); refusalTask.cancel() }

        // One refusal with a marker, one without (media-plane
        // refusal / older server shape): both streams see both,
        // and only the first carries the correlation.
        transport.inject(#"{"type":"error","code":"peer_offline","to":"987654321","ref":"msg-0001"}"#)
        transport.inject(#"{"type":"error","code":"not_paired","to":"987654321"}"#)

        await settle("both refusals published") { refusals.snapshot.count == 2 }
        XCTAssertEqual(refusals.snapshot, [
            SignalingRefusal(error: .peerOffline, ref: "msg-0001"),
            SignalingRefusal(error: .notPaired, ref: nil),
        ])
        // The plain error stream is unchanged: same errors, no ref.
        await settle("both errors published") { errors.snapshot.count == 2 }
        XCTAssertEqual(errors.snapshot, [.peerOffline, .notPaired])

        await client.close()
    }

    private func settle(_ description: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting: \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Append-only lock-protected list for collecting stream values
/// from test tasks (stream consumers are single, so exactly one
/// collector task per stream appends here).
private final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func append(_ value: T) { lock.withLock { values.append(value) } }
    var snapshot: [T] { lock.withLock { values } }
}

/// A `WebSocketTransport` that plays back injected frames and
/// records sends; the signaling handshake is driven entirely by
/// what the test injects.
private final class ScriptedTransport: WebSocketTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var sentStorage: [String] = []

    init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        incoming = AsyncThrowingStream { cont = $0 }
        continuation = cont
    }

    func connect(to url: URL) async throws {}
    func send(text: String) async throws {
        lock.withLock { sentStorage.append(text) }
    }
    func close() async { continuation.finish() }

    func inject(_ text: String) { continuation.yield(text) }
    var sent: [String] { lock.withLock { sentStorage } }
}
