import SwiftUI

/// Toolbar field: "warmer", "black and white", Return. Runs the on-device model; Undo appears after a change.
struct LookField: View {
    let cam: CameraController
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Describe a look…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .disabled(busy)
                .frame(width: 150)
                .accessibilityLabel("Describe a look")
            if busy {
                ProgressView().controlSize(.mini)
            } else if cam.lookUndo != nil {
                Button("Undo") { cam.undoLook() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .help("Put the picture back as it was before the last request.")
            } else {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help(LookAssistant.unavailableReason ?? "Type what you want the picture to look like and press Return. Runs on this Mac; nothing is sent anywhere.")
    }

    private func submit() {
        let t = text
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        busy = true
        Task {
            await cam.applyLook(t)
            busy = false
            text = ""
            focused = false
        }
    }
}
