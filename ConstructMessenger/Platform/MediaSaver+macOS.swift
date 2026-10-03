#if os(macOS)
import AppKit
import UniformTypeIdentifiers

extension MediaSaver {
    enum Outcome { case saved, cancelled, failed }

    /// `true` if a PNG was written; `false` if the panel was cancelled or encoding failed.
    @MainActor
    static func save(_ image: NSImage) async -> Bool {
        export(image: image) == .saved
    }

    /// Ask where to put a PNG of `image`. Cancelling is not a failure.
    @MainActor
    static func export(image: NSImage) -> Outcome {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return .failed }
        guard let url = askForDestination(name: "image.png", type: .png) else { return .cancelled }
        return (try? png.write(to: url)) != nil ? .saved : .failed
    }

    /// Ask where to put a copy of the file at `source`. Cancelling is not a failure.
    @MainActor
    static func export(fileAt source: URL, suggestedName: String? = nil) -> Outcome {
        let name = suggestedName ?? source.lastPathComponent
        guard let destination = askForDestination(
            name: name,
            type: UTType(filenameExtension: (name as NSString).pathExtension)
        ) else { return .cancelled }
        do {
            // The panel has already confirmed the overwrite.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return .saved
        } catch {
            Log.error("MediaSaver: copy failed: \(error)", category: "MediaSaver")
            return .failed
        }
    }

    @MainActor
    private static func askForDestination(name: String, type: UTType?) -> URL? {
        let panel = NSSavePanel()
        if let type { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif
