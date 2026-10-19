#if os(macOS)
import XCTest
import WebRTC
import MeshClient

/// M1 part 0 spike (see mode2-phase3/M1_WEBRTC_DECISION.md).
///
/// Two in-process `RTCPeerConnection`s negotiate **using only the
/// mesh client's existing `SignalingEnvelope` codec** as transport:
/// every SDP and ICE payload crosses between the peers as a
/// `SignalingEnvelope` encoded to its wire JSON string and decoded
/// on the other side — the same path the mesh server's WebSocket
/// relay carries in production, minus the network hop.
///
/// Wire forms used (pinned at the codec level by
/// `SignalingPayloadCodecTests` in MeshClientTests):
/// - SDP: kind `.offer` / `.answer`, `data` = the SDP **string**.
/// - ICE: kind `.ice`, `data` = the **object**
///   `{candidate, sdpMid, sdpMLineIndex}` documented in the mesh
///   server protocol — an `RTCIceCandidate` cannot be reconstructed
///   from its `sdp` string alone.
///
/// A creates a data channel before offering; B receives it via
/// `didOpenDataChannel` and echoes every buffer verbatim; A asserts
/// the echo is byte-exact and that at least one ICE candidate
/// crossed the codec in each direction.
///
/// This test can only RUN on macOS (the WebRTC binary target has no
/// Linux slice), i.e. in CI. On Linux the target compiles to nothing.
final class WebRTCSpikeTests: XCTestCase {

    // MARK: - Peer harness

    /// One peer: owns the connection, buffers remote candidates
    /// until the remote description is set (libwebrtc rejects
    /// candidates added earlier), forwards local candidates and
    /// remotely opened channels to test-wired closures.
    private final class SpikePeer: NSObject, RTCPeerConnectionDelegate {
        let pc: RTCPeerConnection
        var onLocalCandidate: ((RTCIceCandidate) -> Void)?
        var onDataChannel: ((RTCDataChannel) -> Void)?

        private let lock = NSLock()
        private var remoteDescriptionSet = false
        private var pendingRemoteCandidates: [RTCIceCandidate] = []
        private var openedChannelCount = 0

        /// How many remotely created channels the framework has
        /// delivered to this peer so far (run-15 probe: distinguishes
        /// "framework never called didOpen" from "harness lost it").
        var channelsOpened: Int {
            lock.lock()
            defer { lock.unlock() }
            return openedChannelCount
        }

        init(factory: RTCPeerConnectionFactory) {
            let config = RTCConfiguration()
            config.iceServers = [] // loopback only: host candidates suffice
            guard let pc = factory.peerConnection(
                with: config,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil,
                                                 optionalConstraints: nil),
                delegate: nil)
            else { fatalError("RTCPeerConnectionFactory returned no peer connection") }
            self.pc = pc
            super.init()
            pc.delegate = self
        }

        func addRemoteCandidate(_ candidate: RTCIceCandidate) {
            lock.lock()
            guard remoteDescriptionSet else {
                pendingRemoteCandidates.append(candidate)
                lock.unlock()
                return
            }
            lock.unlock()
            pc.add(candidate) { _ in }
        }

        func setRemoteDescription(_ description: RTCSessionDescription,
                                  completion: @escaping (Error?) -> Void) {
            pc.setRemoteDescription(description) { [self] error in
                if error == nil {
                    lock.lock()
                    remoteDescriptionSet = true
                    let pending = pendingRemoteCandidates
                    pendingRemoteCandidates = []
                    lock.unlock()
                    for candidate in pending { pc.add(candidate) { _ in } }
                }
                completion(error)
            }
        }

        // RTCPeerConnectionDelegate (required members only)
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            onLocalCandidate?(candidate)
        }
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
            lock.lock()
            openedChannelCount += 1
            lock.unlock()
            onDataChannel?(dataChannel)
        }
    }

    /// B side: echoes every received buffer back on the same channel.
    ///
    /// Instrumented after the run-15 failure (negotiation and A's
    /// channel-open all succeeded, the echo never came back, and the
    /// old code discarded the one signal that could say why — the
    /// `sendData:` result). The counters below localize a break in
    /// the chain didOpen → B receive → B sendData → A receive on a
    /// single CI run: every hop leaves a number behind.
    private final class EchoServer: NSObject, RTCDataChannelDelegate {
        private let lock = NSLock()
        /// B's end of the channel, retained on purpose.
        /// `RTCDataChannel.delegate` is weak (RTCDataChannel.h in the
        /// M155 framework), and nothing else in this harness holds
        /// B's wrapper: the binary carries no ObjC channel-collection
        /// property on RTCPeerConnection, so an unretained wrapper is
        /// free to die with the didOpen stack frame — taking every
        /// later delegate callback with it.
        private var channel: RTCDataChannel?
        private var pendingEchoes: [RTCDataBuffer] = []
        private var attachCount = 0
        private var stateAtAttach: RTCDataChannelState?
        private var receivedCount = 0
        private var statesAtReceive: [RTCDataChannelState] = []
        private var sendResults: [Bool] = []
        private var flushedOnOpen = 0

        /// Wiring entry point, called from SpikePeer's didOpen
        /// forwarding: records that the channel reached the harness
        /// and the state it was in at that moment, retains it, then
        /// takes over as the channel's (weakly held) delegate.
        func attach(_ dataChannel: RTCDataChannel) {
            lock.lock()
            attachCount += 1
            stateAtAttach = dataChannel.readyState
            channel = dataChannel
            lock.unlock()
            dataChannel.delegate = self
        }

        func stats() -> (attachCount: Int, stateAtAttach: RTCDataChannelState?,
                         receivedCount: Int, statesAtReceive: [RTCDataChannelState],
                         sendResults: [Bool], flushedOnOpen: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (attachCount, stateAtAttach, receivedCount,
                    statesAtReceive, sendResults, flushedOnOpen)
        }

        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            // B must not assume its own end is ready just because
            // a buffer arrived: echoes queued while this end was
            // still connecting go out when it reports .open.
            if dataChannel.readyState == .open { flushPendingEchoes() }
        }

        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            let echo = RTCDataBuffer(data: buffer.data, isBinary: buffer.isBinary)
            lock.lock()
            receivedCount += 1
            statesAtReceive.append(dataChannel.readyState)
            let isOpen = dataChannel.readyState == .open
            if !isOpen { pendingEchoes.append(echo) }
            lock.unlock()
            if isOpen { recordSend(dataChannel.sendData(echo)) }
        }

        private func flushPendingEchoes() {
            lock.lock()
            let queued = pendingEchoes
            pendingEchoes = []
            let target = channel
            flushedOnOpen += queued.count
            lock.unlock()
            guard let target else { return }
            for echo in queued { recordSend(target.sendData(echo)) }
        }

        private func recordSend(_ ok: Bool) {
            lock.lock()
            sendResults.append(ok)
            lock.unlock()
        }
    }

    /// A side: reports channel-open and the first received payload.
    private final class EchoClient: NSObject, RTCDataChannelDelegate {
        var onOpen: (() -> Void)?
        var onMessage: ((Data) -> Void)?
        /// Run-15 probe: how many buffers A's delegate was handed,
        /// independent of the expectation (break-d localizer).
        let receivedMessages = Counter()
        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            if dataChannel.readyState == .open { onOpen?() }
        }
        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            receivedMessages.increment()
            onMessage?(buffer.data)
        }
    }

    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Runs one async WebRTC step on the test thread, failing the
    /// test on timeout or error instead of hanging.
    private func awaitStep(_ label: String,
                           _ body: (@escaping (Error?) -> Void) -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        var stepError: Error?
        var finished = false
        body { error in
            stepError = error
            finished = true
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 20), .success,
                       "timed out waiting for \(label)")
        XCTAssertTrue(finished, "\(label) never completed")
        XCTAssertNil(stepError, "\(label) failed: \(String(describing: stepError))")
    }

    // MARK: - The spike

    func testDataChannelEchoNegotiatedThroughSignalingCodec() throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let aID = MeshID(unchecked: "111111111")
        let bID = MeshID(unchecked: "222222222")
        let peerA = SpikePeer(factory: factory)
        let peerB = SpikePeer(factory: factory)

        let iceAtoB = Counter()
        let iceBtoA = Counter()
        let negotiated = expectation(description: "answer applied by A")
        let channelOpened = expectation(description: "A's data channel opened")
        let echoReceived = expectation(description: "A received the echo")

        // The loopback "network": JSON strings produced and consumed
        // ONLY through SignalingEnvelope. Delivery hops queues like a
        // real relay would.
        let hop = DispatchQueue(label: "mesh.spike.signaling", attributes: .concurrent)
        func send(_ envelope: SignalingEnvelope, to peer: SpikePeer) {
            guard let json = try? envelope.encodedJSON() else { return }
            hop.async { receive(json, at: peer) }
        }
        func receive(_ json: String, at peer: SpikePeer) {
            guard let envelope = try? SignalingEnvelope.decodeJSON(json) else { return }
            switch envelope.kind {
            case .offer, .answer:
                guard case .string(let sdpText)? = envelope.data else { return }
                let description = RTCSessionDescription(
                    type: envelope.kind == .offer ? .offer : .answer, sdp: sdpText)
                peer.setRemoteDescription(description) { error in
                    guard error == nil else { return }
                    if envelope.kind == .offer {
                        // Answerer: create + set local answer, ship it back.
                        peer.pc.answer(for: RTCMediaConstraints(
                            mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                            guard let answer else { return }
                            peer.pc.setLocalDescription(answer) { _ in
                                send(SignalingEnvelope(
                                    type: .signal, to: aID, from: bID,
                                    kind: .answer, data: .string(answer.sdp)), to: peerA)
                            }
                        }
                    } else {
                        negotiated.fulfill()
                    }
                }
            case .ice:
                guard case .object(let fields)? = envelope.data,
                      case .string(let candidateSDP)? = fields["candidate"],
                      case .string(let mid)? = fields["sdpMid"],
                      case .number(let index)? = fields["sdpMLineIndex"]
                else { return }
                peer.addRemoteCandidate(RTCIceCandidate(
                    sdp: candidateSDP, sdpMLineIndex: Int32(index), sdpMid: mid))
            case nil:
                return
            }
        }

        func wireICE(_ peer: SpikePeer, from: MeshID, to: MeshID,
                     counter: Counter, destination: SpikePeer) {
            peer.onLocalCandidate = { candidate in
                counter.increment()
                send(SignalingEnvelope(
                    type: .signal, to: to, from: from, kind: .ice,
                    data: .object([
                        "candidate": .string(candidate.sdp),
                        "sdpMid": .string(candidate.sdpMid ?? "0"),
                        "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
                    ])), to: destination)
            }
        }
        wireICE(peerA, from: aID, to: bID, counter: iceAtoB, destination: peerB)
        wireICE(peerB, from: bID, to: aID, counter: iceBtoA, destination: peerA)

        // B: echo whatever arrives on the channel A creates.
        let echoServer = EchoServer()
        peerB.onDataChannel = { channel in echoServer.attach(channel) }

        // A: create the channel BEFORE offering, send on open.
        let payload: Data = {
            var data = Data((0...255).map(UInt8.init))
            data.append(Data("MacViewer mesh spike ✓".utf8))
            return data
        }()
        let echoClient = EchoClient()
        let channelA = peerA.pc.dataChannel(
            forLabel: "echo", configuration: RTCDataChannelConfiguration())
        let channel = try XCTUnwrap(channelA, "A could not create a data channel")
        channel.delegate = echoClient
        var received: Data?
        echoClient.onOpen = {
            channelOpened.fulfill()
            XCTAssertTrue(channel.sendData(RTCDataBuffer(data: payload, isBinary: true)))
        }
        echoClient.onMessage = { data in
            received = data
            echoReceived.fulfill()
        }

        // A offers through the codec; the bus drives the rest.
        awaitStep("create offer") { done in
            peerA.pc.offer(for: RTCMediaConstraints(
                mandatoryConstraints: nil, optionalConstraints: nil)) { offer, error in
                guard let offer, error == nil else { done(error); return }
                peerA.pc.setLocalDescription(offer) { setError in
                    if setError == nil {
                        send(SignalingEnvelope(
                            type: .signal, to: bID, from: aID,
                            kind: .offer, data: .string(offer.sdp)), to: peerB)
                    }
                    done(setError)
                }
            }
        }

        waitForExpectations(timeout: 30)

        // Run-15 probe: walk the echo chain hop by hop so a single
        // CI log names the broken link instead of just "no echo".
        // (a) framework → harness: did B's peer connection deliver
        // the channel at all, and did the echo server attach to it?
        // (b) delivery: did a message reach B's delegate?
        // (c) B's echo: was sendData attempted, and did it accept?
        // (d) return trip: did A's delegate receive anything?
        let bStats = echoServer.stats()
        print("SPIKE PROBE: pcDidOpen B=\(peerB.channelsOpened) "
            + "attach=\(bStats.attachCount) "
            + "stateAtAttach=\(String(describing: bStats.stateAtAttach)) "
            + "B received=\(bStats.receivedCount) "
            + "statesAtReceive=\(bStats.statesAtReceive) "
            + "B echo sendData results=\(bStats.sendResults) "
            + "B flushedOnOpen=\(bStats.flushedOnOpen) "
            + "A received=\(echoClient.receivedMessages.get())")
        XCTAssertEqual(peerB.channelsOpened, 1,
                       "B: peerConnection(_:didOpen:) never fired — the framework "
                       + "never delivered A's channel to B (break a)")
        XCTAssertEqual(bStats.attachCount, 1,
                       "B: channel delivered but the echo server never attached (break a)")
        XCTAssertGreaterThanOrEqual(bStats.receivedCount, 1,
                                    "B: attached in state \(String(describing: bStats.stateAtAttach)) "
                                    + "but no message ever reached B's delegate — the channel "
                                    + "wrapper or its delegate did not survive (break b)")
        XCTAssertFalse(bStats.sendResults.isEmpty,
                       "B: message received but the echo sendData was never attempted (break c)")
        XCTAssertTrue(bStats.sendResults.allSatisfy { $0 },
                      "B: echo sendData returned \(bStats.sendResults) — false means the send "
                      + "was rejected (states at receive: \(bStats.statesAtReceive)) (break c)")
        XCTAssertEqual(echoClient.receivedMessages.get(), 1,
                       "A: B's echo sendData accepted but A's delegate received nothing (break d)")

        XCTAssertEqual(received, payload, "echo must be byte-exact")
        XCTAssertGreaterThanOrEqual(iceAtoB.get(), 1, "no ICE candidate crossed A→B through the codec")
        XCTAssertGreaterThanOrEqual(iceBtoA.get(), 1, "no ICE candidate crossed B→A through the codec")

        channel.close()
        peerA.pc.close()
        peerB.pc.close()
    }
}
#endif
