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
            onDataChannel?(dataChannel)
        }
    }

    /// B side: echoes every received buffer back on the same channel.
    private final class EchoServer: NSObject, RTCDataChannelDelegate {
        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
            _ = dataChannel.sendData(RTCDataBuffer(data: buffer.data, isBinary: buffer.isBinary))
        }
    }

    /// A side: reports channel-open and the first received payload.
    private final class EchoClient: NSObject, RTCDataChannelDelegate {
        var onOpen: (() -> Void)?
        var onMessage: ((Data) -> Void)?
        func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
            if dataChannel.readyState == .open { onOpen?() }
        }
        func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
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
        peerB.onDataChannel = { channel in channel.delegate = echoServer }

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

        XCTAssertEqual(received, payload, "echo must be byte-exact")
        XCTAssertGreaterThanOrEqual(iceAtoB.get(), 1, "no ICE candidate crossed A→B through the codec")
        XCTAssertGreaterThanOrEqual(iceBtoA.get(), 1, "no ICE candidate crossed B→A through the codec")

        channel.close()
        peerA.pc.close()
        peerB.pc.close()
    }
}
#endif
