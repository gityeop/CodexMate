import AppKit

@MainActor
final class MenubarStatusSpriteCatalog {
    private enum Metrics {
        static let defaultFrameCount = 6
        static let renderedPixelSize = 36
        static let renderedPointSize = NSSize(width: 18, height: 18)
    }

    private struct SpriteSheetLayout {
        let columns: Int
        let rows: Int

        var frameCount: Int {
            columns * rows
        }
    }

    private struct RenderedFrameKey: Hashable {
        let sprite: MenubarStatusPresentation.StatusSprite
        let frameIndex: Int
        let renderedPixelSize: Int
        let renderedPointWidth: Int
        let renderedPointHeight: Int
    }

    private var cachedSourceFramesBySprite: [MenubarStatusPresentation.StatusSprite: [CGImage]] = [:]
    private var cachedRenderedFramesByKey: [RenderedFrameKey: NSImage] = [:]

    func frame(
        for sprite: MenubarStatusPresentation.StatusSprite,
        index: Int,
        tintColor: NSColor,
        renderedPixelSize: Int = Metrics.renderedPixelSize,
        renderedPointSize: NSSize = Metrics.renderedPointSize
    ) -> NSImage? {
        let sourceFrames = sourceFrames(for: sprite)
        guard !sourceFrames.isEmpty else { return nil }
        return renderTintedFrame(
            sourceFrames[index % sourceFrames.count],
            tintColor: tintColor,
            renderedPixelSize: renderedPixelSize,
            renderedPointSize: renderedPointSize
        )
    }

    func notchFrame(
        for sprite: MenubarStatusPresentation.StatusSprite,
        index: Int,
        renderedPixelSize: Int,
        renderedPointSize: NSSize
    ) -> NSImage? {
        let sourceFrames = sourceFrames(for: sprite)
        guard !sourceFrames.isEmpty else { return nil }
        let normalizedIndex = index % sourceFrames.count
        let cacheKey = RenderedFrameKey(
            sprite: sprite,
            frameIndex: normalizedIndex,
            renderedPixelSize: renderedPixelSize,
            renderedPointWidth: Int(renderedPointSize.width.rounded()),
            renderedPointHeight: Int(renderedPointSize.height.rounded())
        )
        if let cachedFrame = cachedRenderedFramesByKey[cacheKey] {
            return cachedFrame
        }

        let renderedFrame = renderOriginalFrame(
            sourceFrames[normalizedIndex],
            renderedPixelSize: renderedPixelSize,
            renderedPointSize: renderedPointSize
        )
        if let renderedFrame {
            cachedRenderedFramesByKey[cacheKey] = renderedFrame
        }

        return renderedFrame
    }

    func frameCount(for sprite: MenubarStatusPresentation.StatusSprite) -> Int {
        sourceFrames(for: sprite).count
    }

    private func sourceFrames(for sprite: MenubarStatusPresentation.StatusSprite) -> [CGImage] {
        if let cachedFrames = cachedSourceFramesBySprite[sprite] {
            return cachedFrames
        }

        let frames = loadSourceFrames(for: sprite)
        cachedSourceFramesBySprite[sprite] = frames
        return frames
    }

    private func loadSourceFrames(for sprite: MenubarStatusPresentation.StatusSprite) -> [CGImage] {
        let layout = spriteSheetLayout(for: sprite)
        guard let resourceBundle = CodexMateResourceLocator.bundle else {
            DebugTraceLogger.log("status sprite missing bundle sprite=\(sprite.assetName)")
            return []
        }

        guard let spriteSheet = loadSpriteSheetImage(for: sprite, from: resourceBundle) else {
            DebugTraceLogger.log("status sprite missing image sprite=\(sprite.assetName)")
            return []
        }

        var proposedRect = NSRect(origin: .zero, size: spriteSheet.size)
        guard let spriteSheetCGImage = spriteSheet.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            DebugTraceLogger.log("status sprite missing cgimage sprite=\(sprite.assetName)")
            return []
        }

        let trimmedWidth = spriteSheetCGImage.width - (spriteSheetCGImage.width % layout.columns)
        let trimmedHeight = spriteSheetCGImage.height - (spriteSheetCGImage.height % layout.rows)
        guard trimmedWidth > 0, trimmedHeight > 0 else {
            return []
        }

        let horizontalInset = (spriteSheetCGImage.width - trimmedWidth) / 2
        let verticalInset = (spriteSheetCGImage.height - trimmedHeight) / 2
        let usableSheet: CGImage
        if horizontalInset > 0 || verticalInset > 0 {
            guard let croppedSheet = spriteSheetCGImage.cropping(
                to: CGRect(
                    x: horizontalInset,
                    y: verticalInset,
                    width: trimmedWidth,
                    height: trimmedHeight
                )
            ) else {
                return []
            }
            usableSheet = croppedSheet
        } else {
            usableSheet = spriteSheetCGImage
        }

        let frameWidth = usableSheet.width / layout.columns
        let frameHeight = usableSheet.height / layout.rows
        guard frameWidth > 0, frameHeight > 0 else {
            return []
        }

        return (0..<layout.frameCount).compactMap { frameIndex in
            let rowIndex = frameIndex / layout.columns
            let columnIndex = frameIndex % layout.columns
            let cropRect = CGRect(
                x: columnIndex * frameWidth,
                y: rowIndex * frameHeight,
                width: frameWidth,
                height: frameHeight
            )
            return usableSheet.cropping(to: cropRect)
        }
    }

    private func loadSpriteSheetImage(
        for sprite: MenubarStatusPresentation.StatusSprite,
        from resourceBundle: Bundle
    ) -> NSImage? {
        if let assetImage = resourceBundle.image(forResource: NSImage.Name(sprite.assetName)) {
            return assetImage
        }

        let subdirectory = "StatusSprites.xcassets/\(sprite.assetName).imageset"
        if let spriteSheetURL = resourceBundle.url(
            forResource: "sprite_sheet",
            withExtension: "png",
            subdirectory: subdirectory
        ) {
            return NSImage(contentsOf: spriteSheetURL)
        }

        return nil
    }

    private func renderTintedFrame(
        _ source: CGImage,
        tintColor: NSColor,
        renderedPixelSize: Int,
        renderedPointSize: NSSize
    ) -> NSImage? {
        guard let bitmap = makeBitmap(pixels: renderedPixelSize),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: renderedPixelSize, height: renderedPixelSize)
        context.clear(rect)
        context.interpolationQuality = .none
        context.draw(source, in: aspectFitRect(for: source, in: rect))
        context.setBlendMode(.sourceIn)
        context.setFillColor(tintColor.cgColor)
        context.fill(rect)

        return makeImage(bitmap: bitmap, size: renderedPointSize)
    }

    private func renderOriginalFrame(
        _ source: CGImage,
        renderedPixelSize: Int,
        renderedPointSize: NSSize
    ) -> NSImage? {
        guard let bitmap = makeBitmap(pixels: renderedPixelSize),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: renderedPixelSize, height: renderedPixelSize)
        context.clear(rect)
        context.interpolationQuality = .none
        context.draw(source, in: aspectFitRect(for: source, in: rect))

        return makeImage(bitmap: bitmap, size: renderedPointSize)
    }

    private func spriteSheetLayout(for sprite: MenubarStatusPresentation.StatusSprite) -> SpriteSheetLayout {
        _ = sprite
        return SpriteSheetLayout(columns: 3, rows: 3)
    }

    private func aspectFitRect(for source: CGImage, in bounds: CGRect) -> CGRect {
        let widthScale = bounds.width / CGFloat(source.width)
        let heightScale = bounds.height / CGFloat(source.height)
        let scale = min(widthScale, heightScale)
        let fittedWidth = CGFloat(source.width) * scale
        let fittedHeight = CGFloat(source.height) * scale

        return CGRect(
            x: bounds.midX - (fittedWidth / 2),
            y: bounds.midY - (fittedHeight / 2),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private func makeBitmap(pixels: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private func makeImage(bitmap: NSBitmapImageRep, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}
