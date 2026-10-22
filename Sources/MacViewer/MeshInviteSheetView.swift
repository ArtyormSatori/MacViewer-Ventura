import SwiftUI

/// The contextual invite sheet (redesign spec §3.5): the ONLY
/// place a registration invite is ever typed outside the
/// personal-server frame. One explanation sentence, one grouped
/// input, Cancel / Register — no other controls (§1.8). The sheet
/// stays up with a clear error line when the server refuses the
/// code; it closes only on a proven registration.
struct MeshInviteSheetView: View {
    @ObservedObject var model: MeshInviteSheetModel
    @ObservedObject var mesh: MeshSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.standard) {
            Text("Server requires an invite code")
                .font(AppFont.screenTitle)
            Text("This server only registers new devices with an invite code. Enter the code you received from the server's operator.")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Invite code").font(AppFont.body.weight(.medium))
                TextField("Invite code", text: $model.code, prompt: Text("XXXX-XXXX"))
                    .font(AppFont.monoBody)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(model.isSubmitting)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.statusError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.small) {
                if model.isSubmitting {
                    ProgressView().controlSize(.small)
                    Text("Registering…").font(AppFont.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSubmitting)
                Button("Register") { Task { await model.submit(mesh: mesh) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
        .padding(Space.large)
        .frame(width: 430)
        .interactiveDismissDisabled(model.isSubmitting)
    }
}
