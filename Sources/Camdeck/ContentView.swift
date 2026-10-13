import SwiftUI

struct ContentView: View {
    @Bindable var cam: CameraController
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .inspector(isPresented: $showInspector) { InspectorView(cam: cam) }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 600)
            .toolbar {
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
            .task { cam.start() }
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
            PreviewView(session: cam.session, mirrored: cam.mirrored)
        }
    }
}
