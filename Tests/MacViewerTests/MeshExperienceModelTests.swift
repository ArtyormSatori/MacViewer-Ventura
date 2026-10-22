import Foundation
import Testing
@testable import MacViewer

/// Redesign Part 3's pure presentation models: the invite-code
/// format, the first-run outcome mapping (§3.6), the server-state
/// guidance mapping (§3.3), the Connect focus request, and the
/// empty-state selection (§4). The invite sheet's session-level
/// behavior lives in MeshSessionModelTests, next to the fake
/// server it drives.
struct MeshExperienceModelTests {

    // MARK: Invite code format (§3.5, house format from the 5.0 spec §9.3)

    @Test("Invite codes group in fours as typed")
    func inviteGrouping() {
        #expect(InviteCodeFormatter.grouped("ABCDEFGH") == "ABCD-EFGH")
        #expect(InviteCodeFormatter.grouped("ABCDE") == "ABCD-E")
        #expect(InviteCodeFormatter.grouped("ABC") == "ABC")
        #expect(InviteCodeFormatter.grouped("ABCD1234EFGH") == "ABCD-1234-EFGH")
    }

    @Test("Invite grouping is idempotent and ignores spaces and hyphens while typing")
    func inviteGroupingNormalizes() {
        #expect(InviteCodeFormatter.grouped("ABCD-EFGH") == "ABCD-EFGH")
        #expect(InviteCodeFormatter.grouped("AB CD-12 34") == "ABCD-1234")
        #expect(InviteCodeFormatter.grouped(InviteCodeFormatter.grouped("ABCDEFGH")) == "ABCD-EFGH")
    }

    @Test("Invite code case is preserved; only grouping is applied")
    func inviteCasePreserved() {
        #expect(InviteCodeFormatter.grouped("abcd1234") == "abcd-1234")
        #expect(InviteCodeFormatter.normalized("Ab-Cd 12") == "AbCd12")
    }

    @Test("Empty and separator-only invite input stays empty")
    func inviteEmpty() {
        #expect(InviteCodeFormatter.grouped("") == "")
        #expect(InviteCodeFormatter.grouped("----") == "")
        #expect(InviteCodeFormatter.grouped("  -  ") == "")
        #expect(InviteCodeFormatter.normalized("") == "")
    }

    @Test("A 32-character invite code groups into eight blocks of four")
    func inviteLongCode() {
        let code = String(repeating: "A", count: 32)
        let grouped = InviteCodeFormatter.grouped(code)
        #expect(grouped == String(repeating: "AAAA-", count: 7) + "AAAA")
        #expect(InviteCodeFormatter.normalized(grouped) == code)
    }

    // MARK: First-run outcome mapping (§3.6)

    @Test("First-run outcome: ready registration is the live home")
    func outcomeLive() {
        #expect(MeshRegistrationOutcome.outcome(phase: .ready, availability: .online) == .live)
    }

    @Test("First-run outcome: the undeployed default server is its own state")
    func outcomeDefaultNotAvailable() {
        #expect(MeshRegistrationOutcome.outcome(phase: .serverUnavailable,
                                                availability: .defaultNotAvailable) == .defaultNotAvailable)
    }

    @Test("First-run outcome: an invite refusal is the invite-required state, not generic offline")
    func outcomeInviteRequired() {
        #expect(MeshRegistrationOutcome.outcome(phase: .offline("refused"),
                                                availability: .inviteRequired) == .inviteRequired)
    }

    @Test("First-run outcome: a transport failure is plain offline")
    func outcomeOffline() {
        #expect(MeshRegistrationOutcome.outcome(phase: .offline("no route"),
                                                availability: .unreachable) == .offline)
        #expect(MeshRegistrationOutcome.outcome(phase: .offline("no route"),
                                                availability: .unknown) == .offline)
    }

    @Test("First-run outcome: no identity yet and in-flight work keep their own states")
    func outcomeNeedsIdentityAndWorking() {
        #expect(MeshRegistrationOutcome.outcome(phase: .needsIdentity,
                                                availability: .unknown) == .needsIdentity)
        #expect(MeshRegistrationOutcome.outcome(phase: .needsIdentity,
                                                availability: .inviteRequired) == .needsIdentity)
        #expect(MeshRegistrationOutcome.outcome(phase: .working,
                                                availability: .checking) == .working)
    }

    // MARK: Server-state guidance mapping (§3.3)

    @Test("Guidance: default server not available — quiet line, settings action, working-server caption")
    func guidanceDefaultNotAvailable() {
        let guidance = MeshServerGuidance.presentation(
            isCustom: false, availability: .defaultNotAvailable, phase: .serverUnavailable)
        #expect(guidance.kind == .defaultNotAvailable)
        #expect(guidance.explanationKey
                == "The project's default server is not running yet. In the meantime, you can use your own server.")
        #expect(guidance.showsOpenServerSettings)
        #expect(!guidance.showsRetry)
        #expect(!guidance.showsUseDefaultServer)
        #expect(!guidance.showsEnterInviteCode)
        #expect(guidance.connectCaptionKey == "Connecting requires a working server.")
    }

    @Test("Guidance: default server unreachable — one line and Retry only")
    func guidanceDefaultUnreachable() {
        let guidance = MeshServerGuidance.presentation(
            isCustom: false, availability: .unreachable, phase: .offline("down"))
        #expect(guidance.kind == .unreachable)
        #expect(guidance.explanationKey
                == "Check your network connection, or open Settings → Self-hosted to try another server.")
        #expect(guidance.showsRetry)
        #expect(!guidance.showsOpenServerSettings)
        #expect(!guidance.showsUseDefaultServer)
        #expect(!guidance.showsEnterInviteCode)
        #expect(guidance.connectCaptionKey == "Connecting requires a working server.")
    }

    @Test("Guidance: custom server unreachable adds the in-place Use default server action")
    func guidanceCustomUnreachable() {
        let guidance = MeshServerGuidance.presentation(
            isCustom: true, availability: .unreachable, phase: .offline("down"))
        #expect(guidance.kind == .unreachable)
        #expect(guidance.showsRetry)
        #expect(guidance.showsUseDefaultServer)
        #expect(!guidance.showsOpenServerSettings)
        #expect(!guidance.showsEnterInviteCode)
    }

    @Test("Guidance: invite required offers Enter invite code and nothing else")
    func guidanceInviteRequired() {
        for isCustom in [true, false] {
            let guidance = MeshServerGuidance.presentation(
                isCustom: isCustom, availability: .inviteRequired, phase: .offline("refused"))
            #expect(guidance.kind == .inviteRequired)
            #expect(guidance.explanationKey == "This server requires an invite code to register a new device.")
            #expect(guidance.showsEnterInviteCode)
            #expect(!guidance.showsRetry)
            #expect(!guidance.showsUseDefaultServer)
            #expect(!guidance.showsOpenServerSettings)
            #expect(guidance.connectCaptionKey == "Connecting requires a working server.")
        }
    }

    @Test("Guidance: healthy and in-flight states present nothing and keep the normal caption")
    func guidanceNoneWhenHealthy() {
        let normalCaption = "Connecting sends a pairing request. Once the other device approves, it appears under Paired devices."
        for (availability, phase) in [(MeshServerAvailability.online, MeshSessionModel.Phase.ready),
                                      (.checking, .working),
                                      (.unknown, .needsIdentity)] {
            let guidance = MeshServerGuidance.presentation(
                isCustom: false, availability: availability, phase: phase)
            #expect(guidance.kind == .none)
            #expect(guidance.explanationKey == nil)
            #expect(!guidance.showsOpenServerSettings)
            #expect(!guidance.showsRetry)
            #expect(!guidance.showsUseDefaultServer)
            #expect(!guidance.showsEnterInviteCode)
            #expect(guidance.connectCaptionKey == normalCaption)
        }
    }

    @Test("Guidance: mismatched phase and availability never borrow another state's wording")
    func guidanceNoBorrowedWording() {
        // Not-available is a health-gate outcome; an offline phase
        // with that availability is not the not-available state.
        #expect(MeshServerGuidance.presentation(
            isCustom: false, availability: .defaultNotAvailable,
            phase: .offline("down")).kind == .none)
        // An invite state only exists while registration is
        // actually refused (offline phase).
        #expect(MeshServerGuidance.presentation(
            isCustom: true, availability: .inviteRequired,
            phase: .ready).kind == .none)
        // Unreachable wording never appears for the health-gate
        // phase.
        #expect(MeshServerGuidance.presentation(
            isCustom: false, availability: .unreachable,
            phase: .serverUnavailable).kind == .none)
        // A custom target never gets the default-only state.
        #expect(MeshServerGuidance.presentation(
            isCustom: true, availability: .defaultNotAvailable,
            phase: .serverUnavailable).kind == .none)
    }

    // MARK: Connect focus request (§4 paired-devices action)

    @MainActor
    @Test("A focus request is consumed exactly once")
    func focusRequestConsumedOnce() {
        let focus = MeshConnectFocusRequest()
        #expect(!focus.consumePending())
        focus.request()
        #expect(focus.generation == 1)
        #expect(focus.consumePending())
        #expect(!focus.consumePending())
        focus.request()
        #expect(focus.generation == 2)
        #expect(focus.consumePending())
        #expect(!focus.consumePending())
    }

    // MARK: Empty-state selection (§4)

    @Test("Paired-devices empty presentation is the §4 panel")
    func pairedEmptyPresentation() {
        #expect(PairedDevicesEmptyPresentation.symbolName == "network")
        #expect(PairedDevicesEmptyPresentation.titleKey == "No paired devices yet.")
        #expect(PairedDevicesEmptyPresentation.explanationKey
                == "Pairing is complete after the other device approves.")
        #expect(PairedDevicesEmptyPresentation.actionKey == "Connect by Mesh ID")
    }

    @Test("Control recents empty presentation keeps the block with the §4 line")
    func recentPartnersEmptyPresentation() {
        #expect(RecentPartnersEmptyPresentation.titleKey == "Recent Windows computers")
        #expect(RecentPartnersEmptyPresentation.textKey
                == "No computers have been connected recently yet. Enter the ID and password in the card above to get started.")
    }

    @Test("Library combined empty presentation is the §4 two-sentence state")
    func libraryEmptyPresentation() {
        #expect(DeviceLibraryEmptyPresentation.titleKey == "No paired devices or recent computers yet.")
        #expect(DeviceLibraryEmptyPresentation.guidanceKey
                == "Enter an UltraViewer ID in Control, or open Self-hosted to create an identity and pair a device.")
    }

    @Test("Chat empty presentation is the §4 first-message line")
    func chatEmptyPresentation() {
        #expect(ChatEmptyPresentation.textKey == "No messages yet. Send the first message.")
    }

    @Test("Library presentation: combined empty only when both stores are empty")
    func libraryPresentationSelection() {
        #expect(LibraryGroups(meshDevices: [String](), recentPartners: [String]()).presentation
                == .combinedEmpty)
        #expect(LibraryGroups(meshDevices: ["482913705"], recentPartners: [String]()).presentation
                == .groups)
        #expect(LibraryGroups(meshDevices: [String](), recentPartners: ["123456"]).presentation
                == .groups)
        #expect(LibraryGroups(meshDevices: ["482913705"], recentPartners: ["123456"]).presentation
                == .groups)
    }
}
