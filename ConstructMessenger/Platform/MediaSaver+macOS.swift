#if os(macOS)
import AppKit
import UniformTypeIdentifiers

extension MediaSaver {
    /// `true` if a PNG was written; `false` if the panel was cancelled or encoding failed.
    @MainActor
    static func save(_ image: NSImage) async -> Bool {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "image.png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
