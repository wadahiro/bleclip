import AppKit

enum ClipboardContent {
    case text(String)
    case image(Data) // PNG data

    var typeTag: UInt8 {
        switch self {
        case .text: return 0x01
        case .image: return 0x02
        }
    }

    func toData() -> Data {
        var data = Data([typeTag])
        switch self {
        case .text(let str):
            data.append(Data(str.utf8))
        case .image(let pngData):
            data.append(pngData)
        }
        return data
    }

    static func fromData(_ data: Data) -> ClipboardContent? {
        guard !data.isEmpty else { return nil }
        let tag = data[0]
        let payload = data.subdata(in: 1..<data.count)
        switch tag {
        case 0x01:
            guard let str = String(data: payload, encoding: .utf8) else { return nil }
            return .text(str)
        case 0x02:
            return .image(payload)
        default:
            return nil
        }
    }
}

class ClipboardMonitor {
    private var lastChangeCount: Int
    private var suppressNextChange: Bool = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Returns new clipboard content if changed, nil otherwise.
    func checkForChange() -> ClipboardContent? {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return nil }
        lastChangeCount = currentCount

        if suppressNextChange {
            suppressNextChange = false
            return nil
        }

        let pb = NSPasteboard.general
        let types = pb.types ?? []
        Logger.debug("Clipboard types: \(types.map { $0.rawValue })")

        // Check for image first (higher priority)
        // macOS screenshots may use .png, .tiff, or both
        var imageData: Data? = nil
        if let pngData = pb.data(forType: .png) {
            imageData = pngData
        } else if let tiffData = pb.data(forType: .tiff) {
            let image = NSImage(data: tiffData)
            imageData = image?.pngData()
        }

        if let pngData = imageData {
            // Compress as JPEG for BLE transfer (much smaller than PNG for photos/screenshots)
            let transferData: Data
            if let jpegData = Self.compressToJPEG(pngData, quality: 0.7) {
                Logger.debug("Image compressed: \(pngData.count / 1024)KB PNG -> \(jpegData.count / 1024)KB JPEG")
                transferData = jpegData
            } else {
                transferData = pngData
            }

            if transferData.count > 1_000_000 {
                Logger.info("Image too large for BLE transfer (\(transferData.count / 1024)KB after compression), skipping")
            } else {
                Logger.debug("Clipboard change detected: image (\(transferData.count) bytes)")
                return .image(transferData)
            }
        }

        // Fall back to text
        if let text = pb.string(forType: .string) {
            Logger.debug("Clipboard change detected: text (\(text.count) chars)")
            return .text(text)
        }

        return nil
    }

    /// Sets the local clipboard. Suppresses the next change detection to prevent echo.
    func setClipboard(_ content: ClipboardContent) {
        suppressNextChange = true
        let pb = NSPasteboard.general
        pb.clearContents()

        switch content {
        case .text(let str):
            pb.setString(str, forType: .string)
            Logger.debug("Local clipboard set: text (\(str.count) chars)")
        case .image(let pngData):
            if let image = NSImage(data: pngData) {
                pb.writeObjects([image])
                Logger.debug("Local clipboard set: image (\(pngData.count) bytes)")
            }
        }

        lastChangeCount = pb.changeCount
    }
}

extension ClipboardMonitor {
    /// Compress PNG/TIFF image data to JPEG for smaller BLE transfer
    static func compressToJPEG(_ imageData: Data, quality: Double) -> Data? {
        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
