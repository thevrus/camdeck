import SwiftUI

/// Framing mini-map: the crop rectangle shows the visible region inside the full sensor field.
/// Drag moves the crop (pan/tilt), pinch or the +/- buttons zoom, double-click resets.
struct FramingPad: View {
    let zoomMin: Int
    let zoomMax: Int
    let zoom: Int
    let panTiltMin: [Int]
    let panTiltMax: [Int]
    let panTilt: [Int]
    var isLocked: Bool = false
    let onZoom: (Int) -> Void
    let onPanTilt: ([Int]) -> Void
    let onReset: () -> Void

    @State private var dragOffset: CGSize?
    @State private var pinchBase: Int?

    private var zoomFactor: Double { zoomMin > 0 ? max(Double(zoom) / Double(zoomMin), 1) : 1 }
    private var panTiltValid: Bool { panTilt.count >= 2 && panTiltMin.count >= 2 && panTiltMax.count >= 2 }

    private func unit(_ v: Int, _ i: Int) -> Double {
        let lo = Double(panTiltMin[i]), hi = Double(panTiltMax[i])
        return hi > lo ? min(max((Double(v) - lo) / (hi - lo), 0), 1) : 0.5
    }

    private func rectSize(_ field: CGSize) -> CGSize {
        CGSize(width: field.width / zoomFactor, height: field.height / zoomFactor)
    }

    private func rectOrigin(_ field: CGSize) -> CGPoint {
        let r = rectSize(field)
        guard panTiltValid else { return .zero }
        return CGPoint(x: unit(panTilt[0], 0) * (field.width - r.width),
                       y: (1 - unit(panTilt[1], 1)) * (field.height - r.height))
    }

    private func step(_ dir: Int) {
        let inc = max(zoomMin / 10, 1)
        onZoom(min(max(zoom + dir * inc, zoomMin), zoomMax))
    }

    private func drag(_ g: DragGesture.Value, field: CGSize) {
        guard !isLocked, panTiltValid else { return }
        let r = rectSize(field)
        let o = rectOrigin(field)
        if dragOffset == nil {
            let inside = CGRect(origin: o, size: r).contains(g.startLocation)
            dragOffset = inside
                ? CGSize(width: g.startLocation.x - (o.x + r.width / 2), height: g.startLocation.y - (o.y + r.height / 2))
                : .zero
        }
        let off = dragOffset ?? .zero
        let tx = field.width - r.width, ty = field.height - r.height
        let nx = min(max(g.location.x - off.width - r.width / 2, 0), tx)
        let ny = min(max(g.location.y - off.height - r.height / 2, 0), ty)
        var out = panTilt
        if tx > 0 {
            out[0] = panTiltMin[0] + Int((nx / tx * Double(panTiltMax[0] - panTiltMin[0])).rounded())
        }
        if ty > 0 {
            out[1] = panTiltMin[1] + Int(((1 - ny / ty) * Double(panTiltMax[1] - panTiltMin[1])).rounded())
        }
        if out != panTilt { onPanTilt(out) }
    }

    var body: some View {
        VStack(spacing: 8) {
            field
            LabeledContent("Zoom") {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f×", zoomFactor))
                        .foregroundStyle(.secondary).monospacedDigit()
                    ControlGroup {
                        Button { step(-1) } label: { Label("Zoom Out", systemImage: "minus") }
                            .disabled(isLocked || zoom <= zoomMin)
                            .help("Zoom Out")
                        Button { step(1) } label: { Label("Zoom In", systemImage: "plus") }
                            .disabled(isLocked || zoom >= zoomMax)
                            .help("Zoom In")
                    }
                    .labelStyle(.iconOnly)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    let r = rectSize(size)
                    let o = rectOrigin(size)
                    ZStack {
                        if zoomFactor > 1 {
                            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12))
                        }
                        RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: zoomFactor > 1 ? 2 : 1)
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: o.x + r.width / 2, y: o.y + r.height / 2)
                    .animation(.easeOut(duration: 0.18), value: zoom)
                    .animation(dragOffset == nil ? .easeOut(duration: 0.18) : nil, value: panTilt)
                    .allowsHitTesting(false)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag($0, field: size) }
                            .onEnded { _ in dragOffset = nil })
                        .simultaneousGesture(MagnifyGesture().onChanged { g in
                            guard !isLocked else { return }
                            let base = pinchBase ?? zoom
                            pinchBase = base
                            onZoom(min(max(Int((Double(base) * g.magnification).rounded()), zoomMin), zoomMax))
                        }.onEnded { _ in pinchBase = nil })
                        .onTapGesture(count: 2) { if !isLocked { onReset() } }
                }
            }
            .opacity(isLocked ? 0.6 : 1)
            .contextMenu { Button("Reset View", action: onReset).disabled(isLocked) }
            .accessibilityElement()
            .accessibilityLabel("Framing")
            .accessibilityValue(String(format: "%.1f× zoom", zoomFactor))
    }
}
