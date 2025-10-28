//
//  IconBundleExporter.swift
//  Stratify
//
//  Exports layers as an Apple Icon Composer bundle (.icon)
//

import Foundation
import AppKit

enum ExportError: LocalizedError {
    case noLayers
    case failedToCreateDirectory
    case failedToSaveImage(String)
    case failedToWriteJSON

    var errorDescription: String? {
        switch self {
        case .noLayers:
            return "No layers to export"
        case .failedToCreateDirectory:
            return "Failed to create bundle directory"
        case .failedToSaveImage(let name):
            return "Failed to save image: \(name)"
        case .failedToWriteJSON:
            return "Failed to write icon.json"
        }
    }
}

struct IconBundleExporter {

    /// Export layers as a .icon bundle to the specified URL
    /// - Parameters:
    ///   - layers: Array of Layer objects to export
    ///   - sourceImage: Original unprocessed source image for color extraction
    ///   - bundleURL: URL where the .icon bundle should be created (must end in .icon)
    static func exportIconBundle(layers: [Layer], sourceImage: NSImage, to bundleURL: URL) throws {
        guard !layers.isEmpty else {
            throw ExportError.noLayers
        }

        // Create bundle directory structure
        let assetsURL = bundleURL.appendingPathComponent("Assets", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        } catch {
            throw ExportError.failedToCreateDirectory
        }

        // Sort layers by pixel count (smallest first for top-to-bottom ordering)
        let sortedLayers = layers.sorted { $0.pixelCount < $1.pixelCount }

        // Save layer images and create groups
        var groups: [[String: Any]] = []

        // Get the expected pixel dimensions from the source image
        guard let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.failedToSaveImage("source image")
        }

        let expectedWidth = sourceCGImage.width
        let expectedHeight = sourceCGImage.height

        // Diagnostic: Log source image details
        print("🎨 Source: \(sourceImage.size) points, \(sourceCGImage.width)×\(sourceCGImage.height)px, \(sourceCGImage.bitsPerComponent)-bit")

        for (index, layer) in sortedLayers.enumerated() {
            // Save PNG file with explicit dimensions
            let imageFilename = "layer_\(index).png"
            let imageURL = assetsURL.appendingPathComponent(imageFilename)

            // Step 1: Get the CGImage directly from the layer
            guard let layerMaskCGImage = layer.cgImage else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            // Diagnostic: Log layer details before processing
            print("📦 Layer \(index) '\(layer.name)': \(layerMaskCGImage.width)×\(layerMaskCGImage.height)px, \(layerMaskCGImage.bitsPerComponent)-bit")

            // Step 2: Create output bitmap matching source bit depth
            let sourceBitsPerComponent = sourceCGImage.bitsPerComponent
            let bytesPerSample = sourceBitsPerComponent / 8
            let bytesPerRow = expectedWidth * bytesPerSample * 4  // 4 channels (RGBA)

            guard let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: expectedWidth,
                pixelsHigh: expectedHeight,
                bitsPerSample: sourceBitsPerComponent,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: bytesPerRow,
                bitsPerPixel: sourceBitsPerComponent * 4
            ) else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            // Step 3: Apply mask from layer to source image colors
            let bitmapData = bitmapRep.bitmapData
            guard let outputPixels = bitmapData else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            // Get source image data
            guard let sourceDataProvider = sourceCGImage.dataProvider,
                  let sourceData = sourceDataProvider.data,
                  let sourcePixels = CFDataGetBytePtr(sourceData) else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            // Get mask data
            guard let maskDataProvider = layerMaskCGImage.dataProvider,
                  let maskData = maskDataProvider.data,
                  let maskPixels = CFDataGetBytePtr(maskData) else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            let sourceBytesPerPixel = sourceCGImage.bitsPerPixel / 8
            let maskBytesPerPixel = layerMaskCGImage.bitsPerPixel / 8
            let sourceBytesPerRow = sourceCGImage.bytesPerRow
            let maskBytesPerRow = layerMaskCGImage.bytesPerRow

            // Apply mask: take colors from source, alpha from mask
            // Handle both 8-bit and 16-bit data
            if sourceBitsPerComponent == 16 {
                // 16-bit processing - reinterpret byte pointers as UInt16
                let sourcePtr16 = sourcePixels.withMemoryRebound(to: UInt16.self, capacity: sourceBytesPerRow * expectedHeight / 2) { $0 }
                let maskPtr16 = maskPixels.withMemoryRebound(to: UInt16.self, capacity: maskBytesPerRow * expectedHeight / 2) { $0 }
                let outputPtr16 = outputPixels.withMemoryRebound(to: UInt16.self, capacity: expectedWidth * expectedHeight * 4) { $0 }

                for y in 0..<expectedHeight {
                    for x in 0..<expectedWidth {
                        let sourcePixelOffset = (y * sourceBytesPerRow / 2) + x * (sourceBytesPerPixel / 2)
                        let maskPixelOffset = (y * maskBytesPerRow / 2) + x * (maskBytesPerPixel / 2)
                        let outputPixelOffset = (y * expectedWidth + x) * 4

                        // Extract RGB from source
                        let sourceR: UInt16
                        let sourceG: UInt16
                        let sourceB: UInt16

                        if sourceCGImage.alphaInfo == .premultipliedFirst || sourceCGImage.alphaInfo == .first {
                            if sourceCGImage.byteOrderInfo == .order32Little {
                                // BGRA
                                sourceB = sourcePtr16[sourcePixelOffset + 0]
                                sourceG = sourcePtr16[sourcePixelOffset + 1]
                                sourceR = sourcePtr16[sourcePixelOffset + 2]
                            } else {
                                // ARGB
                                sourceR = sourcePtr16[sourcePixelOffset + 1]
                                sourceG = sourcePtr16[sourcePixelOffset + 2]
                                sourceB = sourcePtr16[sourcePixelOffset + 3]
                            }
                        } else {
                            // RGBA
                            sourceR = sourcePtr16[sourcePixelOffset + 0]
                            sourceG = sourcePtr16[sourcePixelOffset + 1]
                            sourceB = sourcePtr16[sourcePixelOffset + 2]
                        }

                        // Extract alpha from mask (last channel)
                        let maskAlpha = maskPtr16[maskPixelOffset + (maskBytesPerPixel / 2) - 1]

                        // Write RGBA to output
                        outputPtr16[outputPixelOffset + 0] = sourceR
                        outputPtr16[outputPixelOffset + 1] = sourceG
                        outputPtr16[outputPixelOffset + 2] = sourceB
                        outputPtr16[outputPixelOffset + 3] = maskAlpha
                    }
                }
            } else {
                // 8-bit processing (original code)
                for y in 0..<expectedHeight {
                    for x in 0..<expectedWidth {
                        let sourceOffset = y * sourceBytesPerRow + x * sourceBytesPerPixel
                        let maskOffset = y * maskBytesPerRow + x * maskBytesPerPixel
                        let outputOffset = (y * expectedWidth + x) * 4

                        // Extract RGB from source (handle different pixel formats)
                        let sourceR: UInt8
                        let sourceG: UInt8
                        let sourceB: UInt8

                        if sourceCGImage.alphaInfo == .premultipliedFirst || sourceCGImage.alphaInfo == .first {
                            // ARGB or BGRA format
                            if sourceCGImage.byteOrderInfo == .order32Little {
                                // BGRA
                                sourceB = sourcePixels[sourceOffset + 0]
                                sourceG = sourcePixels[sourceOffset + 1]
                                sourceR = sourcePixels[sourceOffset + 2]
                            } else {
                                // ARGB
                                sourceR = sourcePixels[sourceOffset + 1]
                                sourceG = sourcePixels[sourceOffset + 2]
                                sourceB = sourcePixels[sourceOffset + 3]
                            }
                        } else {
                            // RGBA format
                            sourceR = sourcePixels[sourceOffset + 0]
                            sourceG = sourcePixels[sourceOffset + 1]
                            sourceB = sourcePixels[sourceOffset + 2]
                        }

                        // Extract alpha from mask (always last byte in RGBA)
                        let maskAlpha = maskPixels[maskOffset + maskBytesPerPixel - 1]

                        // Write RGBA to output
                        outputPixels[outputOffset + 0] = sourceR
                        outputPixels[outputOffset + 1] = sourceG
                        outputPixels[outputOffset + 2] = sourceB
                        outputPixels[outputOffset + 3] = maskAlpha
                    }
                }
            }

            // Save as PNG
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            do {
                try pngData.write(to: imageURL)
            } catch {
                throw ExportError.failedToSaveImage(imageFilename)
            }

            // Create group for this layer
            let isBottomLayer = (index == sortedLayers.count - 1)  // Last in list = largest = bottom layer

            var layerDict: [String: Any] = [
                "image-name": imageFilename,
                "name": "layer_\(index)",
                "fill": "automatic",
                "hidden": false
            ]

            // Add glass effect only to bottom layer
            if isBottomLayer {
                layerDict["glass"] = true
            }

            let group: [String: Any] = [
                "hidden": false,
                "layers": [layerDict],
                "shadow": [
                    "kind": "layer-color",
                    "opacity": 0.5
                ],
                "translucency": [
                    "enabled": true,
                    "value": 0.4
                ],
                "lighting": isBottomLayer ? "individual" : "combined",
                "specular": true
            ]

            groups.append(group)
        }

        // Create icon.json
        let iconJSON: [String: Any] = [
            "fill": "automatic",
            "groups": groups,
            "supported-platforms": [
                "circles": ["watchOS"],
                "squares": "shared"
            ]
        ]

        // Write icon.json with proper formatting
        let iconJSONURL = bundleURL.appendingPathComponent("icon.json")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: iconJSONURL)
        } catch {
            throw ExportError.failedToWriteJSON
        }
    }

    /// Export layers with advanced grouping and appearance options
    /// - Parameters:
    ///   - layerGroups: Array of LayerGroup objects with custom effects
    ///   - sourceImage: Original unprocessed source image for color extraction
    ///   - bundleURL: URL where the .icon bundle should be created
    static func exportIconBundleWithGroups(layerGroups: [LayerGroup], sourceImage: NSImage, to bundleURL: URL) throws {
        // Extract all layers from groups
        let allLayers = layerGroups.flatMap { $0.layers }
        guard !allLayers.isEmpty else {
            throw ExportError.noLayers
        }

        // Create bundle directory structure
        let assetsURL = bundleURL.appendingPathComponent("Assets", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        } catch {
            throw ExportError.failedToCreateDirectory
        }

        // Get the expected pixel dimensions from the source image
        guard let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.failedToSaveImage("source image")
        }

        let expectedWidth = sourceCGImage.width
        let expectedHeight = sourceCGImage.height

        // Diagnostic: Log source image details
        print("🎨 Source (with groups): \(sourceImage.size) points, \(sourceCGImage.width)×\(sourceCGImage.height)px, \(sourceCGImage.bitsPerComponent)-bit")

        // Save all layer images and create groups
        var groups: [[String: Any]] = []
        var imageIndex = 0

        for group in layerGroups {
            var groupLayers: [[String: Any]] = []

            for layer in group.layers {
                // Save PNG file with explicit dimensions
                let imageFilename = "layer_\(imageIndex).png"
                let imageURL = assetsURL.appendingPathComponent(imageFilename)

                // Step 1: Get the CGImage directly from the layer
                guard let layerMaskCGImage = layer.cgImage else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                // Diagnostic: Log layer details before processing
                print("📦 Layer \(imageIndex) '\(layer.name)': \(layerMaskCGImage.width)×\(layerMaskCGImage.height)px, \(layerMaskCGImage.bitsPerComponent)-bit")

                // Step 2: Create output bitmap matching source bit depth
                let sourceBitsPerComponent = sourceCGImage.bitsPerComponent
                let bytesPerSample = sourceBitsPerComponent / 8
                let bytesPerRow = expectedWidth * bytesPerSample * 4  // 4 channels (RGBA)

                guard let bitmapRep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: expectedWidth,
                    pixelsHigh: expectedHeight,
                    bitsPerSample: sourceBitsPerComponent,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: bytesPerRow,
                    bitsPerPixel: sourceBitsPerComponent * 4
                ) else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                // Step 3: Apply mask from layer to source image colors
                let bitmapData = bitmapRep.bitmapData
                guard let outputPixels = bitmapData else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                // Get source image data
                guard let sourceDataProvider = sourceCGImage.dataProvider,
                      let sourceData = sourceDataProvider.data,
                      let sourcePixels = CFDataGetBytePtr(sourceData) else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                // Get mask data
                guard let maskDataProvider = layerMaskCGImage.dataProvider,
                      let maskData = maskDataProvider.data,
                      let maskPixels = CFDataGetBytePtr(maskData) else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                let sourceBytesPerPixel = sourceCGImage.bitsPerPixel / 8
                let maskBytesPerPixel = layerMaskCGImage.bitsPerPixel / 8
                let sourceBytesPerRow = sourceCGImage.bytesPerRow
                let maskBytesPerRow = layerMaskCGImage.bytesPerRow

                // Apply mask: take colors from source, alpha from mask
                // Handle both 8-bit and 16-bit data
                if sourceBitsPerComponent == 16 {
                    // 16-bit processing - reinterpret byte pointers as UInt16
                    let sourcePtr16 = sourcePixels.withMemoryRebound(to: UInt16.self, capacity: sourceBytesPerRow * expectedHeight / 2) { $0 }
                    let maskPtr16 = maskPixels.withMemoryRebound(to: UInt16.self, capacity: maskBytesPerRow * expectedHeight / 2) { $0 }
                    let outputPtr16 = outputPixels.withMemoryRebound(to: UInt16.self, capacity: expectedWidth * expectedHeight * 4) { $0 }

                    for y in 0..<expectedHeight {
                        for x in 0..<expectedWidth {
                            let sourcePixelOffset = (y * sourceBytesPerRow / 2) + x * (sourceBytesPerPixel / 2)
                            let maskPixelOffset = (y * maskBytesPerRow / 2) + x * (maskBytesPerPixel / 2)
                            let outputPixelOffset = (y * expectedWidth + x) * 4

                            // Extract RGB from source
                            let sourceR: UInt16
                            let sourceG: UInt16
                            let sourceB: UInt16

                            if sourceCGImage.alphaInfo == .premultipliedFirst || sourceCGImage.alphaInfo == .first {
                                if sourceCGImage.byteOrderInfo == .order32Little {
                                    // BGRA
                                    sourceB = sourcePtr16[sourcePixelOffset + 0]
                                    sourceG = sourcePtr16[sourcePixelOffset + 1]
                                    sourceR = sourcePtr16[sourcePixelOffset + 2]
                                } else {
                                    // ARGB
                                    sourceR = sourcePtr16[sourcePixelOffset + 1]
                                    sourceG = sourcePtr16[sourcePixelOffset + 2]
                                    sourceB = sourcePtr16[sourcePixelOffset + 3]
                                }
                            } else {
                                // RGBA
                                sourceR = sourcePtr16[sourcePixelOffset + 0]
                                sourceG = sourcePtr16[sourcePixelOffset + 1]
                                sourceB = sourcePtr16[sourcePixelOffset + 2]
                            }

                            // Extract alpha from mask (last channel)
                            let maskAlpha = maskPtr16[maskPixelOffset + (maskBytesPerPixel / 2) - 1]

                            // Write RGBA to output
                            outputPtr16[outputPixelOffset + 0] = sourceR
                            outputPtr16[outputPixelOffset + 1] = sourceG
                            outputPtr16[outputPixelOffset + 2] = sourceB
                            outputPtr16[outputPixelOffset + 3] = maskAlpha
                        }
                    }
                } else {
                    // 8-bit processing (original code)
                    for y in 0..<expectedHeight {
                        for x in 0..<expectedWidth {
                            let sourceOffset = y * sourceBytesPerRow + x * sourceBytesPerPixel
                            let maskOffset = y * maskBytesPerRow + x * maskBytesPerPixel
                            let outputOffset = (y * expectedWidth + x) * 4

                            // Extract RGB from source (handle different pixel formats)
                            let sourceR: UInt8
                            let sourceG: UInt8
                            let sourceB: UInt8

                            if sourceCGImage.alphaInfo == .premultipliedFirst || sourceCGImage.alphaInfo == .first {
                                // ARGB or BGRA format
                                if sourceCGImage.byteOrderInfo == .order32Little {
                                    // BGRA
                                    sourceB = sourcePixels[sourceOffset + 0]
                                    sourceG = sourcePixels[sourceOffset + 1]
                                    sourceR = sourcePixels[sourceOffset + 2]
                                } else {
                                    // ARGB
                                    sourceR = sourcePixels[sourceOffset + 1]
                                    sourceG = sourcePixels[sourceOffset + 2]
                                    sourceB = sourcePixels[sourceOffset + 3]
                                }
                            } else {
                                // RGBA format
                                sourceR = sourcePixels[sourceOffset + 0]
                                sourceG = sourcePixels[sourceOffset + 1]
                                sourceB = sourcePixels[sourceOffset + 2]
                            }

                            // Extract alpha from mask (always last byte in RGBA)
                            let maskAlpha = maskPixels[maskOffset + maskBytesPerPixel - 1]

                            // Write RGBA to output
                            outputPixels[outputOffset + 0] = sourceR
                            outputPixels[outputOffset + 1] = sourceG
                            outputPixels[outputOffset + 2] = sourceB
                            outputPixels[outputOffset + 3] = maskAlpha
                        }
                    }
                }

                // Save as PNG
                guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                do {
                    try pngData.write(to: imageURL)
                } catch {
                    throw ExportError.failedToSaveImage(imageFilename)
                }

                var layerDict: [String: Any] = [
                    "image-name": imageFilename,
                    "name": "layer_\(imageIndex)",
                    "fill": "automatic",
                    "hidden": false
                ]

                // Add glass effect if specified
                if group.effects.hasGlass {
                    layerDict["glass"] = true
                }

                groupLayers.append(layerDict)
                imageIndex += 1
            }

            // Skip empty groups
            guard !groupLayers.isEmpty else { continue }

            let groupDict: [String: Any] = [
                "hidden": false,
                "layers": groupLayers,
                "shadow": [
                    "kind": "layer-color",
                    "opacity": Double(group.effects.shadowOpacity)
                ],
                "translucency": [
                    "enabled": true,
                    "value": Double(group.effects.translucencyValue)
                ],
                "lighting": group.effects.lighting == .individual ? "individual" : "combined",
                "specular": group.effects.hasSpecular
            ]

            groups.append(groupDict)
        }

        // Create icon.json
        let iconJSON: [String: Any] = [
            "fill": "automatic",
            "groups": groups,
            "supported-platforms": [
                "circles": ["watchOS"],
                "squares": "shared"
            ]
        ]

        // Write icon.json with proper formatting
        let iconJSONURL = bundleURL.appendingPathComponent("icon.json")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: iconJSONURL)
        } catch {
            throw ExportError.failedToWriteJSON
        }
    }
}
