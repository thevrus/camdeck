import Foundation

/// A command carried by a `camdeck://` URL (Shortcuts, Raycast, `open -g`).
public enum URLCommand: Equatable, Sendable {
    /// Preset by name (case-insensitive) or 1-based index when numeric.
    case preset(String)
    case resetView
    case reset
    case resetImage
    /// One-shot "Fix My Picture": exposure, white balance, focus and anti-flicker from the face.
    case fix
    case lock(Bool)
    /// Camera by localized name or unique ID.
    case camera(String)

    /// Returns the command plus the optional `?camera=` selector, or nil for anything unrecognized.
    public static func parse(_ url: URL) -> (command: URLCommand, camera: String?)? {
        guard url.scheme?.lowercased() == "camdeck",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        // Split the encoded path first so an encoded "%2F" stays inside one argument.
        let args = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        let camera = comps.queryItems?.first { $0.name == "camera" }?.value.flatMap { $0.isEmpty ? nil : $0 }

        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        let command: URLCommand
        switch (host, args.count) {
        case ("preset", 1) where !blank(args[0]): command = .preset(args[0])
        case ("reset-view", 0): command = .resetView
        case ("reset", 0): command = .reset
        case ("reset-image", 0): command = .resetImage
        case ("fix", 0): command = .fix
        case ("lock", 1) where args[0].lowercased() == "on": command = .lock(true)
        case ("lock", 1) where args[0].lowercased() == "off": command = .lock(false)
        case ("camera", 1) where !blank(args[0]): command = .camera(args[0])
        default: return nil
        }
        return (command, camera)
    }
}
