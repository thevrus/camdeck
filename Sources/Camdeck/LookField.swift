import SwiftUI

/// Floating field over the preview: "warmer", "black and white", Return. Runs the on-device model.
/// Closes on success; on a miss it stays open with the text so it can be reworded. Esc or a click outside closes it.
struct LookField: View {
    let cam: CameraController
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    private static let misses: Set<String> = ["", CameraAgent.nothingDone]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Warmer, zoom in, black and white…", text: $text)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($focused)
                .onSubmit(submit)
                .disabled(busy)
                .accessibilityLabel("Describe a look")
            trailing
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 520)
        .frame(height: 60)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        // Never touches the preview edges when the inspector narrows it.
        .padding(.horizontal, 24)
        .help("Runs on this Mac. Nothing is sent anywhere.")
        .defaultFocus($focused, true)
        .onAppear { focused = true }
        .onExitCommand { cam.lookOpen = false }
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if !text.isEmpty {
            Image(systemName: "return")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        } else if cam.lookUndo != nil {
            Button { cam.undoLook() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Put the picture back as it was before the last look.")
        }
    }

    private func submit() {
        let t = text
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        busy = true
        Task {
            let msg = await CameraAgent.run(t, on: cam)
            busy = false
            if Self.misses.contains(msg) {
                focused = true
            } else {
                cam.lookOpen = false
            }
        }
    }
}
