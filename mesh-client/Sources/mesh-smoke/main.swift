import Foundation
import MeshClient
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// mesh-smoke: drives one mesh device through the control-plane flows
// against a real mesh server. run-smoke.sh orchestrates two devices
// (separate identity directories) through register -> pair -> signal
// and asserts the PASS lines printed here.

struct Options {
    var values: [String: String] = [:]
    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), index + 1 < args.count {
                values[String(arg.dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
    }
    func require(_ key: String) throws -> String {
        guard let value = values[key] else {
            throw MeshError.transport("missing --\(key)")
        }
        return value
    }
    func url(_ key: String) throws -> URL {
        let raw = try require(key)
        guard let url = URL(string: raw) else {
            throw MeshError.transport("bad URL for --\(key): \(raw)")
        }
        return url
    }
}

struct Device {
    let store: FileMeshIdentityStore
    let identity: MeshIdentity
    let meshID: MeshID
    let record: FilePairingRecord

    var restClient: MeshServerClient {
        MeshServerClient(baseURL: serverURL, pairingRecord: record)
    }

    let serverURL: URL

    static func load(server: URL, dir: URL) throws -> Device {
        let store = FileMeshIdentityStore(directory: dir)
        guard let identity = try store.loadIdentity() else {
            throw MeshError.transport("no identity in \(dir.path) — run register first")
        }
        guard let meshID = try store.loadMeshID() else {
            throw MeshError.transport("no mesh-id in \(dir.path) — run register first")
        }
        return Device(store: store, identity: identity, meshID: meshID,
                      record: FilePairingRecord(directory: dir, server: server), serverURL: server)
    }
}


/// Writes one output line unbuffered: run-smoke.sh polls the listener's
/// log for PASS lines while the process is still alive, and stdio
/// buffering would hide them until exit.
func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func nextSignal(from client: MeshSignalingClient, timeoutSeconds: Double = 30) async throws -> SignalEnvelope {
    try await withThrowingTaskGroup(of: SignalEnvelope.self) { group in
        group.addTask {
            for await signal in client.signals {
                return signal
            }
            throw MeshError.connectionClosed
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            throw MeshError.transport("timed out waiting for a signal envelope")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

func stringPayload(_ value: JSONValue) -> String? {
    if case .string(let text) = value { return text }
    return nil
}

func run() async throws {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        throw MeshError.transport("usage: mesh-smoke <register|pair-request|pair-approve|pair-list|presence|signal-listen|signal-send> [options]")
    }
    let command = args[1]
    let options = Options(Array(args.dropFirst(2)))
    let server = try options.url("server")
    let dir = URL(fileURLWithPath: try options.require("dir"))

    switch command {
    case "register":
        let name = try options.require("name")
        let invite = options.values["invite"] ?? ""
        let store = FileMeshIdentityStore(directory: dir)
        let identity = try MeshIdentity.loadOrCreate(using: store)
        let client = MeshServerClient(baseURL: server, pairingRecord: FilePairingRecord(directory: dir, server: server))
        // A device that already has a Mesh ID re-registers with no
        // invite: the server returns the same ID for a known key.
        let known = try store.loadMeshID()
        let meshID = try await client.register(
            identity: identity, name: name, invite: known == nil ? invite : "")
        try store.saveMeshID(meshID)
        emit("PASS register mesh_id=\(meshID.rawValue) name=\(name)")

    case "pair-request":
        let device = try Device.load(server: server, dir: dir)
        let peer = try MeshID(validating: options.require("peer"))
        let result = try await device.restClient.requestPairing(
            identity: device.identity, meshID: device.meshID, peer: peer)
        emit("PASS pair-request from=\(device.meshID.rawValue) to=\(peer.rawValue) status=\(result.rawValue)")

    case "pair-approve":
        let device = try Device.load(server: server, dir: dir)
        let peer = try MeshID(validating: options.require("peer"))
        let pending = try await device.restClient.listPendingPairings(
            identity: device.identity, meshID: device.meshID)
        guard pending.contains(peer) else {
            throw MeshError.transport("peer \(peer.rawValue) not in pending list \(pending.map(\.rawValue))")
        }
        emit("PASS pair-pending from=\(peer.rawValue)")
        try await device.restClient.approvePairing(
            identity: device.identity, meshID: device.meshID, peer: peer)
        emit("PASS pair-approve peer=\(peer.rawValue)")

    case "pair-list":
        let record = FilePairingRecord(directory: dir, server: server)
        let peers = record.pairedDevices()
        emit("PASS pair-listed peers=\(peers.map(\.rawValue).joined(separator: ","))")

    case "presence":
        let target = try MeshID(validating: options.require("id"))
        let expect = try options.require("expect")
        let client = MeshServerClient(baseURL: server)
        let presence = try await client.presence(of: target)
        let expectedOnline = expect == "online"
        guard presence.online == expectedOnline else {
            throw MeshError.transport(
                "presence for \(target.rawValue): online=\(presence.online), expected \(expect)")
        }
        emit("PASS presence mesh_id=\(target.rawValue) online=\(presence.online)")

    case "signal-listen":
        let device = try Device.load(server: server, dir: dir)
        let expectedFrom = try MeshID(validating: options.require("from"))
        let expectData = try options.require("expect-data")
        let replyData = try options.require("reply-data")
        let signaling = MeshSignalingClient(
            serverBaseURL: server, identity: device.identity, meshID: device.meshID)
        try await signaling.connect()
        emit("PASS signal-connected mesh_id=\(device.meshID.rawValue)")
        let signal = try await nextSignal(from: signaling)
        guard signal.from == expectedFrom, signal.kind == .offer,
              stringPayload(signal.data) == expectData else {
            throw MeshError.transport(
                "unexpected signal: from=\(signal.from.rawValue) kind=\(signal.kind.rawValue) data=\(signal.data)")
        }
        emit("PASS signal-received from=\(signal.from.rawValue) kind=offer data=\(expectData)")
        try await signaling.sendSignal(to: signal.from, kind: .answer, data: .string(replyData))
        emit("PASS signal-replied to=\(signal.from.rawValue) kind=answer")
        // The envelope arrived through the grant-gated relay, which
        // proves the pairing server-side; record it locally.
        device.record.notePaired(signal.from)
        await signaling.close()

    case "signal-send":
        let device = try Device.load(server: server, dir: dir)
        let peer = try MeshID(validating: options.require("to"))
        let data = try options.require("data")
        let expectReply = try options.require("expect-reply")
        let signaling = MeshSignalingClient(
            serverBaseURL: server, identity: device.identity, meshID: device.meshID)
        try await signaling.connect()
        emit("PASS signal-connected mesh_id=\(device.meshID.rawValue)")
        try await signaling.sendSignal(to: peer, kind: .offer, data: .string(data))
        emit("PASS signal-sent to=\(peer.rawValue) kind=offer")
        let reply = try await nextSignal(from: signaling)
        guard reply.from == peer, reply.kind == .answer,
              stringPayload(reply.data) == expectReply else {
            throw MeshError.transport(
                "unexpected reply: from=\(reply.from.rawValue) kind=\(reply.kind.rawValue) data=\(reply.data)")
        }
        emit("PASS signal-reply-received from=\(reply.from.rawValue) kind=answer data=\(expectReply)")
        device.record.notePaired(peer)
        await signaling.close()

    default:
        throw MeshError.transport("unknown subcommand: \(command)")
    }
}

Task {
    do {
        try await run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()
