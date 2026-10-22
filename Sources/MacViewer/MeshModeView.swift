import AppKit
import MeshClient
import SwiftUI

/// The Mode 2 (self-hosted mesh) main-window body, UI spec §5.2:
/// This device → Connect → Requests (only when present) → Paired.
/// Before an identity exists it shows the first-run surface (§6.1).
struct MeshModeView: View {
    @ObservedObject var mesh: MeshSessionModel
    /// One-shot focus requests for the Connect field, raised by
    /// the Devices & History library's paired-devices empty state.
    @ObservedObject var connectFocus: MeshConnectFocusRequest
    /// Opens the shared chat window for a paired device (Phase 3,
    /// chunk 3). Owned by ConnectionView, which owns the windows.
    var onOpenChat: ((MeshSessionModel.PairedDevice) -> Void)?
    @State private var connectID = ""
    @State private var createName = ""
    @State private var nameDraft = ""
    @State private var didStart = false
    @StateObject private var inviteSheet = MeshInviteSheetModel()
    @FocusState private var connectFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mesh.phase == .needsIdentity {
                    firstRun
                } else {
                    thisDeviceCard
                    if let controller = mesh.sessionController {
                        MeshSessionBanner(controller: controller,
                                          media: mesh.mediaCoordinator)
                    }
                    connectBlock
                    if !mesh.pendingRequests.isEmpty { requestsCard }
                    pairedBlock
                }
            }
            .frame(maxWidth: MainWindowLayout.contentMaxWidth)
            .padding(.horizontal, MainWindowLayout.contentHorizontalPadding)
            .padding(.vertical, MainWindowLayout.contentVerticalPadding)
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
        .onAppear {
            if connectFocus.consumePending() { connectFieldFocused = true }
        }
        .onChange(of: connectFocus.generation) { _ in
            if connectFocus.consumePending() { connectFieldFocused = true }
        }
        .onChange(of: mesh.serverAvailability) { availability in
            // §3.5, first door: a real invite refusal raises the
            // one contextual sheet — exactly once, because
            // `present()` is a no-op while the sheet is up.
            if availability == .inviteRequired { inviteSheet.present() }
        }
        .sheet(isPresented: inviteSheetPresented) {
            MeshInviteSheetView(model: inviteSheet, mesh: mesh)
        }
    }

    private var inviteSheetPresented: Binding<Bool> {
        Binding(
            get: { inviteSheet.isPresented },
            set: { presented in
                if presented { inviteSheet.present() } else { inviteSheet.cancel() }
            })
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
            if let error = mesh.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(AppColor.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await mesh.createIdentity(name: createName, invite: "") }
            } label: {
                Label("Create identity", systemImage: "person.crop.circle.badge.plus")
                    .frame(minWidth: 180, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mesh.isBusy || createName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
    }

    // MARK: This device (§5.2)

    private var thisDeviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 20)).foregroundStyle(AppColor.accent)
                    .frame(width: 36, height: 36)
                    .background(AppColor.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.card))
                VStack(alignment: .leading, spacing: 4) {
                    Text("THIS DEVICE").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(AppColor.accent)
                    TextField("Device name", text: $nameDraft)
                        .textFieldStyle(.plain).font(.headline)
                        .onSubmit { Task { await mesh.saveDeviceNameAndRefresh() } }
                }
                Spacer()
                if mesh.isBusy { ProgressView().controlSize(.small) }
            }
            if let meshID = mesh.meshID {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("Mesh ID").font(AppFont.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: Space.small) {
                        Text(meshID.formatted)
                            .font(AppFont.meshIDHero)
                            .textSelection(.enabled)
                        Button { copy(meshID.rawValue) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                        .accessibilityLabel("Copy")
                    }
                }
            }
            statusLine
            serverGuidanceView
            if case let .offline(message) = mesh.phase, serverGuidance.kind == .none {
                // Offline states with no server-specific guidance
                // keep the existing behavior (§3.6): the plain
                // message and one retry.
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(AppColor.statusError)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await mesh.refresh() } }
                    .buttonStyle(.bordered).controlSize(AppButtonStyle.rowControlSize)
                    .disabled(mesh.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
    }

    private var serverGuidance: MeshServerGuidance {
        .presentation(isCustom: mesh.isUsingCustomServer,
                      availability: mesh.serverAvailability,
                      phase: mesh.phase)
    }

    /// The §3.3 server-state surface under the status line: one
    /// quiet explanation and only the actions that state calls
    /// for. No dialogs, no red — a failed server is a state to
    /// describe and a way forward, not an error to announce.
    @ViewBuilder
    private var serverGuidanceView: some View {
        let guidance = serverGuidance
        if guidance.kind != .none {
            VStack(alignment: .leading, spacing: Space.small) {
                if let explanationKey = guidance.explanationKey {
                    Text(LocalizedStringKey(explanationKey))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if guidance.showsUseDefaultServer {
                    Text("Switching servers changes which pairings you see. Pairings on the other server are kept and come back when you switch back.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.small) {
                    if guidance.showsOpenServerSettings {
                        Button("Open personal server settings") { openServerSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(AppButtonStyle.rowControlSize)
                    }
                    if guidance.showsRetry {
                        Button("Try again") { Task { await mesh.refresh() } }
                            .buttonStyle(.bordered)
                            .controlSize(AppButtonStyle.rowControlSize)
                            .disabled(mesh.isBusy)
                    }
                    if guidance.showsUseDefaultServer {
                        Button("Use default server") { Task { await mesh.switchToDefaultServer() } }
                            .buttonStyle(.bordered)
                            .controlSize(AppButtonStyle.rowControlSize)
                            .disabled(mesh.isBusy)
                    }
                    if guidance.showsEnterInviteCode {
                        Button("Enter invite code") { inviteSheet.present() }
                            .buttonStyle(.bordered)
                            .controlSize(AppButtonStyle.rowControlSize)
                            .disabled(mesh.isBusy)
                    }
                }
            }
        }
    }

    /// Presence (dot + word) and the server pill (§3.2, D4): the
    /// pill replaces Part 1's plain status text — same observed
    /// states, presented as the one capsule used everywhere.
    private var statusLine: some View {
        HStack(spacing: Space.small) {
            if mesh.phase == .working {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.callout).foregroundStyle(.secondary)
            } else {
                Circle().fill(mesh.isOnline ? AppColor.statusOnline : AppColor.statusIdle)
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(mesh.isOnline ? "Online" : "Offline"))
                    .font(.callout.weight(.medium))
            }
            ServerStatusPillView(presentation: ServerStatusPillView.presentation(for: mesh),
                                 action: serverPillAction)
        }
    }

    /// The card's pill opens Settings → Self-hosted — except in
    /// the not-available state, whose dedicated "Open personal
    /// server settings" action is already on this card: the same
    /// action never appears twice on one surface (§1.8), so there
    /// the pill renders inert and the one button carries it.
    private var serverPillAction: (() -> Void)? {
        serverGuidance.kind == .defaultNotAvailable
            ? nil
            : { self.openServerSettings() }
    }

    /// Opens the app's Settings scene (macOS 13 path, mirroring the
    /// gear button in the main window), landing on the Self-hosted
    /// pane: the personal-server frame lives there (§3.4).
    private func openServerSettings() {
        SettingsSection.selfHosted.save()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Connect (§5.2)

    private var connectBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect").font(.headline)
            HStack(spacing: 8) {
                TextField("123 456 789", text: $connectID)
                    .font(.system(size: 15, design: .monospaced))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .focused($connectFieldFocused)
                    .onSubmit { Task { await mesh.connect(toRawID: connectID) } }
                Button("Connect") { Task { await mesh.connect(toRawID: connectID) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(mesh.isBusy || mesh.phase != .ready
                              || connectID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(LocalizedStringKey(serverGuidance.connectCaptionKey))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = mesh.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = mesh.errorMessage, mesh.phase == .ready {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(AppColor.statusError)
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
                        .font(.system(size: 19)).foregroundStyle(AppColor.statusLimited)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.formatted)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                        Text("wants to pair with this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reject", role: .destructive) { Task { await mesh.reject(peer) } }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Approve") { Task { await mesh.approve(peer) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if peer != mesh.pendingRequests.last { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
    }

    // MARK: Paired (§5.2)

    private var pairedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired devices").font(.headline)
            if mesh.pairedDevices.isEmpty {
                PairedDevicesEmptyView { connectFieldFocused = true }
            } else {
                VStack(spacing: 0) {
                    ForEach(mesh.pairedDevices) { device in
                        HStack(spacing: 13) {
                            Circle().fill(device.online == true ? AppColor.statusOnline : AppColor.statusIdle)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? device.id.formatted)
                                    .font(.system(size: 15, weight: .medium,
                                                  design: device.name == nil ? .monospaced : .default))
                                Text(device.presenceText)
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
                .background(cardBackground, in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// The media coordinator (M1 part 3b): on the host side its
    /// capture state is part of this strip — the host has no
    /// session window, so a capture failure must land here,
    /// never silently.
    var media: MeshMediaCoordinator?

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
            VStack(alignment: .leading, spacing: 6) {
                strip {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(AppColor.statusOnline)
                    Text(role == .host
                         ? LF("%@ is connected to this device.", peerName ?? peer.formatted)
                         : LF("Connected to %@.", peerName ?? peer.formatted))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("End session", role: .destructive) { controller.endSession() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if role == .host, let media {
                    MeshHostMediaLine(media: media)
                }
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
                        in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
    }
}

/// The host-side media line under the session strip (M1 part
/// 3b): "Sharing screen" while capture runs, or the capture
/// failure in plain words. Never silent either way.
private struct MeshHostMediaLine: View {
    @ObservedObject var media: MeshMediaCoordinator

    var body: some View {
        if let error = media.hostCaptureError {
            Label(LF("Screen sharing failed: %@", error),
                  systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(AppColor.statusError)
                .fixedSize(horizontal: false, vertical: true)
        } else if media.isSharingScreen {
            HStack(spacing: 5) {
                Circle().fill(AppColor.statusOnline).frame(width: 7, height: 7)
                Text("Sharing screen")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
