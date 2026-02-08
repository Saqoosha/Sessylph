import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "ImagePaste")

enum ImagePasteHelper {

    /// Checks the pasteboard for image content and returns a file path.
    /// Returns `nil` if the pasteboard contains only text (caller should fall through to normal paste).
    ///
    /// Priority:
    /// 1. File URL pointing to an image → return its path
    /// 2. TIFF data (e.g. screenshots) → convert to PNG, save to temp, return path
    /// 3. PNG data → save to temp, return path
    static func imagePathFromPasteboard() -> String? {
        let pb = NSPasteboard.general

        // 1. File URL that is an image
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: NSImage.imageTypes,
        ]) as? [URL], let url = urls.first {
            if FileManager.default.fileExists(atPath: url.path) {
                logger.info("Pasting image file URL: \(url.path, privacy: .public)")
                return url.path
            }
        }

        // 2. TIFF data (macOS screenshots are stored as TIFF internally)
        if let tiffData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:])
        {
            return saveTempImage(pngData: pngData)
        }

        // 3. PNG data directly
        if let pngData = pb.data(forType: .png) {
            return saveTempImage(pngData: pngData)
        }

        return nil
    }

    /// Removes paste images older than the given interval (default 1 hour).
    static func cleanupOldTempImages(olderThan interval: TimeInterval = 3600) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sessylph", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-interval)
        for file in files where file.lastPathComponent.hasPrefix("paste-") {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let created = attrs[.creationDate] as? Date,
                  created < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Private

    private static func saveTempImage(pngData: Data) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sessylph", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create temp directory: \(error.localizedDescription)")
            return nil
        }

        let filename = "paste-\(UUID().uuidString.prefix(8)).png"
        let fileURL = tempDir.appendingPathComponent(filename)

        do {
            try pngData.write(to: fileURL)
            logger.info("Saved pasted image to: \(fileURL.path, privacy: .public)")
            return fileURL.path
        } catch {
            logger.error("Failed to save temp image: \(error.localizedDescription)")
            return nil
        }
    }
}
