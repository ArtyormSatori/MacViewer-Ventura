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

/// The viewer's session window (UI spec W2): in this chunk it shows
/// the negotiated state — peer, elapsed time, granted capabilities —
/// and states factually that media arrives with M1. Ending the
/// session from here ends it on both sides.
struct MeshSessionWindowView: View {
    @ObservedObject var controller: MeshSessionController
    var onClose: () -> Void

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
                Text("Signaling connected · media arrives with the M1 update")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
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
        .frame(width: 430)
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
                view: MeshSessionWindowView(controller: controller,
                                            onClose: { [weak self] in self?.sessionWindow?.close() }),
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
