import AppKit
import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

// Tests for the 4.0.2 lag / dead-input fixes at the app layer:
// frame coalescing (FX-1), input-send timeout (FX-3), and the
// encoder resync the adapter performs on a resumed session (FX-7).
@MainActor
struct LagFixTests {
    // MARK: - FX-1: LatestFrameCoalescer

    @Test("Coalescer: a slow consumer receives only the latest frame; superseded frames are counted")
    func coalescerLatestWins() {
        let coalescer = LatestFrameCoalescer<Int>()
        var presented: [Int] = []
        // Frame 1 takes the free presentation slot immediately.
        if case let .present(frame) = coalescer.offer(1) { presented.append(frame) }
        #expect(coalescer.hasAwaitingFrame)
        // Frame 2 queues behind it; frame 3 supersedes frame 2, which
        // is dropped and counted — it is never presented.
        guard case .queued = coalescer.offer(2) else {
            Issue.record("Frame 2 should queue behind the awaiting frame")
            return
        }
        guard case .coalesced = coalescer.offer(3) else {
            Issue.record("Frame 3 should supersede the pending frame 2")
            return
        }
        #expect(coalescer.coalescedDrops == 1)
        // The consumer finishes frame 1 and is handed the LATEST
        // pending frame, not the superseded one.
        if let next = coalescer.consume() { presented.append(next) }
        #expect(presented == [1, 3])
        #expect(coalescer.consume() == nil)
        #expect(!coalescer.hasAwaitingFrame)
        #expect(!coalescer.hasPendingFrame)
    }

    @Test("Coalescer soak: presented plus dropped accounts for every offered frame")
    func coalescerSoakAccounting() {
        let coalescer = LatestFrameCoalescer<Int>()
        var presented: [Int] = []
        // A producer blasting 500 frames at a consumer that takes one
        // frame per 50 offers: the hand-off must stay bounded, and at
        // the end every frame is accounted for exactly once.
        for frame in 1...500 {
            if case let .present(immediate) = coalescer.offer(frame) { presented.append(immediate) }
            if frame % 50 == 0, let next = coalescer.consume() { presented.append(next) }
        }
        while let next = coalescer.consume() { presented.append(next) }
        #expect(presented.count + coalescer.coalescedDrops == 500)
        #expect(coalescer.coalescedDrops > 0)
        // Presentation is monotone and ends at the newest frame:
        // staleness is bounded by the hand-off, not by the blast.
        #expect(presented == presented.sorted())
        #expect(presented.last == 500)
    }

    // MARK: - FX-3: bounded input sends

    @Test("A hung input send times out, surfaces the input error, and control can be re-enabled")
    func inputSendTimeoutFailsAndRecovers() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = LagTestAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: LagTestCredentials(), audioPlayer: LagTestAudio(),
                                    inputSendTimeout: .milliseconds(250))
        model.partnerID = "123456789"
        model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        #expect(model.controlEnabled)

        // The next send parks forever (a send completion lost on a
        // half-open connection — the audit's silent input wedge).
        adapter.suspendNextInput = true
        let hung = RemoteInput.pointerMoved(x: 5, y: 5)
        model.send(hung)
        try await settle { adapter.inputs == [hung] }

        // Without the FX-3 race this state never resolves: no error,
        // no timeout, input dead while video flows. With it, the send
        // is abandoned at the bound and the generation fails through
        // the existing error path.
        try await settleSeconds { model.inputSendTimeouts == 1 }
        try await settleSeconds { adapter.inputs.last == .releaseAll }
        #expect(model.errorMessage != nil)
        #expect(!model.controlEnabled)
        #expect(model.phase == .connected)
        adapter.resumeSuspendedInput()

        // Control can be re-enabled and a fresh drain delivers input.
        try await settleSeconds {
            model.setControlEnabled(true)
            return model.controlEnabled
        }
        let move = RemoteInput.pointerMoved(x: 9, y: 9)
        model.send(move)
        try await settle { adapter.inputs.last == move }
        model.disconnect()
    }

    // MARK: - FX-1/FX-2 at the model: presentation counting under a blast

    @Test("A frame blast does not starve interleaved input, and every presented frame is counted and signalled")
    func frameBlastKeepsInputPrompt() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = LagTestAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: LagTestCredentials(), audioPlayer: LagTestAudio())
        model.partnerID = "123456789"
        model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }

        // 300 frames, with a pointer move interleaved every 25 —
        // the soak shape from the audit: production far above a
        // comfortable presentation rate, input mixed into the flood.
        var frames: [RemoteScreenFrame] = []
        var moves: [RemoteInput] = []
        for index in 1...300 {
            let frame = try makeFrame()
            frames.append(frame)
            adapter.events[0].yield(.frame(frame))
            if index % 25 == 0 {
                let move = RemoteInput.pointerMoved(x: index, y: index)
                moves.append(move)
                model.send(move)
            }
        }
        try await settle { model.presentedFrames == 300 }
        // The screen shows the newest frame, every interleaved input
        // was delivered in order (none waited behind the flood), and
        // the adapter received one consumption signal per frame —
        // the signal that releases ACK pacing in the session (FX-2).
        #expect(model.frame?.id == frames.last?.id)
        #expect(adapter.inputs == moves)
        #expect(adapter.frameConsumptions == 300)
        model.disconnect()
    }

    // MARK: - FX-7: encoder resync mechanism

    @Test("Encoder resync: releaseAll clears the held-button state that would eat the next click after a resume")
    func encoderResyncClearsHeldButton() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        let press = RemoteInput.pointerButton(button: 0, pressed: true, x: 12, y: 12)
        #expect(!encoder.encode(press).isEmpty)
        // While the encoder believes the button is held, a repeated
        // press is swallowed by its held-state guard — exactly the
        // desync H5 describes when the release was lost with the old
        // connection and the same encoder survives a resume.
        #expect(encoder.encode(press).isEmpty)
        // The adapter's resume path encodes releaseAll on the old
        // encoder (and then rebuilds it): the releases are emitted…
        #expect(!encoder.encode(.releaseAll).isEmpty)
        // …and the user's next real press is encoded again.
        #expect(!encoder.encode(press).isEmpty)
    }

    // MARK: - Helpers (mirroring ConnectionModelTests)

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "MacViewerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuite(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }

    private func settle(until predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate(), "Asynchronous model operation did not reach its expected state")
    }

    /// Wall-clock settle for assertions gated on real timers (the
    /// FX-3 send race), where a yield-counted settle can spin through
    /// its whole budget in less than the timeout being tested.
    private func settleSeconds(until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Timed asynchronous operation did not reach its expected state")
    }

    private func makeFrame(width: Int = 2, height: Int = 2) throws -> RemoteScreenFrame {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return RemoteScreenFrame(image: try #require(context.makeImage()))
    }
}

@MainActor
private final class LagTestAdapter: MacViewerSessionAdapter {
    var availability: SessionAvailability { .available }
    var events: [AsyncThrowingStream<RemoteSessionEvent, Error>.Continuation] = []
    var inputs: [RemoteInput] = []
    var frameConsumptions = 0
    var disconnectCount = 0
    var suspendNextInput = false
    var suspendedInput: CheckedContinuation<Void, any Error>?

    func connect(partnerID: String, password: String) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        let pair = AsyncThrowingStream<RemoteSessionEvent, Error>.makeStream()
        events.append(pair.continuation)
        return pair.stream
    }

    func send(_ input: RemoteInput) async throws {
        inputs.append(input)
        if suspendNextInput {
            suspendNextInput = false
            try await withCheckedThrowingContinuation { suspendedInput = $0 }
        }
    }

    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {}
    func setComputerAudioEnabled(_ enabled: Bool) async throws {}
    func noteFrameConsumed() { frameConsumptions += 1 }
    func disconnect() { disconnectCount += 1 }

    func resumeSuspendedInput() {
        suspendedInput?.resume()
        suspendedInput = nil
    }
}

@MainActor
private final class LagTestCredentials: PartnerCredentialStore {
    var values: [String: String] = [:]
    func password(forID identifier: String) throws -> String? { values[identifier] }
    func store(password: String, forID identifier: String) throws { values[identifier] = password }
    func remove(forID identifier: String) throws { values.removeValue(forKey: identifier) }
    func removeAll() throws { values.removeAll() }
}

@MainActor
private final class LagTestAudio: RemoteAudioPlayback {
    var onPlaybackError: ((Swift.Error) -> Void)?
    func setEnabled(_ enabled: Bool) throws {}
    func play(_ pcm: Data) throws {}
    func stop() {}
}
