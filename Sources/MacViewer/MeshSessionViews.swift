import AppKit
import Combine
import MeshClient
import SwiftUI

/// The dedicated consent alert window's content (UI spec §5.4, D8):
/// who is asking, what they ask for, Approve / Reject. The window
/// itself is owned by `MeshSessionWindows`; closing it unanswered
/// counts as a rejection.
struct MeshConsentView: View {
    @ObservedObject var controller: MeshSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case let .incomingPending(_, peer, peerName, capabilities) = controller.phase {
                content(peer: peer, name: peerName, capabilities: capabilities)
            } else {
                Text("The request is no longer waiting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func content(peer: MeshID, name: String?,
                         capabilities: Set<MeshSessionCapability>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 30)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incoming session request").font(.headline)
                    Text(LF("%@ wants to connect to this device.", name ?? peer.formatted))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if capabilities.contains(.view) {
                    Label("Can view the screen", systemImage: "eye")
                }
                if capabilities.contains(.control) {
                    Label("Can control mouse and keyboard", systemImage: "keyboard")
                }
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text("Mesh ID").font(.callout.weight(.medium))
                Text(peer.formatted)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
            Text("If you do not answer within 60 seconds, the request is rejected automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Reject", role: .destructive) { controller.rejectIncoming() }
                    .buttonStyle(.bordered)
                Button("Approve") { controller.approveIncoming() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The viewer's session window (UI spec W2): the negotiated
/// state — peer, elapsed time, granted capabilities — and, since
/// M1 part 3b, the live WebRTC video surface with its Direct /
/// Relay badge and link stats when the session granted view.
/// Ending the session from here ends it on both sides.
struct MeshSessionWindowView: View {
    @ObservedObject var controller: MeshSessionController
    var onClose: () -> Void
    /// Opens the shared chat window with the session's peer
    /// (Phase 3, chunk 3); nil hides the Chat action.
    var onOpenChat: (() -> Void)?
    /// The media coordinator (M1 part 3b); nil keeps the
    /// pre-media status line, which stays truthful wherever no
    /// coordinator is wired.
    var media: MeshMediaCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch controller.phase {
            case let .outgoingPending(_, peer, peerName, _):
                header(peer: peer, name: peerName)
                Text(LF("Waiting for %@ to answer…", peerName ?? peer.formatted))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel request") { controller.cancelOutgoing() }
                        .buttonStyle(.bordered)
                }
            case let .active(_, peer, peerName, _, capabilities, startedAt):
                header(peer: peer, name: peerName)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsed(since: startedAt, now: context.date))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 6) {
                    if capabilities.contains(.view) {
                        Label("View", systemImage: "eye").labelStyle(.titleAndIcon)
                    }
                    if capabilities.contains(.control) {
                        Label("Control", systemImage: "keyboard").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                if capabilities.contains(.view), let media {
                    MeshMediaSection(media: media,
                                     inputEnabled: capabilities.contains(.control))
                } else if capabilities.contains(.view) {
                    Text("Signaling connected · media arrives with the M1 update")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let onOpenChat {
                        Button("Chat") { onOpenChat() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("End session", role: .destructive) { controller.endSession() }
                        .buttonStyle(.bordered)
                }
            case .ended:
                Text("Mesh session").font(.headline)
                if let message = controller.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Close") {
                        controller.dismissEnded()
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            default:
                Text("Mesh session").font(.headline)
                HStack {
                    Spacer()
                    Button("Close") { onClose() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(20)
        .frame(width: videoActive ? 680 : 430)
    }

    /// True while the window carries the live video surface —
    /// the window widens for it (the windows manager re-fits the
    /// window when the content size changes).
    private var videoActive: Bool {
        guard media != nil,
              case let .active(_, _, _, _, capabilities, _) = controller.phase
        else { return false }
        return capabilities.contains(.view)
    }

    private func header(peer: MeshID, name: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 24)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? peer.formatted).font(.headline)
                Text(peer.formatted)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// The live-media block of the viewer's session window (M1
/// part 3b): the remote video surface, the Direct / Relay path
/// badge, and the RTT · fps readout (spec §5.6: the badge is
/// green for Direct, amber for Relay, and a status color is
/// always paired with its text). The stats refresh once a
/// second from the coordinator's poll.
private struct MeshMediaSection: View {
    @ObservedObject var media: MeshMediaCoordinator
    let inputEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeshVideoSurfaceView(track: media.remoteVideoTrack,
                                 inputSender: media.inputSender,
                                 inputEnabled: inputEnabled)
                .frame(width: 640, height: 360)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(0.12)))
            HStack(spacing: 8) {
                if let kind = media.linkKind {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(kind == .direct ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(L(kind == .direct ? "Direct" : "Relay"))
                            .font(.caption.weight(.medium))
                    }
                }
                if let stats = media.linkStats {
                    Text(statsText(stats))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if media.mediaFailed {
                Label("Media connection failed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if media.remoteVideoTrack == nil {
                Text("Connecting media…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Only the fields the stats actually carried — an absent
    /// field is left out, never shown as zero.
    private func statsText(_ stats: MeshLinkStats) -> String {
        var parts: [String] = []
        if let rtt = stats.roundTripMilliseconds { parts.append("\(rtt) ms") }
        if let fps = stats.receivedFramesPerSecond { parts.append("\(fps) fps") }
        return parts.joined(separator: " · ")
    }
}

/// Owns the two Mode 2 session windows as plain AppKit windows,
/// independent of the main window's state — a consent request must
/// not be missable because another app is frontmost (spec §5.4, D8).
/// Bound to the model's current session controller from
/// ConnectionView; rebinding (server change) closes both windows.
@MainActor
final class MeshSessionWindows: NSObject, NSWindowDelegate {
    private var consentWindow: NSWindow?
    private var sessionWindow: NSWindow?
    private var phaseSink: AnyCancellable?
    private weak var controller: MeshSessionController?
    private var lastPhase: MeshSessionController.Phase = .idle
    /// Opens the shared chat window for a peer (Phase 3, chunk 3);
    /// set by ConnectionView, which owns the chat windows.
    var onOpenChat: ((MeshID, String?) -> Void)?
    /// The media coordinator (M1 part 3b), bound alongside the
    /// controller; passed into the session window's content.
    private weak var media: MeshMediaCoordinator?
    private var mediaSink: AnyCancellable?

    /// Binds the media coordinator whose state the session
    /// window shows. Media changes (track arrival, stats) can
    /// change the content's size, so the window re-fits.
    func bindMedia(_ coordinator: MeshMediaCoordinator?) {
        media = coordinator
        mediaSink?.cancel()
        mediaSink = coordinator?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refitSessionWindow() }
        }
    }

    private func refitSessionWindow() {
        guard let window = sessionWindow, let content = window.contentView
        else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0,
              window.contentView?.frame.size != size else { return }
        window.setContentSize(size)
    }

    func bind(to controller: MeshSessionController) {
        guard self.controller !== controller else { return }
        consentWindow?.close()
        sessionWindow?.close()
        self.controller = controller
        lastPhase = controller.phase
        MeshConsentNotifier.requestAuthorization()
        phaseSink = controller.$phase.sink { [weak self] phase in
            Task { @MainActor in self?.phaseChanged(to: phase) }
        }
        phaseChanged(to: controller.phase)
    }

    private func phaseChanged(to phase: MeshSessionController.Phase) {
        let previous = lastPhase
        lastPhase = phase
        switch phase {
        case let .incomingPending(_, peer, peerName, _):
            if case .incomingPending = previous {
                // Same prompt re-rendered; do not re-notify.
            } else {
                MeshConsentNotifier.postIncomingRequest(
                    name: peerName ?? peer.formatted, meshID: peer)
            }
            showConsentWindow()
        case .outgoingPending:
            showSessionWindow()
        case let .active(_, peer, peerName, role, _, _):
            closeConsentWindow()
            if role == .host {
                if case .active = previous {
                    // Already announced.
                } else {
                    MeshConsentNotifier.postSessionStarted(name: peerName ?? peer.formatted)
                }
            } else {
                showSessionWindow()
            }
        case .ended, .idle:
            closeConsentWindow()
            // The session window stays open on .ended so the outcome
            // can be read; its Close button dismisses it.
        }
    }

    // MARK: Consent window

    private func showConsentWindow() {
        guard let controller else { return }
        if consentWindow == nil {
            let window = makeWindow(title: L("Incoming session request"),
                                    view: MeshConsentView(controller: controller),
                                    floating: true)
            window.delegate = self
            consentWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        consentWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeConsentWindow() {
        consentWindow?.close()
    }

    // MARK: Session window

    private func showSessionWindow() {
        guard let controller else { return }
        if sessionWindow == nil {
            let window = makeWindow(
                title: L("Mesh session"),
                view: MeshSessionWindowView(
                    controller: controller,
                    onClose: { [weak self] in self?.sessionWindow?.close() },
                    onOpenChat: { [weak self, weak controller] in
                        guard let controller,
                              case let .active(_, peer, peerName, _, _, _) = controller.phase
                        else { return }
                        self?.onOpenChat?(peer, peerName)
                    },
                    media: media),
                floating: false)
            window.delegate = self
            sessionWindow = window
        }
        sessionWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === consentWindow {
            consentWindow = nil
            // Closing the prompt unanswered counts as a rejection, so
            // the requester is never left hanging until the timeout.
            if let controller, case .incomingPending = controller.phase {
                controller.rejectIncoming()
            }
        } else if window === sessionWindow {
            sessionWindow = nil
        }
    }

    // MARK: Helpers

    private func makeWindow<Content: View>(title: String, view: Content, floating: Bool) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 220),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        if floating { window.level = .floating }
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        window.center()
        return window
    }
}
