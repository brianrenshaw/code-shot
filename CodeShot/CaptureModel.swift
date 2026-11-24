import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureKind {
    case area, scrolling, window
}

/// AppKit screen coordinates use a bottom-left origin. ScreenCaptureKit crops in display-local,
/// top-left points. Quartz window metadata uses top-left points relative to the primary display.
struct CaptureRegion {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let rect: CGRect

    var windowID: CGWindowID? = nil

    var sourceRect: CGRect {
        CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    var quartzCenter: CGPoint {
        let display = CGDisplayBounds(displayID)
        return CGPoint(x: display.minX + sourceRect.midX, y: display.minY + sourceRect.midY)
    }
}

struct CaptureContext {
    var app: String?
    var window: String?
    var url: String?

    /// Compact source shown in the note header. The prompt and details use the original URL.
    var displayURL: String? {
        guard let url, let components = URLComponents(string: url) else { return url }
        if components.url?.isFileURL == true { return (components.path as NSString).abbreviatingWithTildeInPath }
        guard let host = components.host, !host.isEmpty else { return url }
        let port = components.port.map { ":\($0)" } ?? ""
        return host + port + (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath)
    }

    var fields: [(String, String)] {
        [("App", app), ("Window", window), ("URL", url)].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }
}

struct SavedCapture {
    let file: URL
    let width: Int
    let height: Int
    let context: CaptureContext

    func prompt(note: String) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["Screenshot: " + file.path]
        lines += context.fields.map { "\($0.0): \($0.1)" }
        lines.append("Image: \(width) × \(height) px")
        return (note.isEmpty ? "" : note + "\n\n") + lines.joined(separator: "\n")
    }
}

struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CaptureFiles {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeShot", isDirectory: true)
    }

    static func save(_ image: CGImage, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let name = "CodeShot \(stamp) \(UUID().uuidString.prefix(8)).png"
        let file = folder.appendingPathComponent(name)
        guard let bytes = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw CaptureError("Couldn’t create the PNG.") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError("Couldn’t encode the PNG.") }
        try (bytes as Data).write(to: file, options: .atomic)
        return file
    }
}
