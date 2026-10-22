import SwiftUI

/// The server status pill (redesign spec §3.2, decision D4 —
/// always visible): a capsule with a status dot and its text; the
/// color never appears without the words. The same pill renders in
/// three places — the sidebar footer, the This-device card, and the
/// head of Settings → Self-hosted. Where it is tappable it opens
/// Settings → Self-hosted; where it is not (inside that very pane)
/// it renders as a plain capsule, never a dead button (§1.8).
struct ServerStatusPillView: View {
    let presentation: ServerPillPresentation
    /// Opens Settings → Self-hosted; nil renders the pill inert.
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { pillBody }
                .buttonStyle(.plain)
                .help("Server settings")
                .accessibilityLabel(L(presentation.textKey))
        } else {
            pillBody
        }
    }

    private var pillBody: some View {
        HStack(spacing: 6) {
            if presentation.showsSpinner {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            Text(L(presentation.textKey))
                .font(AppFont.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.small)
        .padding(.vertical, Space.tight)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var dotColor: Color {
        switch presentation.token {
        case .online: return AppColor.statusOnline
        case .limited: return AppColor.statusLimited
        case .idle: return AppColor.statusIdle
        }
    }
}

/// Derives the pill from the mesh session model's live state.
extension ServerStatusPillView {
    static func presentation(for mesh: MeshSessionModel) -> ServerPillPresentation {
        ServerPill.presentation(isCustom: mesh.isUsingCustomServer,
                                availability: mesh.serverAvailability,
                                phase: mesh.phase)
    }
}
