import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UVCKit

struct InspectorView: View {
    @Bindable var cam: CameraController
    /// Master switch: off shows the short everyday inspector, on shows every control.
    @AppStorage("showAllControls") private var showAll = false
    /// Open/closed state of the Advanced fold only.
    @AppStorage("advancedControls") private var advanced = false
    @AppStorage("inspector.effects") private var effectsOpen = false
    @AppStorage("inspector.framing") private var framingOpen = true
    @AppStorage("inspector.image") private var imageOpen = true
    @AppStorage("inspector.exposure") private var exposureOpen = false
    @AppStorage("inspector.presets") private var presetsOpen = true
    @AppStorage("inspector.camera") private var cameraOpen = true
    @AppStorage("inspector.device") private var deviceOpen = false
    /// Open vendor sections, newline-separated (section titles come from profiles).
    @AppStorage("inspector.vendor") private var vendorOpenRaw = ""
    @State private var saving = false
    @State private var newName = ""
    @State private var renaming: Preset?
    @State private var renameText = ""
    private var effects: VideoEffects { .shared }

    /// Everyday look controls. Everything else lives in Color & Exposure or Advanced.
    private static let basicImage = ["brightness", "contrast", "saturation", "sharpness"]
    private static let exposureIDs = ["wb-auto", "wb-temp", "ae-mode", "exposure", "powerline", "backlight", "lowlight"]
    /// What the standard view (Show All Controls off) keeps from the two lists above.
    private static let standardImage = ["brightness", "contrast", "saturation"]
    private static let standardExposure = ["wb-auto", "wb-temp", "ae-mode"]
    /// Controls hidden in the standard view besides the Advanced fold's ids.
    private static let hiddenExtraIDs = ["sharpness", "exposure", "powerline", "backlight", "lowlight", "roll", "focus-auto", "focus"]

    var body: some View {
        Form {
            if let w = cam.usbWarning {
                Label(w.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            cameraSection
            if showFraming {
                fold("Framing", $framingOpen) {
                    viewRows
                    if cam.state("pantilt") != nil, let z = cam.state("zoom"), let lo = z.min?.first,
                       (cam.value("zoom").first ?? lo) <= lo {
                        footnote("Zoom in to reframe. Drag the frame to pan and tilt, or double-click to reset.")
                    }
                }
            }
            if hasAny(imageIDs) || (showAll && !vendorControls(in: "Image").isEmpty) {
                fold("Image", $imageOpen, reset: { cam.resetImage() }) {
                    imageRows(imageIDs)
                    if showAll { vendorRows(vendorControls(in: "Image")) }
                }
            }
            if hasAny(exposureRowIDs) {
                fold("Color & Exposure", $exposureOpen, reset: { cam.resetImage() }) {
                    imageRows(exposureRowIDs)
                    if showAll {
                        if let readout = cam.autoReadout {
                            Text(readout).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        @Bindable var zebra = cam.zebra
                        Toggle("Show Clipping", isOn: $zebra.isEnabled)
                            .help("Stripes over areas that are blown out to pure white, so you can lower exposure until they disappear.")
                        footnote("Marks parts of the preview that are overexposed (pure white, detail lost) with stripes. Lower Exposure or Brightness until they vanish. Only affects the preview, not what other apps see.")
                    }
                }
            }
            if showAll, !effects.items.isEmpty { effectsSection }
            if let presets = cam.presets { presetsSection(presets) }
            if showAll, hasAny(advancedIDs) || cam.state("roll") != nil {
                fold("Advanced", $advanced) {
                    imageRows(advancedIDs)
                    if let r = cam.state("roll") { slider(r) }
                    footnote("Rarely needed. These can easily make the image look worse.")
                }
            }
            if showAll {
                vendorSections
                if cam.currentDevice != nil { deviceSection }
            } else if hasHiddenChanges {
                hiddenChangesNote
            }
        }
        .formStyle(.grouped)
        .onChange(of: showAll && exposureOpen, initial: true) { _, on in cam.autoReadoutVisible = on }
        .onDisappear { cam.autoReadoutVisible = false }
        .animation(.snappy, value: cam.value("zoom"))
        .animation(.snappy, value: cam.selectedFormatID)
        // Opaque on purpose: the glass inspector over dark video made text unreadable.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var imageIDs: [String] { showAll ? Self.basicImage : Self.standardImage }
    private var exposureRowIDs: [String] { showAll ? Self.exposureIDs : Self.standardExposure }

    private var showFraming: Bool {
        let core = ["zoom", "pantilt"].contains { cam.state($0) != nil } || cam.centerStageSupported
        guard showAll else { return core }
        return cam.hasViewControls || core || cam.state("focus-auto") != nil || !vendorControls(in: "Framing").isEmpty
    }

    // MARK: Hidden changes

    /// True when a control the standard view hides differs from its default. Reads cached state only, never the device.
    private var hasHiddenChanges: Bool {
        let ids = Set(advancedIDs + Self.hiddenExtraIDs)
        let stateChanged = cam.states.contains { st in
            guard ids.contains(st.id), let def = st.def else { return false }
            // Skip values the camera drives itself while the matching auto toggle is on.
            if st.id == "exposure" && cam.autoExposureOn() { return false }
            if st.id == "focus" && autoOn("focus-auto") { return false }
            return def != cam.value(st.id)
        }
        if stateChanged { return true }
        if cam.zebra.isEnabled { return true }
        return cam.profileControls.contains { c in
            guard let d = c.ui.default, let v = cam.profileValues[c.id] else { return false }
            return abs(v - d) > 0.0001
        }
    }

    private var hiddenChangesNote: some View {
        Section {
            Button { withAnimation(.snappy) { showAll = true } } label: {
                Text("Some hidden settings are changed. Show All Controls to see them.")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.link)
        }
    }

    private var advancedIDs: [String] {
        cam.states.filter { $0.control.group == .image }.map(\.id)
            .filter { !Self.basicImage.contains($0) && !Self.exposureIDs.contains($0) }
    }
    private func hasAny(_ ids: [String]) -> Bool { ids.contains { cam.state($0) != nil } }

    /// Collapsible section whose whole header row is the click target (the native disclosure only hits the tiny chevron).
    private func fold<C: View>(_ title: String, _ open: Binding<Bool>, reset: (() -> Void)? = nil, @ViewBuilder content: () -> C) -> some View {
        Section {
            if open.wrappedValue { content() }
        } header: {
            HStack(spacing: 8) {
            Button { withAnimation(.snappy) { open.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                    Spacer(minLength: 0)
                }
                // Pinned: section headers otherwise pick up different sizes depending on where they sit in the Form.
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open.wrappedValue ? "expanded" : "collapsed")
            if let reset, open.wrappedValue {
                Button("Reset", action: reset)
                    .buttonStyle(.link)
                    .font(.subheadline)
                    .help("Put these settings back to the camera's defaults.")
            }
            }
        }
    }

    // MARK: Camera

    private var cameraSection: some View {
        fold("Camera", $cameraOpen) {
            Picker("Camera", selection: Binding(get: { cam.selectedID }, set: { if let id = $0 { cam.select(id) } })) {
                ForEach(cam.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            }
            if showAll {
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

    // MARK: Presets

    private func exportPresets(_ presets: PresetStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Camdeck Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try presets.exportData().write(to: url, options: .atomic)
            let n = presets.items.count
            cam.showToast("Exported \(n) preset\(n == 1 ? "" : "s")")
        } catch { cam.showToast("Export failed") }
    }

    private func importPresets(_ presets: PresetStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try presets.importData(Data(contentsOf: url))
            cam.showToast("Imported \(n) preset\(n == 1 ? "" : "s")")
        } catch { cam.showToast("Not a Camdeck presets file") }
    }

    private func presetsSection(_ presets: PresetStore) -> some View {
        fold("Presets", $presetsOpen) {
            ForEach(Array(presets.items.enumerated()), id: \.element.id) { i, p in
                Button { presets.apply(p.id) } label: {
                    LabeledContent {
                        HStack(spacing: 8) {
                            let apps = showAll ? presets.boundApps(for: p.id).map(Self.appName) : []
                            if !apps.isEmpty { Text(apps.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1) }
                            if presets.startupPresetID == p.id { Text("At launch").foregroundStyle(.secondary) }
                            if i < 5 { Text("⌘\(i + 1)").foregroundStyle(.tertiary).monospacedDigit() }
                        }
                    } label: { Text(p.name) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Apply \(p.name)")
                .contextMenu {
                    Button("Apply") { presets.apply(p.id) }
                    Toggle("Apply at Launch", isOn: Binding(get: { presets.startupPresetID == p.id },
                                                            set: { presets.startupPresetID = $0 ? p.id : nil }))
                    Divider()
                    if showAll {
                        Button("Use With App…") { pickApp(for: p.id, in: presets) }
                        let bound = presets.boundApps(for: p.id)
                        if !bound.isEmpty {
                            Menu("Remove App Binding") {
                                ForEach(bound, id: \.self) { id in
                                    Button(Self.appName(id)) { presets.unbind(app: id) }
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Rename…") { renameText = p.name; renaming = p }
                    Button("Delete", role: .destructive) { presets.delete(p.id) }
                }
            }
            if presets.items.isEmpty {
                footnote("Save the current look, then switch back to it any time with ⌘1 to ⌘5.")
            }
            Button("Save Preset…") { newName = presets.defaultName; saving = true }
            if showAll {
                Button("Export Presets…") { exportPresets(presets) }.disabled(presets.items.isEmpty)
                Button("Import Presets…") { importPresets(presets) }
            }
            if let lock = cam.settingsLock {
                @Bindable var lock = lock
                Toggle("Keep These Settings", isOn: $lock.isEnabled)
                    .help("Puts your settings back if another app, like Zoom or Teams, changes them.")
                if lock.isEnabled {
                    footnote(lock.lastReassert.map { "Last restored \($0.formatted(.relative(presentation: .named)))." }
                             ?? "Your settings are restored if another app changes them.")
                }
            }
        }
        .alert("Save Preset", isPresented: $saving) {
            TextField("Name", text: $newName)
            Button("Save") { presets.save(name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves image, exposure, framing and format.") }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { presets.rename(p.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// LaunchServices lookups are slow for a per-render call; names do not change while the app runs.
    @MainActor private static var appNames: [String: String] = [:]
    @MainActor private static func appName(_ bundleID: String) -> String {
        if let n = appNames[bundleID] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        appNames[bundleID] = n
        return n
    }

    private func pickApp(for id: UUID, in presets: PresetStore) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app that should use this preset when it starts the camera."
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        presets.bind(app: bundleID, to: id)
    }

    // MARK: Device

    private var deviceSection: some View {
        fold("Device", $deviceOpen) {
            let info = cam.deviceInfo
            LabeledContent("Name", value: info?.name ?? cam.currentDevice?.localizedName ?? "")
            if let s = info?.serial { LabeledContent("Serial Number") { Text(s).textSelection(.enabled) } }
            if let f = info?.firmware { LabeledContent("Firmware") { Text(f).textSelection(.enabled) } }
            Button("Reset All Settings…", role: .destructive) { cam.confirmingReset = true }
                .help("Return image, exposure and framing to the tuned defaults for this camera. Presets are kept.")
        }
    }

    // MARK: View


    @ViewBuilder
    private var framingRow: some View {
        let z = cam.state("zoom")
        if let pt = cam.state("pantilt"), let lo = pt.min, let hi = pt.max, lo != hi {
            let zmin = z?.min?.first ?? 1
            let zmax = z?.max?.first ?? zmin
            FramingPad(zoomMin: zmin, zoomMax: zmax,
                       zoom: z == nil ? zmin : cam.value("zoom").first ?? zmin,
                       panTiltMin: lo, panTiltMax: hi, panTilt: cam.value("pantilt"),
                       isLocked: cam.autoFraming != .off,
                       session: cam.session, mirrored: cam.mirrored,
                       onZoom: { cam.set("zoom", [$0]) },
                       onPanTilt: { cam.set("pantilt", $0) },
                       onReset: { cam.resetView() })
        } else if let z {
            slider(z)
        }
    }

    @ViewBuilder
    private var viewRows: some View {
        FramingModeControls(cam: cam, footnotes: true)
        if cam.canAutoFrame, cam.autoFraming != .off {
            footnote(cam.isSubjectDetected ? "Following you. Manual framing is paused." : "Looking for a person…")
        }
        framingRow
        if showAll, let af = cam.state("focus-auto") {
            Toggle(af.control.name, isOn: Binding(get: { autoOn(af.id) }, set: { v in withAnimation(.snappy) { cam.set(af.id, [v ? 1 : 0]) } }))
                .help("Let the camera focus by itself. Turn off to set focus manually.")
            if let f = cam.state("focus"), !autoOn("focus-auto") { slider(f) }
        }
        if showAll {
            vendorRows(vendorControls(in: "Framing"))
        }
        if showAll, cam.hasViewControls {
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
                if st.id == "powerline" {
                    footnote("Pick your country's mains frequency: 60 Hz in the Americas, 50 Hz in Europe and most of Asia. Fixes flickering or banding under artificial light.")
                }
            case .panTilt: EmptyView()
            }
        }
    }

    // MARK: Vendor

    /// Profile sections named after a built-in fold ("image", "Framing") render inside it.
    private static let builtInSections: Set<String> = ["framing", "image"]

    private func vendorControls(in section: String) -> [ProfileControl] {
        cam.profileControls.filter { $0.section.lowercased() == section.lowercased() }
    }

    private var vendorGroups: [(String, [ProfileControl])] {
        var order: [String] = [], by: [String: [ProfileControl]] = [:]
        for c in cam.profileControls where !Self.builtInSections.contains(c.section.lowercased()) {
            let key = c.section.lowercased()
            if by[key] == nil { order.append(c.section) }
            by[key, default: []].append(c)
        }
        return order.map { ($0, by[$0.lowercased()]!) }
    }

    private func vendorOpen(_ section: String) -> Binding<Bool> {
        Binding(get: { vendorOpenRaw.split(separator: "\n").contains { $0 == section } },
                set: { open in
                    var set = vendorOpenRaw.split(separator: "\n").map(String.init).filter { $0 != section }
                    if open { set.append(section) }
                    vendorOpenRaw = set.joined(separator: "\n")
                })
    }

    private var vendorSections: some View {
        ForEach(vendorGroups, id: \.0) { section, controls in
            fold(section, vendorOpen(section)) { vendorRows(controls) }
        }
    }

    private func vendorRows(_ controls: [ProfileControl]) -> some View {
        ForEach(controls) { c in
            let enabled = cam.isProfileControlEnabled(c.id)
            Group {
                switch c.ui.kind {
                case .toggle:
                    Toggle(c.title, isOn: Binding(get: { (cam.profileValues[c.id] ?? 0) != 0 },
                                                  set: { v in withAnimation(.snappy) { cam.setProfileValue(c.id, v ? 1 : 0) } }))
                case .picker:
                    Picker(c.title, selection: Binding(get: { Int((cam.profileValues[c.id] ?? 0).rounded()) },
                                                       set: { v in withAnimation(.snappy) { cam.setProfileValue(c.id, Double(v)) } })) {
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
            .help(enabled ? "" : "\(c.title) is unavailable in the current mode.")
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
                      isModified: st.def.map { $0 != cam.value(st.id) } ?? false,
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
                           range: ClosedRange<Double>, step: Double, isModified: Bool = false, onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                if isModified {
                    Button(action: onReset) { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset \(name) to default")
                        .accessibilityLabel("Reset \(name)")
                }
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

