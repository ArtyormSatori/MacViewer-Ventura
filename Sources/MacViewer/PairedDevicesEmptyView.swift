import SwiftUI

/// The paired-devices empty panel (redesign spec §4), shared by
/// the Self-hosted list and the Devices & History library's mesh
/// group: a faded `network` symbol, the one sentence, the pairing
/// explanation, and exactly one secondary action — go to the Mesh
/// ID field (§1.8: no other button belongs here).
struct PairedDevicesEmptyView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: Space.small) {
            Image(systemName: PairedDevicesEmptyPresentation.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.55))
            Text(LocalizedStringKey(PairedDevicesEmptyPresentation.titleKey))
                .font(AppFont.body.weight(.medium))
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(PairedDevicesEmptyPresentation.explanationKey))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(LocalizedStringKey(PairedDevicesEmptyPresentation.actionKey), action: action)
                .buttonStyle(.bordered)
                .controlSize(AppButtonStyle.rowControlSize)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.large)
        .background(AppColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(AppColor.hairline))
    }
}
