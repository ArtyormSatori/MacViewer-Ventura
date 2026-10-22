import AppKit
import SwiftUI

/// The redesign's design tokens (UI_REDESIGN_SPEC §1): every screen
/// of the redesign draws its colors, spacing, type and radii from
/// here instead of hardcoding per-view values. Colors are named
/// tokens over SYSTEM semantic colors, so each one adapts to light
/// and dark appearance — and to the user's accessibility contrast
/// settings — on its own. The app defines no custom hex colors.

/// Color tokens (spec §1.4). A status color is ALWAYS paired with
/// text; color never carries meaning alone.
enum AppColor {
    /// The one accent: the primary action of a surface, the
    /// sidebar's selection, links. Follows the user's macOS accent.
    static let accent = Color.accentColor
    /// Online, direct path, healthy session.
    static let statusOnline = Color(nsColor: .systemGreenColor)
    /// Relay path, waiting for approval, server unreachable,
    /// reduced quality.
    static let statusLimited = Color(nsColor: .systemOrangeColor)
    /// Errors and destructive actions — only those two jobs.
    static let statusError = Color(nsColor: .systemRedColor)
    /// Offline, unknown, last-seen.
    static let statusIdle = Color.secondary
    /// Content area background.
    static let surfaceWindow = Color(nsColor: .windowBackgroundColor)
    /// Card and list-row background.
    static let surfaceCard = Color(nsColor: .controlBackgroundColor)
    /// One-point separators between regions and rows.
    static let hairline = Color(nsColor: .separatorColor)
    /// The letterbox behind remote video: pure black in BOTH
    /// appearances (spec §1.6 — a hard rule: no material or
    /// translucency is ever placed over the remote video surface).
    static let videoBackdrop = Color.black
}

/// The spacing grid (spec §1.2): a 4-point base, one scale —
/// 4 / 8 / 12 / 16 / 24 / 32 — and no other layout values.
enum Space {
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let standard: CGFloat = 16
    static let large: CGFloat = 24
    static let section: CGFloat = 32
}

/// The type scale (spec §1.3): the system font (SF Pro) only, in
/// these sizes and no others. IDs, invite codes, server addresses
/// and session figures use the monospaced variants; session figures
/// additionally use tabular digits so values never change width.
enum AppFont {
    /// Screen title at the head of a content area.
    static let screenTitle = Font.system(size: 20, weight: .semibold)
    /// Block title / device name.
    static let blockTitle = Font.system(size: 13, weight: .semibold)
    /// Field labels and body text.
    static let body = Font.system(size: 13)
    /// Secondary text and captions.
    static let caption = Font.system(size: 11)
    /// Sidebar row label.
    static let sidebarTitle = Font.system(size: 13)
    /// Sidebar row subtitle (the owning mode's name).
    static let sidebarSubtitle = Font.system(size: 11)
    /// The Mesh ID on the This-device card: the app's single hero
    /// element, set like the device's phone number (§1.3, §9.2).
    static let meshIDHero = Font.system(size: 20, weight: .semibold, design: .monospaced)
    /// Monospaced body text (IDs, addresses).
    static let monoBody = Font.system(size: 13, design: .monospaced)
    /// Monospaced secondary text (figures, subtitles).
    static let monoCaption = Font.system(size: 11, design: .monospaced)
}

/// Corner radii (spec §1.5): one card radius, one small-tile
/// radius; pills and badges are capsules. Elevation is flat by
/// default — shadows belong only to genuinely floating surfaces
/// (sheets, popovers, the chat and consent windows) — and regions
/// are separated by `AppColor.hairline`, never by boxes.
enum Radius {
    /// Cards and panels: continuous 10-point corners.
    static let card: CGFloat = 10
    /// Logo tiles and small symbol tiles.
    static let tile: CGFloat = 8
}

/// The shared button system (spec §1.8 — neat, standard, nothing
/// redundant). Hierarchy is expressed by STYLE, never by adding
/// buttons:
/// - exactly ONE primary action per surface: `.borderedProminent`;
/// - secondary actions: `.bordered`;
/// - row and icon actions: `.borderless` / `.plain`, and every
///   icon-only button carries a tooltip (`.help`) AND an
///   accessibility label;
/// - the same action never appears twice on one surface;
/// - an action the current state cannot use is hidden, or disabled
///   with a readable reason next to it — never a dead button.
enum AppButtonStyle {
    /// The standard small control size for card and row actions.
    static let rowControlSize: ControlSize = .small
    /// The standard control size for a surface's primary action.
    static let primaryControlSize: ControlSize = .regular
}
