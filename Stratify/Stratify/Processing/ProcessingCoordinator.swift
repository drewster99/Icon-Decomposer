//
//  ProcessingCoordinator.swift
//  Stratify
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
    ///   - depthMap: Optional depth map for depth-aware segmentation
    /// - Returns: Array of extracted layers
    static func processIcon(_ image: NSImage, parameters: ProcessingParameters, depthMap: NSImage? = nil) async throws -> [Layer] {
        print("Starting icon processing...")
        print("  Parameters: \(parameters.numberOfClusters) clusters, compactness: \(parameters.compactness)")
        print("  Auto-merge threshold: \(parameters.autoMergeThreshold)")
        if parameters.depthWeightSLIC > 0 {
            print("  Depth weight: \(parameters.depthWeightSLIC) (depth map: \(depthMap != nil ? "provided" : "not provided"))")
        }

        // Create processing pipeline
        let adjustments = LABColorAdjustments(
            lightnessScale: parameters.lightnessWeight,
            greenAxisScale: parameters.greenAxisScale
        )

        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab, adjustments: adjustments)
            .segment(
                superpixels: parameters.numberOfSegments,
                compactness: parameters.compactness,
                depthWeight: parameters.depthWeightSLIC
            )
            .graphCluster(into: parameters.numberOfClusters)  // Use graph-based RAG clustering instead of K-means
            // Don't auto-merge - let user manually combine layers via "Auto-Merge Layers" button
            // .autoMerge(threshold: parameters.autoMergeThreshold, strategy: .iterativeWeighted())
            .extractLayers()

        // Execute pipeline with depth map if provided (regardless of weight)
        // When depthWeight == 0, depth values are read but have no effect (multiplied by zero)
        let result: PipelineExecution
        if let depthMap = depthMap {
            result = try await pipeline.execute(input: image, depthMap: depthMap)
        } else {
            result = try await pipeline.execute(input: image)
        }

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

            // Create CGImage from Metal buffer
            guard let layerCGImage = createLayerCGImage(from: layerBuffer, width: width, height: height) else {
                print("Warning: Failed to create image from layer_\(i) buffer")
                continue
            }

            // Diagnostic: Log layer dimensions and bit depth
            print("📐 Created layer \(i): \(layerCGImage.width)×\(layerCGImage.height)px, \(layerCGImage.bitsPerComponent)-bit")

            // Calculate pixel count and average color
            let (pixelCount, avgColor) = analyzeLayer(layerBuffer, width: width, height: height)

            let layer = Layer(
                name: "Layer \(i + 1)",
                cgImage: layerCGImage,
                pixelCount: pixelCount,
                averageColor: avgColor
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

    /// Create CGImage from Metal buffer containing BGRA8 data
    static func createLayerCGImage(from buffer: MTLBuffer, width: Int, height: Int) -> CGImage? {
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

        return context.makeImage()
    }

    /// Convert sRGB (0-1 range) to CIE LAB color space
    nonisolated static func rgbToLab(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        // Convert sRGB to linear RGB
        func srgbToLinear(_ c: Float) -> Float {
            if c <= 0.04045 {
                return c / 12.92
            } else {
                return pow((c + 0.055) / 1.055, 2.4)
            }
        }

        let rLin = srgbToLinear(r)
        let gLin = srgbToLinear(g)
        let bLin = srgbToLinear(b)

        // Convert linear RGB to XYZ (D65 illuminant)
        let x = rLin * 0.4124564 + gLin * 0.3575761 + bLin * 0.1804375
        let y = rLin * 0.2126729 + gLin * 0.7151522 + bLin * 0.0721750
        let z = rLin * 0.0193339 + gLin * 0.1191920 + bLin * 0.9503041

        // Normalize by D65 white point
        let xn = x / 0.95047
        let yn = y / 1.00000
        let zn = z / 1.08883

        // Convert to LAB
        func f(_ t: Float) -> Float {
            let delta: Float = 6.0 / 29.0
            if t > pow(delta, 3) {
                return pow(t, 1.0/3.0)
            } else {
                return t / (3.0 * delta * delta) + 4.0 / 29.0
            }
        }

        let fx = f(xn)
        let fy = f(yn)
        let fz = f(zn)

        let l = 116.0 * fy - 16.0
        let a = 500.0 * (fx - fy)
        let b_lab = 200.0 * (fy - fz)

        return SIMD3<Float>(l, a, b_lab)
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

            let labColor = rgbToLab(avgR, avgG, avgB)

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
