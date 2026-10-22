import Combine
import Foundation

/// Groups an invite code the house way (UI 5.0 spec: groups of
/// four). The grouping characters are presentation only: the code
/// a server compares against is the same string with spaces and
/// hyphens removed. Character case is preserved — the server, not
/// the formatter, owns what a valid code looks like.
enum InviteCodeFormatter {
    static func normalized(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != "-" }
    }

    static func grouped(_ raw: String) -> String {
        let characters = Array(normalized(raw))
        guard !characters.isEmpty else { return "" }
        return stride(from: 0, to: characters.count, by: 4)
            .map { start in
                String(characters[start..<min(start + 4, characters.count)])
            }
            .joined(separator: "-")
    }
}

/// The outcome of a first-run or re-registration attempt, in the
/// terms redesign spec §3.6 branches on. This is a pure mapping of
/// the session model's observed state — it invents no new state.
enum MeshRegistrationOutcome: Equatable {
    case needsIdentity
    case working
    case live
    case defaultNotAvailable
    case inviteRequired
    case offline

    static func outcome(phase: MeshSessionModel.Phase,
                        availability: MeshServerAvailability) -> MeshRegistrationOutcome {
        switch phase {
        case .needsIdentity:
            return .needsIdentity
        case .working:
            return .working
        case .ready:
            return .live
        case .serverUnavailable:
            return .defaultNotAvailable
        case .offline:
            return availability == .inviteRequired ? .inviteRequired : .offline
        }
    }
}

/// What the This-device card adds below its status line for the
/// server states redesign spec §3.3 spells out. Pure presentation
/// mapping, driven only by states the app actually observed.
struct MeshServerGuidance: Equatable {
    enum Kind: Equatable {
        case none
        case defaultNotAvailable
        case unreachable
        case inviteRequired
    }

    let kind: Kind
    let explanationKey: String?
    let showsOpenServerSettings: Bool
    let showsRetry: Bool
    let showsUseDefaultServer: Bool
    let showsEnterInviteCode: Bool
    let connectCaptionKey: String

    private static let pairingCaptionKey =
        "Connecting sends a pairing request. Once the other device approves, it appears under Paired devices."
    private static let workingServerCaptionKey = "Connecting requires a working server."

    static func presentation(isCustom: Bool,
                             availability: MeshServerAvailability,
                             phase: MeshSessionModel.Phase) -> MeshServerGuidance {
        if availability == .inviteRequired, case .offline = phase {
            return MeshServerGuidance(
                kind: .inviteRequired,
                explanationKey: "This server requires an invite code to register a new device.",
                showsOpenServerSettings: false,
                showsRetry: false,
                showsUseDefaultServer: false,
                showsEnterInviteCode: true,
                connectCaptionKey: workingServerCaptionKey)
        }
        if availability == .defaultNotAvailable, !isCustom, phase == .serverUnavailable {
            return MeshServerGuidance(
                kind: .defaultNotAvailable,
                explanationKey: "The project's default server is not running yet. In the meantime, you can use your own server.",
                showsOpenServerSettings: true,
                showsRetry: false,
                showsUseDefaultServer: false,
                showsEnterInviteCode: false,
                connectCaptionKey: workingServerCaptionKey)
        }
        if availability == .unreachable, case .offline = phase {
            return MeshServerGuidance(
                kind: .unreachable,
                explanationKey: "Check your network connection, or open Settings → Self-hosted to try another server.",
                showsOpenServerSettings: false,
                showsRetry: true,
                showsUseDefaultServer: isCustom,
                showsEnterInviteCode: false,
                connectCaptionKey: workingServerCaptionKey)
        }
        return MeshServerGuidance(
            kind: .none,
            explanationKey: nil,
            showsOpenServerSettings: false,
            showsRetry: false,
            showsUseDefaultServer: false,
            showsEnterInviteCode: false,
            connectCaptionKey: pairingCaptionKey)
    }
}

/// State behind the contextual invite sheet (redesign spec §3.5).
/// One model, two doors: the session model's invite refusal opens
/// it automatically, and the This-device card's "Enter invite code"
/// action opens the very same sheet. A refused code keeps the
/// sheet up with its error; success closes it and clears the code.
@MainActor
final class MeshInviteSheetModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var code = "" {
        didSet {
            let formatted = InviteCodeFormatter.grouped(code)
            if formatted != code { code = formatted }
            if errorMessage != nil { errorMessage = nil }
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false

    var canSubmit: Bool {
        !InviteCodeFormatter.normalized(code).isEmpty && !isSubmitting
    }

    /// Opens the sheet. Re-presenting an already-open sheet is a
    /// no-op, so an automatic trigger can never wipe a code the
    /// user is halfway through typing.
    func present() {
        guard !isPresented else { return }
        errorMessage = nil
        isPresented = true
    }

    func cancel() {
        isPresented = false
        code = ""
        errorMessage = nil
        isSubmitting = false
    }

    /// Registers the existing local identity with the typed code.
    /// The sheet closes only on a proven success: the session
    /// model is ready and holds the Mesh ID the server assigned.
    func submit(mesh: MeshSessionModel) async {
        guard canSubmit else { return }
        guard !mesh.isBusy else {
            errorMessage = L("Registration is already in progress.")
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        await mesh.createIdentity(name: mesh.deviceName,
                                  invite: InviteCodeFormatter.normalized(code))
        if mesh.phase == .ready, mesh.meshID != nil {
            code = ""
            errorMessage = nil
            isPresented = false
        } else if mesh.serverAvailability == .inviteRequired {
            errorMessage = L("That invite code was not accepted. Check the code and try again.")
        } else {
            errorMessage = L("Registration could not be completed. Check the connection and try again.")
        }
    }
}

/// A one-shot request to focus the Self-hosted Connect field,
/// raised from another section (the Devices & History library's
/// paired-devices empty state). The generation lets an already
/// on-screen Self-hosted view react; `consumePending` lets a view
/// that appears afterwards honor the request exactly once.
@MainActor
final class MeshConnectFocusRequest: ObservableObject {
    @Published private(set) var generation = 0
    private var pending = false

    func request() {
        generation += 1
        pending = true
    }

    func consumePending() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}

/// The paired-devices empty presentation (redesign spec §4): a
/// quiet panel, one sentence, one secondary sentence, and the one
/// action the spec allows — move to the Mesh ID field.
enum PairedDevicesEmptyPresentation {
    static let symbolName = "network"
    static let titleKey = "No paired devices yet."
    static let explanationKey = "Pairing is complete after the other device approves."
    static let actionKey = "Connect by Mesh ID"
}

/// The Control section's recents empty presentation (spec §4):
/// the block stays in place with one quiet line; no Clear action
/// exists while there is nothing to clear.
enum RecentPartnersEmptyPresentation {
    static let titleKey = "Recent Windows computers"
    static let textKey = "No computers have been connected recently yet. Enter the ID and password in the card above to get started."
}

/// The Devices & History library when BOTH stores are empty
/// (spec §4): one combined state for the whole screen, two short
/// sentences pointing at the two ways to start — text only, the
/// spec gives this state no action of its own.
enum DeviceLibraryEmptyPresentation {
    static let titleKey = "No paired devices or recent computers yet."
    static let guidanceKey = "Enter an UltraViewer ID in Control, or open Self-hosted to create an identity and pair a device."
}

/// Which face the Devices & History library shows.
enum DeviceLibraryPresentation: Equatable {
    case combinedEmpty
    case groups
}

extension LibraryGroups {
    var presentation: DeviceLibraryPresentation {
        count(for: .meshPaired) == 0 && count(for: .ultraViewerRecent) == 0
            ? .combinedEmpty
            : .groups
    }
}

/// The chat transcript's empty line (spec §4), used when the
/// transport has no factual note of its own to show.
enum ChatEmptyPresentation {
    static let textKey = "No messages yet. Send the first message."
}
