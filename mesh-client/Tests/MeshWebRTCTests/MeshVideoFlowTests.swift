#if os(macOS)
import CoreVideo
import XCTest
import MeshClient
import MeshWebRTC
import WebRTC

/// End-to-end video proof for M1 part 2: two `MeshPeerSession`s
/// wired back-to-back through `SignalingEnvelope` JSON only
/// (the part-1 harness pattern). The host adds its screen
/// track and pushes SYNTHETIC frames — solid palette colors,
/// a different slot per frame index — through
/// `MeshVideoCapturer`; the viewer's session surfaces the
/// remote track, a probe renderer records every decoded
/// frame, and the test asserts the frames that came through
/// the real H.264 encode/decode path classify back to palette
/// slots that were actually painted (see
/// `SyntheticFramePalette` for why classification, not
/// bit-equality, is the honest check for a lossy codec).
///
/// CI-only: the WebRTC binary target has no Linux slice.
final class MeshVideoFlowTests: XCTestCase {

    private let aID = MeshID(unchecked: "111111111")
    private let bID = MeshID(unchecked: "222222222")

    private final class SessionSlot: @unchecked Sendable {
        var session: MeshPeerSession?
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func with<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private struct ReceivedFrame {
        let width: Int
        let height: Int
        let centerLuma: Int
    }

    /// The framework's real renderer surface (RTCVideoRenderer,
    /// RTCVideoRenderer.h): records each decoded frame's size
    /// and the luma of its center pixel, extracted through the
    /// frame buffer's own `toI420()` conversion.
    private final class RendererProbe: NSObject, RTCVideoRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ReceivedFrame] = []

        var count: Int { lock.withLock { storage.count } }
        var snapshot: [ReceivedFrame] { lock.withLock { storage } }

        func setSize(_ size: CGSize) {}

        func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            let i420 = frame.buffer.toI420()
            let centerIndex = Int(i420.strideY) * (Int(i420.height) / 2)
                + Int(i420.width) / 2
            let luma = Int(i420.dataY[centerIndex])
            lock.withLock {
                storage.append(ReceivedFrame(width: Int(frame.width),
                                             height: Int(frame.height),
                                             centerLuma: luma))
            }
        }
    }

    private func makePair() -> (a: MeshPeerSession, b: MeshPeerSession) {
        let hop = DispatchQueue(label: "mesh.videoflow.testbus",
                                attributes: .concurrent)
        func deliver(_ envelope: SignalingEnvelope, to slot: SessionSlot) {
            guard let json = try? envelope.encodedJSON() else { return }
            hop.async {
                guard let decoded = try? SignalingEnvelope.decodeJSON(json),
                      let from = decoded.from, let kind = decoded.kind,
                      let data = decoded.data,
                      let session = slot.session
                else { return }
                session.handleSignal(SignalEnvelope(from: from, kind: kind, data: data))
            }
        }
        let slotA = SessionSlot()
        let slotB = SessionSlot()
        let a = MeshPeerSession(localID: aID, remoteID: bID, role: .initiator) { envelope in
            deliver(envelope, to: slotB)
        }
        let b = MeshPeerSession(localID: bID, remoteID: aID, role: .responder) { envelope in
            deliver(envelope, to: slotA)
        }
        slotA.session = a
        slotB.session = b
        return (a, b)
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 15,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    /// One solid palette-colored BGRA frame. Bytes are laid
    /// out B,G,R,A per pixel, rows padded to the buffer's
    /// bytes-per-row.
    private func makeSyntheticFrame(index: Int, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let color = SyntheticFramePalette.color(forFrameIndex: index)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            var p = pointer + row * rowBytes
            for _ in 0..<width {
                p[0] = color.blue
                p[1] = color.green
                p[2] = color.red
                p[3] = 255
                p += 4
            }
        }
        return pixelBuffer
    }

    // MARK: - The proof

    func testSyntheticVideoFlowsHostToViewerWithVerifiedContent() async throws {
        let pair = makePair()
        defer {
            pair.a.close()
            pair.b.close()
        }
        let width = 320
        let height = 180

        // Viewer: attach the probe to the remote track the
        // moment the session surfaces it (set before start, so
        // no frame can slip past unrendered).
        let probe = RendererProbe()
        let remoteTrackSeen = Locked(false)
        pair.b.onRemoteVideoTrack = { track in
            track.addRenderer(probe)
            remoteTrackSeen.with { $0 = true }
        }

        // Host: the screen track exists BEFORE the offer, so
        // it is part of the initial negotiation (the layer's
        // documented ordering contract).
        let screen = pair.a.addScreenTrack()
        XCTAssertNotNil(pair.a.screenTrack)

        try await pair.a.start()
        await waitUntil("A connected") { pair.a.state == .connected }
        await waitUntil("B connected") { pair.b.state == .connected }
        await waitUntil("remote video track surfaced") { remoteTrackSeen.with { $0 } }

        // Push palette frames at ~15 fps until the viewer has
        // decoded a solid sample of them (or the deadline
        // passes and the assertions below report the truth).
        var pushed = 0
        var timeStampNs: Int64 = 1_000_000_000
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, probe.count < 8 {
            if let frame = makeSyntheticFrame(index: pushed, width: width, height: height) {
                screen.push(frame, timeStampNs: timeStampNs)
                pushed += 1
            }
            timeStampNs += 66_666_667
            try? await Task.sleep(nanoseconds: 66_666_667)
        }
        XCTAssertGreaterThan(pushed, 0, "the host must have pushed frames")

        let received = probe.snapshot
        print("VIDEO PROBE: pushed=\(pushed) received=\(received.count) "
            + "lumas=\(received.map(\.centerLuma))")
        XCTAssertGreaterThanOrEqual(
            received.count, 5,
            "viewer must decode a real frame stream, got \(received.count) of \(pushed) pushed")
        XCTAssertTrue(
            received.allSatisfy { $0.width == width && $0.height == height },
            "every decoded frame must be \(width)x\(height): "
                + "\(received.map { "\($0.width)x\($0.height)" })")

        // Content honesty: decoded frames' center lumas must
        // classify back to palette slots — and to at least two
        // DISTINCT slots, so a stream stuck at one luma (e.g. a
        // black screen that never carried the pattern) cannot
        // pass.
        let verifiedSlots = received.compactMap {
            SyntheticFramePalette.classify(luma: $0.centerLuma)
        }
        XCTAssertGreaterThanOrEqual(
            verifiedSlots.count, 3,
            "at least 3 decoded frames must classify to a painted palette slot; "
                + "lumas were \(received.map(\.centerLuma))")
        XCTAssertGreaterThanOrEqual(
            Set(verifiedSlots).count, 2,
            "verified frames must cover at least 2 distinct palette slots")

        // The encoder that actually ran: the outbound video
        // stream's codec, resolved from getStats, must be the
        // VideoToolbox H.264 path.
        var negotiatedCodec: String?
        let codecDeadline = Date().addingTimeInterval(10)
        while Date() < codecDeadline {
            let entries = await pair.a.fetchStatisticsEntries()
            if let mime = MeshStatsSelection.outboundVideoCodecMimeType(in: entries) {
                negotiatedCodec = mime
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertEqual(negotiatedCodec, "video/H264",
                       "outbound video must be encoded by the hardware H.264 path")

        // Loopback, as in part 1: the carrying pair is host.
        let pairType = await pair.a.fetchSelectedCandidatePairType()
        XCTAssertEqual(pairType, .host)
    }
}
#endif
