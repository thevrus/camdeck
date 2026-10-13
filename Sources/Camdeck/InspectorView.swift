import SwiftUI
import UVCKit

struct InspectorView: View {
    @Bindable var cam: CameraController
    @AppStorage("advancedControls") private var advanced = false
    @AppStorage("inspector.effects") private var effectsOpen = false
    @AppStorage("inspector.framing") private var framingOpen = true
    @AppStorage("inspector.image") private var imageOpen = true
    @AppStorage("inspector.exposure") private var exposureOpen = false
    @State private var vendorOpen: Set<String> = []
    private var effects: VideoEffects { .shared }

    /// Everyday look controls. Everything else lives in Color & Exposure or Advanced.
    private static let basicImage = ["brightness", "contrast", "saturation", "sharpness"]
    private static let exposureIDs = ["wb-auto", "wb-temp", "ae-mode", "exposure", "powerline", "backlight", "lowlight"]

    var body: some View {
        Form {
            cameraSection
            if hasViewControls || cam.state("focus-auto") != nil {
                fold("Framing", $framingOpen) {
                    viewRows
                    if cam.state("pantilt") != nil, let z = cam.state("zoom"), let lo = z.min?.first,
                       (cam.value("zoom").first ?? lo) <= lo {
                        footnote("Zoom in to reframe. Drag the frame to pan and tilt, or double-click to reset.")
                    }
                }
            }
            fold("Image", $imageOpen) { imageRows(Self.basicImage) }
            if hasAny(Self.exposureIDs) {
                fold("Color & Exposure", $exposureOpen) { imageRows(Self.exposureIDs) }
            }
            if !effects.items.isEmpty { effectsSection }
            if hasAny(advancedIDs) {
                fold("Advanced", $advanced) {
                    imageRows(advancedIDs)
                    if let r = cam.state("roll") { slider(r) }
                    footnote("Rarely needed. These can easily make the image look worse.")
                }
            }
            vendorSections
        }
        .formStyle(.grouped)
        .animation(.snappy, value: cam.value("zoom"))
        .animation(.snappy, value: cam.selectedFormatID)
        // Opaque on purpose: the glass inspector over dark video made text unreadable.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var advancedIDs: [String] {
        cam.states.filter { $0.control.group == .image }.map(\.id)
            .filter { !Self.basicImage.contains($0) && !Self.exposureIDs.contains($0) }
    }
    private func hasAny(_ ids: [String]) -> Bool { ids.contains { cam.state($0) != nil } }

    /// Collapsible section whose whole header row is the click target (the native disclosure only hits the tiny chevron).
    private func fold<C: View>(_ title: String, _ open: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        Section {
            if open.wrappedValue { content() }
        } header: {
            Button { withAnimation(.snappy) { open.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open.wrappedValue ? "expanded" : "collapsed")
        }
    }

    // MARK: Camera

    private var cameraSection: some View {
        Section("Camera") {
            Picker("Camera", selection: Binding(get: { cam.selectedID }, set: { if let id = $0 { cam.select(id) } })) {
                ForEach(cam.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            Picker("Resolution", selection: Binding(get: { selectedSize }, set: { if let r = $0 { selectResolution(r) } })) {
                ForEach(resolutions, id: \.self) { Text(resolutionLabel($0)).tag(Optional($0)) }
            }
            .disabled(cam.formats.isEmpty)
            .help("Capture size. Higher resolutions cost more CPU and USB bandwidth.")
            Picker("Frame Rate", selection: Binding(get: { selectedFormat?.fps }, set: { fps in
                if let r = selectedSize, let fps { cam.selectFormat("\(r.w)x\(r.h)@\(fps)") }
            })) {
                ForEach(frameRates, id: \.self) { Text("\($0) fps").tag(Optional($0)) }
            }
            .disabled(frameRates.count < 2)
            .help("Frames per second. Match your region's mains frequency (50 or 60 Hz) to avoid flicker.")
            Toggle("Mirror Preview", isOn: $cam.mirrored)
                .help("Flip the preview horizontally, like a mirror. Does not affect what other apps receive.")
        }
    }

    // MARK: Format

    private struct Size: Hashable { let w: Int; let h: Int }

    private var selectedFormat: FormatOption? { cam.formats.first { $0.id == cam.selectedFormatID } }
    private var selectedSize: Size? { selectedFormat.map { Size(w: $0.width, h: $0.height) } }

    private var resolutions: [Size] {
        var seen = Set<Size>()
        return cam.formats.map { Size(w: $0.width, h: $0.height) }.filter { seen.insert($0).inserted }
    }

    private var frameRates: [Int] {
        guard let r = selectedSize else { return [] }
        return cam.formats.filter { $0.width == r.w && $0.height == r.h }.map(\.fps).sorted(by: >)
    }

    private func resolutionLabel(_ r: Size) -> String {
        let wide = abs(Double(r.w) / Double(r.h) - 16.0 / 9.0) < 0.02
        switch (r.w, r.h) {
        case (3840, 2160): return "4K"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return wide ? "\(r.w)×\(r.h)" : "\(r.w)×\(r.h) · 4:3"
        }
    }

    /// Keep the current fps if the new resolution offers it, else 30, else the highest at or below it, else the highest.
    private func selectResolution(_ r: Size) {
        let rates = cam.formats.filter { $0.width == r.w && $0.height == r.h }.map(\.fps).sorted(by: >)
        guard !rates.isEmpty else { return }
        let current = selectedFormat?.fps ?? 30
        let fps = rates.contains(current) ? current
            : rates.contains(30) ? 30
            : rates.first { $0 <= current } ?? rates[0]
        cam.selectFormat("\(r.w)x\(r.h)@\(fps)")
    }

    // MARK: Effects

    private var effectsSection: some View {
        fold("Effects", $effectsOpen) {
            ForEach(effects.items) { item in
                Button { effects.openSystemPanel() } label: {
                    LabeledContent(item.title) {
                        HStack(spacing: 6) {
                            Text(item.on ? "On" : "Off").foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Opens the system Video Effects panel, where \(item.title) can be turned on for Camdeck.")
            }
            footnote("Effects are turned on in the system Video Effects panel and apply only to Camdeck.")
        }
    }

    // MARK: View

    private var hasViewControls: Bool { ["zoom", "pantilt", "roll"].contains { cam.state($0) != nil } }

    @ViewBuilder
    private var framingRow: some View {
        let z = cam.state("zoom")
        if let pt = cam.state("pantilt"), let lo = pt.min, let hi = pt.max, lo != hi {
            let zmin = z?.min?.first ?? 1
            let zmax = z?.max?.first ?? zmin
            FramingPad(zoomMin: zmin, zoomMax: zmax,
                       zoom: z == nil ? zmin : cam.value("zoom").first ?? zmin,
                       panTiltMin: lo, panTiltMax: hi, panTilt: cam.value("pantilt"),
                       isLocked: false,
                       onZoom: { cam.set("zoom", [$0]) },
                       onPanTilt: { cam.set("pantilt", $0) },
                       onReset: { cam.resetView() })
        } else if let z {
            slider(z)
        }
    }

    @ViewBuilder
    private var viewRows: some View {
        framingRow
        if let af = cam.state("focus-auto") {
            Toggle(af.control.name, isOn: Binding(get: { autoOn(af.id) }, set: { v in withAnimation(.snappy) { cam.set(af.id, [v ? 1 : 0]) } }))
                .help("Let the camera focus by itself. Turn off to set focus manually.")
            if let f = cam.state("focus"), !autoOn("focus-auto") { slider(f) }
        }
        if hasViewControls {
            Button("Reset View") { cam.resetView() }
                .help("Return zoom and framing to the full field of view.")
        }
    }

    // MARK: Image

    private func imageRows(_ ids: [String]) -> some View {
        ForEach(ids.compactMap { cam.state($0) }.filter(imageVisible)) { st in
            imageRow(st)
        }
    }

    private func imageVisible(_ st: UVCControlState) -> Bool {
        switch st.id {
        case "wb-temp": !autoOn("wb-auto")
        case "exposure": !cam.autoExposureOn()
        default: true
        }
    }

    @ViewBuilder
    private func imageRow(_ st: UVCControlState) -> some View {
        if st.id == "ae-mode" {
            Toggle(st.control.name, isOn: Binding(get: { cam.autoExposureOn() }, set: { v in withAnimation(.snappy) { cam.setAutoExposure(v) } }))
                .help(helpText(st.id))
        } else {
            switch st.control.widget {
            case .slider:
                slider(st)
            case .toggle:
                Toggle(st.control.name, isOn: Binding(get: { autoOn(st.id) }, set: { v in withAnimation(.snappy) { cam.set(st.id, [v ? 1 : 0]) } }))
                    .help(helpText(st.id))
            case .picker(let opts):
                let hi = st.max?.first ?? Int.max, lo = st.min?.first ?? Int.min
                Picker(st.id == "powerline" ? "Anti-Flicker" : st.control.name,
                       selection: Binding(get: { cam.value(st.id).first ?? 0 }, set: { cam.set(st.id, [$0]) })) {
                    ForEach(opts.filter { (lo ... hi).contains($0.value) }, id: \.value) { Text($0.label).tag($0.value) }
                }
                .help(helpText(st.id))
            case .panTilt: EmptyView()
            }
        }
    }

    // MARK: Vendor

    private var vendorGroups: [(String, [ProfileControl])] {
        var order: [String] = [], by: [String: [ProfileControl]] = [:]
        for c in cam.profileControls {
            if by[c.section] == nil { order.append(c.section) }
            by[c.section, default: []].append(c)
        }
        return order.map { ($0, by[$0]!) }
    }

    private var vendorSections: some View {
        ForEach(vendorGroups, id: \.0) { section, controls in
            fold(section, Binding(get: { vendorOpen.contains(section) },
                                  set: { if $0 { vendorOpen.insert(section) } else { vendorOpen.remove(section) } })) {
                ForEach(controls) { c in
                    let enabled = cam.isProfileControlEnabled(c.id)
                    Group {
                        switch c.ui.kind {
                        case .toggle:
                            Toggle(c.title, isOn: Binding(get: { (cam.profileValues[c.id] ?? 0) != 0 },
                                                          set: { cam.setProfileValue(c.id, $0 ? 1 : 0) }))
                        case .picker:
                            Picker(c.title, selection: Binding(get: { Int((cam.profileValues[c.id] ?? 0).rounded()) },
                                                               set: { cam.setProfileValue(c.id, Double($0)) })) {
                                ForEach(c.ui.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                            }
                        case .slider:
                            if let lo = c.ui.min, let hi = c.ui.max, hi > lo {
                                let value = Binding(get: { cam.profileValues[c.id] ?? c.ui.default ?? lo },
                                                    set: { cam.setProfileValue(c.id, $0) })
                                sliderRow(name: c.title, valueText: c.formatDisplay(value.wrappedValue),
                                          value: value, range: lo ... hi, step: c.ui.step ?? 1,
                                          onReset: { if let d = c.ui.default { cam.setProfileValue(c.id, d) } })
                            }
                        }
                    }
                    .disabled(!enabled)
                    .help(enabled ? c.title : "\(c.title) is unavailable in the current mode.")
                }
            }
        }
    }

    // MARK: Pieces

    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    private func autoOn(_ id: String) -> Bool { (cam.value(id).first ?? 0) != 0 }

    @ViewBuilder
    private func slider(_ st: UVCControlState, disabled: Bool = false) -> some View {
        if let lo = st.min?.first, let hi = st.max?.first, hi > lo {
            let v = cam.value(st.id).first ?? lo
            sliderRow(name: st.control.name, valueText: st.id == "wb-temp" ? "\(v) K" : "\(v)",
                      value: Binding(get: { Double(cam.value(st.id).first ?? lo) }, set: { cam.set(st.id, [Int($0.rounded())]) }),
                      range: Double(lo) ... Double(hi), step: 1,
                      onReset: { cam.reset(st.id) })
                .disabled(disabled || !st.canSet)
                .help(helpText(st.id))
        }
    }

    private func helpText(_ id: String) -> String {
        switch id {
        case "brightness": "Overall lightness of the image."
        case "contrast": "Difference between light and dark areas."
        case "saturation": "Color intensity. Lower for a softer look, zero for black and white."
        case "sharpness": "Edge enhancement. Too high adds halos and noise."
        case "gamma": "Mid-tone brightness curve."
        case "hue": "Shifts all colors around the color wheel."
        case "gain": "Sensor amplification. Brightens dark scenes but adds noise."
        case "backlight": "Compensates when the background is much brighter than you."
        case "wb-temp": "Color temperature in kelvin. Lower is warmer, higher is cooler."
        case "wb-auto": "Let the camera balance colors for the room's lighting. Turn off to set a fixed temperature."
        case "exposure": "Shutter time. Longer is brighter but blurs motion."
        case "ae-mode": "Let the camera set exposure automatically. Turn off for manual exposure."
        case "powerline": "Match your mains frequency to remove banding from artificial light."
        case "lowlight": "Slows the frame rate in dim rooms to brighten the image."
        case "zoom": "Digital zoom. Crops into the sensor."
        case "roll": "Rotates the image."
        case "focus": "Manual focus distance."
        default: ""
        }
    }

    private func sliderRow(name: String, valueText: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double, onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(valueText).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { v in value.wrappedValue = (range.lowerBound + ((v - range.lowerBound) / step).rounded() * step).clamped(to: range) }),
                   in: range)
                .labelsHidden()
                .accessibilityLabel(name)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReset)
        .contextMenu { Button("Reset to Default", action: onReset) }
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
