//
//  AIAnalysisExporter.swift
//  Stratify
//
//  Creates a diagnostic vertical strip image for AI analysis
//

import Foundation
import AppKit
import UniformTypeIdentifiers

struct AIAnalysisExporter {

    enum ExportResult {
        case success
        case cancelled
        case failed(Error)
    }

    /// Export a vertical strip showing source image and all layers for AI analysis
    /// - Parameters:
    ///   - sourceImage: Original source icon image
    ///   - layers: Array of layers to include
    /// - Returns: Result of the export operation (success, cancelled, or failed)
    static func exportForAIAnalysis(sourceImage: NSImage, layers: [Layer]) -> ExportResult {
        guard !layers.isEmpty else {
            return .failed(NSError(domain: "AIAnalysisExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No layers to export"]))
        }

        // Generate unique 2-letter codes for each layer
        let layerCodes = generateUniqueLayerCodes(count: layers.count)

        // Configuration
        let scale: CGFloat = 0.3  // 30% scale
        let imageSize: CGFloat = 1024 * scale  // ~307px
        let padding: CGFloat = 20
        let textHeight: CGFloat = 20
        let imageSpacing: CGFloat = 15
        let sectionSpacing: CGFloat = 20

        // Calculate total height
        let headerHeight = textHeight + imageSpacing
        let sourceSection = headerHeight + imageSize + sectionSpacing
        let layersHeaderHeight = textHeight + imageSpacing
        let perLayerHeight = textHeight + imageSpacing + imageSize + imageSpacing
        let totalHeight = sourceSection + layersHeaderHeight + CGFloat(layers.count) * perLayerHeight + padding * 2

        let width = imageSize + padding * 2

        // Create white background image
        let size = NSSize(width: width, height: totalHeight)
        let stripImage = NSImage(size: size)

        stripImage.lockFocus()

        // Fill white background
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        var yPosition = totalHeight - padding

        // Helper to draw text
        func drawText(_ text: String, bold: Bool = false) {
            let font = bold ? NSFont.boldSystemFont(ofSize: 14) : NSFont.systemFont(ofSize: 12)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = NSRect(
                x: padding,
                y: yPosition - textHeight,
                width: textSize.width,
                height: textHeight
            )
            text.draw(in: textRect, withAttributes: attributes)
            yPosition -= textHeight + imageSpacing
        }

        // Helper to draw checkerboard pattern (matches UI CheckerboardBackground)
        func drawCheckerboard(in rect: NSRect) {
            let squareSize: CGFloat = 10
            let lightGray = NSColor(white: 0.95, alpha: 1.0)
            let darkGray = NSColor(white: 0.85, alpha: 1.0)

            NSGraphicsContext.current?.saveGraphicsState()

            let cols = Int(ceil(rect.width / squareSize))
            let rows = Int(ceil(rect.height / squareSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let color = isEven ? lightGray : darkGray

                    color.setFill()
                    let squareRect = NSRect(
                        x: rect.origin.x + CGFloat(col) * squareSize,
                        y: rect.origin.y + CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    squareRect.fill()
                }
            }

            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Helper to draw image with checkerboard background
        func drawImage(_ image: NSImage) {
            let imageRect = NSRect(
                x: padding,
                y: yPosition - imageSize,
                width: imageSize,
                height: imageSize
            )

            // Draw checkerboard pattern behind image
            drawCheckerboard(in: imageRect)

            // Draw image with transparency preserved
            image.draw(
                in: imageRect,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1.0
            )

            yPosition -= imageSize + imageSpacing
        }

        // Draw "Original source icon image:"
        drawText("Original source icon image:", bold: true)

        // Draw source image at 30% scale
        if let scaledSource = scaleImage(sourceImage, toSize: NSSize(width: imageSize, height: imageSize)) {
            drawImage(scaledSource)
        }

        yPosition -= sectionSpacing

        // Draw "Compositing layers:"
        drawText("Compositing layers:", bold: true)

        // Draw each layer with its code
        for (index, layer) in layers.enumerated() {
            let code = layerCodes[index]
            drawText("Layer '\(code)':")

            if let layerImage = layer.image,
               let scaledLayer = scaleImage(layerImage, toSize: NSSize(width: imageSize, height: imageSize)) {
                drawImage(scaledLayer)
            }
        }

        stripImage.unlockFocus()

        // Show save dialog
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.jpeg]
        savePanel.nameFieldStringValue = "layer_analysis.jpg"
        savePanel.title = "Export for AI Analysis"
        savePanel.message = "Save diagnostic image for AI layer analysis"

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return .cancelled
        }

        // Convert to JPEG and save
        guard let tiffData = stripImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            return .failed(NSError(domain: "AIAnalysisExporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG format"]))
        }

        do {
            try jpegData.write(to: url)
            return .success
        } catch {
            print("Failed to save AI analysis export: \(error)")
            return .failed(error)
        }
    }

    /// Generate unique random 2-letter uppercase codes
    private static func generateUniqueLayerCodes(count: Int) -> [String] {
        var codes = Set<String>()
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

        while codes.count < count {
            let index1 = Int.random(in: 0..<letters.count)
            let index2 = Int.random(in: 0..<letters.count)
            let letter1 = letters[letters.index(letters.startIndex, offsetBy: index1)]
            let letter2 = letters[letters.index(letters.startIndex, offsetBy: index2)]
            let code = "\(letter1)\(letter2)"
            codes.insert(code)
        }

        return Array(codes)
    }

    /// Scale an image to a specific size while maintaining aspect ratio
    private static func scaleImage(_ image: NSImage, toSize targetSize: NSSize) -> NSImage? {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()

        // Draw with high quality
        NSGraphicsContext.current?.imageInterpolation = .high

        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0
        )

        newImage.unlockFocus()
        return newImage
    }
}
