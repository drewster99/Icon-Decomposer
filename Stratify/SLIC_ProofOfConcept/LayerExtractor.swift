//
//  LayerExtractor.swift
//  SLIC_ProofOfConcept
//
//  Extracts individual layers from K-means clustering results
//

import Foundation
import CoreGraphics
import AppKit

class LayerExtractor {

    /// Result containing an individual layer
    struct Layer {
        let image: NSImage
        let mask: Data  // Binary mask data
        let clusterId: Int
        let pixelCount: Int
        let averageColor: SIMD3<Float>  // LAB color
    }

    /// Extract layers from clustering results
    /// - Parameters:
    ///   - originalImage: The original input image
    ///   - pixelClusters: Cluster assignment for each pixel
    ///   - clusterCenters: LAB color centers for each cluster
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Array of extracted layers sorted by size (largest first)
    static func extractLayers(
        from originalImage: NSImage,
        pixelClusters: [UInt32],
        clusterCenters: [SIMD3<Float>],
        width: Int,
        height: Int
    ) -> [Layer] {

        // Get CGImage from NSImage
        guard let cgImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage from NSImage")
            return []
        }

        // Get pixel data from original image
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let originalData = UnsafeMutableRawPointer.allocate(byteCount: height * bytesPerRow, alignment: 1)
        defer { originalData.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: originalData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            print("Failed to create CGContext for reading original image")
            return []
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Find unique cluster IDs and count pixels
        var clusterPixelCounts: [Int: Int] = [:]
        for clusterId in pixelClusters {
            let id = Int(clusterId)
            clusterPixelCounts[id, default: 0] += 1
        }

        // Sort clusters by size (largest first)
        let sortedClusters = clusterPixelCounts.sorted { $0.value > $1.value }

        var layers: [Layer] = []

        for (clusterId, pixelCount) in sortedClusters {
            // Create mask and layer image for this cluster
            var maskData = Data(count: width * height)
            var layerData = Data(count: width * height * 4)

            maskData.withUnsafeMutableBytes { maskBytes in
                layerData.withUnsafeMutableBytes { layerBytes in
                    let mask = maskBytes.bindMemory(to: UInt8.self)
                    let layer = layerBytes.bindMemory(to: UInt8.self)
                    let original = originalData.bindMemory(to: UInt8.self, capacity: width * height * 4)

                    for y in 0..<height {
                        for x in 0..<width {
                            let idx = y * width + x
                            let pixelCluster = Int(pixelClusters[idx])

                            if pixelCluster == clusterId {
                                // Set mask to 255 (fully opaque)
                                mask[idx] = 255

                                // Copy original pixel with full alpha
                                let srcOffset = idx * 4
                                let dstOffset = idx * 4

                                layer[dstOffset + 0] = original[srcOffset + 0]  // B
                                layer[dstOffset + 1] = original[srcOffset + 1]  // G
                                layer[dstOffset + 2] = original[srcOffset + 2]  // R
                                layer[dstOffset + 3] = original[srcOffset + 3]  // A (preserve original alpha)
                            } else {
                                // Set mask to 0 (fully transparent)
                                mask[idx] = 0

                                // Make pixel transparent
                                let dstOffset = idx * 4
                                layer[dstOffset + 0] = 0  // B
                                layer[dstOffset + 1] = 0  // G
                                layer[dstOffset + 2] = 0  // R
                                layer[dstOffset + 3] = 0  // A
                            }
                        }
                    }
                }
            }

            // Create NSImage from layer data
            guard let layerImage = createNSImage(from: layerData, width: width, height: height) else {
                print("Failed to create NSImage for cluster \(clusterId)")
                continue
            }

            // Get average color for this cluster
            let averageColor = clusterId < clusterCenters.count ?
                clusterCenters[clusterId] : SIMD3<Float>(0, 0, 0)

            let layer = Layer(
                image: layerImage,
                mask: maskData,
                clusterId: clusterId,
                pixelCount: pixelCount,
                averageColor: averageColor
            )

            layers.append(layer)
        }

        print("Extracted \(layers.count) layers from \(clusterPixelCounts.count) clusters")
        return layers
    }

    /// Create NSImage from pixel data
    private static func createNSImage(from pixelData: Data, width: Int, height: Int) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let dataProvider = CGDataProvider(data: pixelData as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Apply soft edges to layer mask (anti-aliasing)
    static func applySoftEdges(to maskData: inout Data, width: Int, height: Int, blurRadius: Float = 0.8) {
        // Simple box blur implementation for soft edges
        // In a production app, you might want to use Accelerate framework for this

        var tempMask = Data(count: maskData.count)
        tempMask.withUnsafeMutableBytes { tempBytes in
            maskData.withUnsafeBytes { srcBytes in
                let temp = tempBytes.bindMemory(to: UInt8.self)
                let src = srcBytes.bindMemory(to: UInt8.self)

                let radius = Int(blurRadius)

                for y in 0..<height {
                    for x in 0..<width {
                        var sum = 0
                        var count = 0

                        for dy in -radius...radius {
                            for dx in -radius...radius {
                                let nx = x + dx
                                let ny = y + dy

                                if nx >= 0 && nx < width && ny >= 0 && ny < height {
                                    let idx = ny * width + nx
                                    sum += Int(src[idx])
                                    count += 1
                                }
                            }
                        }

                        let idx = y * width + x
                        temp[idx] = UInt8(sum / count)
                    }
                }
            }
        }

        maskData = tempMask
    }
}