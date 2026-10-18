import AppKit
import MeshClient
import SwiftUI

/// The Mode 2 (self-hosted mesh) main-window body, UI spec §5.2:
/// This device → Connect → Requests (only when present) → Paired.
/// Before an identity exists it shows the first-run surface (§6.1).
struct MeshModeView: View {
    @ObservedObject var mesh: MeshSessionModel
    /// Opens the shared chat window for a paired device (Phase 3,
    /// chunk 3). Owned by ConnectionView, which owns the windows.
    var onOpenChat: ((MeshSessionModel.PairedDevice) -> Void)?
    @State private var connectID = ""
    @State private var createName = ""
    @State private var inviteCode = ""
    @State private var nameDraft = ""
    @State private var didStart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mesh.phase == .needsIdentity {
                    firstRun
                } else {
                    thisDeviceCard
                    if let controller = mesh.sessionController {
                        MeshSessionBanner(controller: controller)
                    }
                    connectBlock
                    if !mesh.pendingRequests.isEmpty { requestsCard }
                    pairedBlock
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .clipped()
        .task {
            if !didStart {
                didStart = true
                createName = mesh.deviceName
                await mesh.start()
                nameDraft = mesh.deviceName
            }
        }
        .task {
            // While Mode 2 is on screen, keep requests and presence
            // fresh. Registration and signaling are owned by start().
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                await mesh.refreshLists()
            }
        }
    }

    // MARK: First run (§6.1)

    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Self-hosted").font(.system(size: 21, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("Your computers connect directly to each other, peer to peer.",
                      systemImage: "point.3.connected.trianglepath.dotted")
                Label("A rendezvous server only introduces devices; it never sees your screen or input.",
                      systemImage: "server.rack")
                Label("Pairing is invitation-only, and every session is end-to-end encrypted.",
                      systemImage: "lock")
            }
            .font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Device name").font(.callout.weight(.medium))
                TextField("Device name", text: $createName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Invite code").font(.callout.weight(.medium))
                TextField("Invite code", text: $inviteCode)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Text("Only needed when your server requires one for a first registration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = mesh.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await mesh.createIdentity(name: createName, invite: inviteCode) }
            } label: {
                Label("Create identity", systemImage: "person.crop.circle.badge.plus")
                    .frame(minWidth: 180, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mesh.isBusy || createName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
    }

    // MARK: This device (§5.2)

    private var thisDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 20)).foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("THIS DEVICE").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.blue)
                    TextField("Device name", text: $nameDraft)
                        .textFieldStyle(.plain).font(.headline)
                        .onSubmit { Task { await mesh.saveDeviceNameAndRefresh() } }
                }
                Spacer()
                if mesh.isBusy { ProgressView().controlSize(.small) }
            }
            if let meshID = mesh.meshID {
                HStack(spacing: 8) {
                    Text("Mesh ID").font(.callout.weight(.medium))
                    Text(meshID.formatted)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button { copy(meshID.rawValue) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                }
            }
            statusLine
            if mesh.meshID == nil {
                // Identity exists but this server has never registered
                // it (e.g. an invite-gated server). Offer the retry
                // with an invite instead of a dead end.
                HStack(spacing: 8) {
                    TextField("Invite code", text: $inviteCode)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Button("Register with server") {
                        Task { await mesh.createIdentity(name: mesh.deviceName, invite: inviteCode) }
                    }
                    .buttonStyle(.bordered).disabled(mesh.isBusy)
                }
            }
            if case let .offline(message) = mesh.phase {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await mesh.refresh() } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(mesh.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if mesh.phase == .working {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.callout).foregroundStyle(.secondary)
            } else {
                Circle().fill(mesh.isOnline ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(mesh.isOnline ? "Online" : "Offline"))
                    .font(.callout.weight(.medium))
            }
            Text("·").foregroundStyle(.secondary)
            Text(LocalizedStringKey(mesh.isUsingCustomServer ? "Custom server" : "Default server"))
                .font(.callout).foregroundStyle(.secondary)
            if let host = mesh.serverURL.host {
                Text(host).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Connect (§5.2)

    private var connectBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect").font(.headline)
            HStack(spacing: 8) {
                TextField("123 456 789", text: $connectID)
                    .font(.system(size: 15, design: .monospaced))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit { Task { await mesh.connect(toRawID: connectID) } }
                Button("Connect") { Task { await mesh.connect(toRawID: connectID) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(mesh.isBusy || mesh.phase != .ready
                              || connectID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Connecting sends a pairing request. Once the other device approves, it appears under Paired devices.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = mesh.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = mesh.errorMessage, mesh.phase == .ready {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Requests (§5.2)

    private var requestsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Requests").font(.headline)
                Text("(\(mesh.pendingRequests.count))").font(.headline).foregroundStyle(.secondary)
            }
            ForEach(mesh.pendingRequests, id: \.rawValue) { peer in
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 19)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.formatted)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                        Text("wants to pair with this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reject", role: .destructive) { Task { await mesh.reject(peer) } }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Approve") { Task { await mesh.approve(peer) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if peer != mesh.pendingRequests.last { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
    }

    // MARK: Paired (§5.2)

    private var pairedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired devices").font(.headline)
            if mesh.pairedDevices.isEmpty {
                Text("No paired devices yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(mesh.pairedDevices) { device in
                        HStack(spacing: 13) {
                            Circle().fill(device.online == true ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? device.id.formatted)
                                    .font(.system(size: 15, weight: .medium,
                                                  design: device.name == nil ? .monospaced : .default))
                                Text(presenceText(for: device))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.name != nil {
                                Text(device.id.formatted)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let center = mesh.chatCenter {
                                Button { onOpenChat?(device) } label: {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .font(.system(size: 14))
                                        if center.unreadCount(for: device.id) > 0 {
                                            Text("\(center.unreadCount(for: device.id))")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Color.red, in: Capsule())
                                                .offset(x: 8, y: -7)
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help("Chat")
                                .accessibilityLabel("Chat")
                            }
                            if let controller = mesh.sessionController {
                                Button("Connect") {
                                    controller.requestSession(to: device.id, peerName: device.name)
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(!controller.canStartSession)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        if device.id != mesh.pairedDevices.last?.id { Divider().padding(.leading, 37) }
                    }
                }
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presenceText(for device: MeshSessionModel.PairedDevice) -> String {
        if device.online == true { return L("Online") }
        if let lastSeen = device.lastSeen, lastSeen > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(lastSeen))
            return LF("Last seen %@", date.formatted(date: .abbreviated, time: .shortened))
        }
        return L("Offline")
    }

    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// Session state strip shown under the This-device card while a
/// negotiation is pending, active, or just ended (Phase 3, chunk 2).
/// The host side has no session window by design (spec §5.4), so
/// this strip — plus the session window on the viewer side — is
/// where a live session is seen and ended.
private struct MeshSessionBanner: View {
    @ObservedObject var controller: MeshSessionController

    var body: some View {
        switch controller.phase {
        case let .outgoingPending(_, peer, peerName, _):
            strip {
                ProgressView().controlSize(.small)
                Text(LF("Waiting for %@ to answer…", peerName ?? peer.formatted))
                    .font(.callout)
                Spacer()
                Button("Cancel request") { controller.cancelOutgoing() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case let .active(_, peer, peerName, role, _, _):
            strip {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Text(role == .host
                     ? LF("%@ is connected to this device.", peerName ?? peer.formatted)
                     : LF("Connected to %@.", peerName ?? peer.formatted))
                    .font(.callout.weight(.medium))
                Spacer()
                Button("End session", role: .destructive) { controller.endSession() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .ended:
            strip {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(controller.statusMessage ?? L("Session ended"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { controller.dismissEnded() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    private func strip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
    }
}
