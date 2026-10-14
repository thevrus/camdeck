import SwiftUI
import UVCKit

struct ContentView: View {
    @Bindable var cam: CameraController
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("showAllControls") private var showAll = false

    var body: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .inspector(isPresented: $showInspector) { InspectorView(cam: cam) }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 600)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { LookField(cam: cam) }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    cameraMenu
                    Toggle(isOn: $cam.mirrored) {
                        Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Mirror Preview")
                    Button { cam.resetView() } label: {
                        Label("Reset View", systemImage: "arrow.counterclockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(!hasViewControls)
                    .help("Reset View")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    // Same switch as Camera > Show All Controls (⇧⌘A). View-only: nothing is written to the camera.
                    Picker("Controls", selection: $showAll) {
                        Text("Basic").tag(false)
                        Text("Pro").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Basic shows the everyday controls. Pro shows every setting the camera supports.")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { withAnimation(.snappy) { showInspector.toggle() } } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .labelStyle(.titleAndIcon)
                    .help(showInspector ? "Hide Inspector" : "Show Inspector")
                }
            }
            .navigationTitle("Camdeck")
            .navigationSubtitle(subtitle)
            .frame(minWidth: 900, minHeight: 560)
            .overlay(alignment: .bottom) {
                if let t = cam.toast {
                    Label(t, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: cam.toast)
            .task { cam.start() }
            .onAppear { cam.previewVisible = true }
            .onDisappear { cam.previewVisible = false }
            .confirmationDialog("Reset all settings?", isPresented: $cam.confirmingReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { cam.restoreDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Image, exposure, framing and format return to the defaults for this camera. Your presets are kept.")
            }
    }

    private var subtitle: String {
        guard let name = cam.currentDevice?.localizedName else { return "" }
        guard let f = cam.formats.first(where: { $0.id == cam.selectedFormatID }) else { return name }
        return "\(name) · \(f.width)×\(f.height) · \(f.fps) fps"
    }

    private var hasViewControls: Bool { ["zoom", "pantilt", "roll"].contains { cam.state($0) != nil } }

    private var cameraMenu: some View {
        Menu {
            Picker("Camera", selection: Binding(get: { cam.selectedID }, set: { if let id = $0 { cam.select(id) } })) {
                ForEach(cam.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(cam.currentDevice?.localizedName ?? "Camera", systemImage: "web.camera")
        }
        .labelStyle(.titleAndIcon)
        .disabled(cam.cameras.isEmpty)
        .help("Camera")
    }

    @ViewBuilder
    private var preview: some View {
        if cam.authorized == false {
            ContentUnavailableView {
                Label("Camera Access Is Off", systemImage: "video.slash")
            } description: {
                Text("Allow Camdeck in System Settings › Privacy & Security › Camera.")
            } actions: {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
            .environment(\.colorScheme, .dark)
        } else if cam.cameras.isEmpty && cam.authorized == true {
            ContentUnavailableView("No Camera Connected", systemImage: "web.camera",
                                   description: Text("Plug in a UVC camera and it will appear here."))
                .environment(\.colorScheme, .dark)
        } else {
            PreviewView(session: cam.session, mirrored: cam.mirrored, gravity: .resizeAspectFill)
                .overlay { ZebraOverlay(zebra: cam.zebra, mirrored: cam.mirrored) }
        }
    }
}

/// Diagonal stripes over blown-out areas. The mask is analyzed from the full frame, so it is
/// filled into the same aspect-fill geometry as the preview and mirrored with it.
/// Reads `zebra` itself so a new mask (~5 Hz) only invalidates this view, not ContentView.
private struct ZebraOverlay: View {
    let zebra: ZebraAnalyzer
    let mirrored: Bool

    var body: some View {
        if zebra.isEnabled, let mask = zebra.mask {
            ZebraStripes()
                .mask {
                    Image(decorative: mask, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(x: mirrored ? -1 : 1)
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// No inputs, so the stripe path is only redrawn when the size changes, not per mask.
private struct ZebraStripes: View {
    var body: some View {
        Canvas { ctx, size in
            var stripes = Path()
            let step: CGFloat = 8
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(stripes, with: .color(.white.opacity(0.85)), lineWidth: 2.5)
            ctx.stroke(stripes.offsetBy(dx: step / 2, dy: 0), with: .color(.black.opacity(0.55)), lineWidth: 2.5)
        }
    }
}
