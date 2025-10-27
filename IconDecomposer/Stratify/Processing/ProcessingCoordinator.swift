//
//  ProcessingCoordinator.swift
//  IconDecomposer
//
//  Coordinates icon processing using ImageColorSegmentation package
//

import Foundation
import AppKit
import Metal
import ImageColorSegmentation

/// Coordinates the processing of an icon into color-separated layers
class ProcessingCoordinator {

    /// Process an icon image and extract layers
    /// - Parameters:
    ///   - image: Source icon image
    ///   - parameters: Processing parameters
    /// - Returns: Array of extracted layers
    static func processIcon(_ image: NSImage, parameters: ProcessingParameters) async throws -> [Layer] {
        print("Starting icon processing...")
        print("  Parameters: \(parameters.numberOfClusters) clusters, compactness: \(parameters.compactness)")
        print("  Auto-merge threshold: \(parameters.autoMergeThreshold)")

        // Create processing pipeline
        let labScale = LABScale(
            l: parameters.lightnessWeight,
            a: 1.0,
            b: parameters.greenAxisScale
        )

        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: labScale)
            .segment(
                superpixels: parameters.numberOfSegments,
                compactness: parameters.compactness
            )
            .cluster(into: parameters.numberOfClusters)
            // Don't auto-merge - let user manually combine layers
            // .autoMerge(threshold: parameters.autoMergeThreshold)
            .extractLayers()

        // Execute pipeline
        let result = try await pipeline.execute(input: image)

        // Extract layers from result
        guard let clusterCount: Int = result.metadata(for: "clusterCount") else {
            throw ProcessingError.processingFailed("No cluster count in result")
        }

        print("Processing complete: \(clusterCount) layers extracted")

        let width = Int(image.size.width)
        let height = Int(image.size.height)

        var layers: [Layer] = []

        for i in 0..<clusterCount {
            guard let layerBuffer = result.buffer(named: "layer_\(i)") else {
                print("Warning: layer_\(i) buffer not found")
                continue
            }

            // Create NSImage from Metal buffer
            guard let layerImage = createLayerImage(from: layerBuffer, width: width, height: height) else {
                print("Warning: Failed to create image from layer_\(i) buffer")
                continue
            }

            // Calculate pixel count and average color
            let (pixelCount, avgColor) = analyzeLayer(layerBuffer, width: width, height: height)

            let layer = Layer(
                name: "Layer \(i + 1)",
                image: layerImage,
                pixelCount: pixelCount,
                averageColor: avgColor,
                isSelected: true
            )

            layers.append(layer)
        }

        // Sort by size (largest first)
        layers.sort { $0.pixelCount > $1.pixelCount }

        // Renumber after sorting
        for (index, layer) in layers.enumerated() {
            var updatedLayer = layer
            updatedLayer.name = "Layer \(index + 1)"
            layers[index] = updatedLayer
        }

        return layers
    }

    /// Create NSImage from Metal buffer containing BGRA8 data
    static func createLayerImage(from buffer: MTLBuffer, width: Int, height: Int) -> NSImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: buffer.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        guard let cgImage = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Analyze layer to get pixel count and average LAB color
    static func analyzeLayer(_ buffer: MTLBuffer, width: Int, height: Int) -> (pixelCount: Int, avgColor: SIMD3<Float>) {
        let bufferPointer = buffer.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)

        var pixelCount = 0
        var rSum: Float = 0
        var gSum: Float = 0
        var bSum: Float = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = bufferPointer[offset + 3]

                if alpha > 10 {  // Consider pixel if alpha > threshold
                    pixelCount += 1
                    // BGRA format
                    let b = Float(bufferPointer[offset + 0])
                    let g = Float(bufferPointer[offset + 1])
                    let r = Float(bufferPointer[offset + 2])

                    rSum += r
                    gSum += g
                    bSum += b
                }
            }
        }

        if pixelCount > 0 {
            let avgR = rSum / Float(pixelCount) / 255.0
            let avgG = gSum / Float(pixelCount) / 255.0
            let avgB = bSum / Float(pixelCount) / 255.0

            // Convert RGB to LAB (simplified - just store RGB for now)
            // TODO: Proper RGB to LAB conversion
            let labColor = SIMD3<Float>(avgR * 100, avgG * 100 - 50, avgB * 100 - 50)

            return (pixelCount, labColor)
        } else {
            return (0, SIMD3<Float>(50, 0, 0))
        }
    }
}

enum ProcessingError: Error, LocalizedError {
    case notImplemented
    case metalNotAvailable
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "This feature is not yet implemented"
        case .metalNotAvailable:
            return "Metal GPU acceleration is not available on this device"
        case .processingFailed(let message):
            return message
        }
    }
}
