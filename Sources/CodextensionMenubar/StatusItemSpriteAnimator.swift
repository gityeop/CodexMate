import AppKit

@MainActor
final class StatusItemSpriteAnimator {
    private static let alertFrameRects: [NSRect] = [
        NSRect(x: 212, y: 600, width: 240, height: 320),
        NSRect(x: 430, y: 600, width: 240, height: 320),
        NSRect(x: 648, y: 600, width: 240, height: 320),
        NSRect(x: 866, y: 600, width: 240, height: 320),
        NSRect(x: 1084, y: 600, width: 240, height: 320),
    ]

    private static let idleFrameRects: [NSRect] = [
        NSRect(x: 212, y: 100, width: 240, height: 320),
        NSRect(x: 430, y: 100, width: 240, height: 320),
        NSRect(x: 648, y: 100, width: 240, height: 320),
        NSRect(x: 866, y: 100, width: 240, height: 320),
        NSRect(x: 1084, y: 100, width: 240, height: 320),
    ]

    private let alertFrames: [NSImage]
    private let idleFrames: [NSImage]
    private let fallbackIcon: NSImage?
    private var frameIndex = 0
    private var lastMode: AppStateStore.StatusIconAnimationMode?

    init(spriteSheetURL: URL, fallbackIconURL: URL?) {
        let spriteSheet = NSImage(contentsOf: spriteSheetURL)
        alertFrames = Self.makeFrames(from: spriteSheet, rects: Self.alertFrameRects)
        idleFrames = Self.makeFrames(from: spriteSheet, rects: Self.idleFrameRects)

        if let fallbackIconURL, let image = NSImage(contentsOf: fallbackIconURL) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            fallbackIcon = image
        } else {
            fallbackIcon = nil
        }
    }

    func currentImage(mode: AppStateStore.StatusIconAnimationMode) -> NSImage? {
        prepare(for: mode)
        return currentFrame(mode: mode) ?? fallbackIcon
    }

    func advance(mode: AppStateStore.StatusIconAnimationMode) -> NSImage? {
        prepare(for: mode)

        let frames = frames(for: mode)
        guard !frames.isEmpty else { return fallbackIcon }

        frameIndex = (frameIndex + 1) % frames.count
        return frames[frameIndex]
    }

    private func prepare(for mode: AppStateStore.StatusIconAnimationMode) {
        if lastMode != mode {
            lastMode = mode
            frameIndex = 0
        }
    }

    private func currentFrame(mode: AppStateStore.StatusIconAnimationMode) -> NSImage? {
        let frames = frames(for: mode)
        guard !frames.isEmpty else { return nil }
        return frames[min(frameIndex, frames.count - 1)]
    }

    private func frames(for mode: AppStateStore.StatusIconAnimationMode) -> [NSImage] {
        switch mode {
        case .alert:
            return alertFrames
        case .idle:
            return idleFrames
        }
    }

    private static func makeFrames(from image: NSImage?, rects: [NSRect]) -> [NSImage] {
        guard let image else { return [] }

        return rects.compactMap { rect in
            let frame = NSImage(size: rect.size)
            frame.lockFocus()
            image.draw(
                in: NSRect(origin: .zero, size: rect.size),
                from: rect,
                operation: .copy,
                fraction: 1
            )
            frame.unlockFocus()
            frame.size = NSSize(width: 18, height: 18)
            frame.isTemplate = false
            return frame
        }
    }
}
