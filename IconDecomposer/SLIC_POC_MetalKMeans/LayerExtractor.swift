//
//  LayerExtractor.swift
//  SLIC_ProofOfConcept
//
//  Extracts individual layers from K-means clustering results
//

import Foundation
import CoreGraphics
import AppKit
import Metal

class LayerExtractor {

    // Metal objects for GPU acceleration
    private static let device = MTLCreateSystemDefaultDevice()!
    private static let commandQueue = device.makeCommandQueue()!
    private static let library = device.makeDefaultLibrary()!

    // Lazy-loaded pipeline state
    private static var extractLayerPipeline: MTLComputePipelineState = {
        let function = library.makeFunction(name: "extractLayer")!
        return try! device.makeComputePipelineState(function: function)
    }()

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

        // Debug output
        print("\nLayerExtractor: Processing clusters")
        print("  Cluster centers provided: \(clusterCenters.count)")
        print("  Unique clusters in pixel data: \(clusterPixelCounts.count)")
        print("  Cluster IDs found: \(clusterPixelCounts.keys.sorted())")
        print("  Pixel counts per cluster:")
        for (clusterId, count) in clusterPixelCounts.sorted(by: { $0.key < $1.key }) {
            let percentage = Double(count) / Double(width * height) * 100.0
            print(String(format: "    Cluster %d: %d pixels (%.2f%%)", clusterId, count, percentage))
        }

        // Sort clusters by size (largest first)
        let sortedClusters = clusterPixelCounts.sorted { $0.value > $1.value }

        var layers: [Layer] = []

        for (clusterId, pixelCount) in sortedClusters {
            #if DEBUG
            let layerStart = CFAbsoluteTimeGetCurrent()
            #endif

            // Create mask and layer image for this cluster
            var maskData = Data(count: width * height)
            var layerData = Data(count: width * height * 4)

            #if DEBUG
            let allocTime = CFAbsoluteTimeGetCurrent() - layerStart
            let loopStart = CFAbsoluteTimeGetCurrent()
            #endif

            // GPU-accelerated layer extraction
            extractLayerGPU(
                originalData: originalData,
                pixelClusters: pixelClusters,
                targetCluster: UInt32(clusterId),
                maskData: &maskData,
                layerData: &layerData,
                width: width,
                height: height
            )

            #if DEBUG
            let loopTime = CFAbsoluteTimeGetCurrent() - loopStart
            #endif

            // Create NSImage from layer data
            #if DEBUG
            let imageStart = CFAbsoluteTimeGetCurrent()
            #endif

            guard let layerImage = createNSImage(from: layerData, width: width, height: height) else {
                print("Failed to create NSImage for cluster \(clusterId)")
                continue
            }

            #if DEBUG
            let imageTime = CFAbsoluteTimeGetCurrent() - imageStart
            let totalLayerTime = CFAbsoluteTimeGetCurrent() - layerStart
            print(String(format: "  Cluster %d layer: alloc=%.2fms, loop=%.2fms, image=%.2fms, total=%.2fms",
                         clusterId, allocTime * 1000, loopTime * 1000, imageTime * 1000, totalLayerTime * 1000))
            #endif

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

    /// GPU-accelerated layer extraction using Metal
    private static func extractLayerGPU(
        originalData: UnsafeMutableRawPointer,
        pixelClusters: [UInt32],
        targetCluster: UInt32,
        maskData: inout Data,
        layerData: inout Data,
        width: Int,
        height: Int
    ) {
        let pixelCount = width * height

        // Create Metal buffers
        guard let originalBuffer = device.makeBuffer(
            bytes: originalData,
            length: pixelCount * 4,
            options: .storageModeShared
        ) else {
            print("Failed to create original buffer")
            return
        }

        guard let clustersBuffer = device.makeBuffer(
            bytes: pixelClusters,
            length: pixelCount * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else {
            print("Failed to create clusters buffer")
            return
        }

        guard let layerBuffer = device.makeBuffer(
            length: pixelCount * 4,
            options: .storageModeShared
        ) else {
            print("Failed to create layer buffer")
            return
        }

        guard let maskBuffer = device.makeBuffer(
            length: pixelCount,
            options: .storageModeShared
        ) else {
            print("Failed to create mask buffer")
            return
        }

        // Dispatch Metal kernel
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(extractLayerPipeline)
        encoder.setBuffer(originalBuffer, offset: 0, index: 0)
        encoder.setBuffer(clustersBuffer, offset: 0, index: 1)
        encoder.setBuffer(layerBuffer, offset: 0, index: 2)
        encoder.setBuffer(maskBuffer, offset: 0, index: 3)
        var target = targetCluster
        encoder.setBytes(&target, length: MemoryLayout<UInt32>.size, index: 4)
        var total = UInt32(pixelCount)
        encoder.setBytes(&total, length: MemoryLayout<UInt32>.size, index: 5)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (pixelCount + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Copy results back to Data
        maskData.withUnsafeMutableBytes { maskBytes in
            let maskPtr = maskBytes.bindMemory(to: UInt8.self)
            let bufferMask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount)
            memcpy(maskPtr.baseAddress!, bufferMask, pixelCount)
        }

        layerData.withUnsafeMutableBytes { layerBytes in
            let layerPtr = layerBytes.bindMemory(to: UInt8.self)
            let bufferLayer = layerBuffer.contents().bindMemory(to: UInt8.self, capacity: pixelCount * 4)
            memcpy(layerPtr.baseAddress!, bufferLayer, pixelCount * 4)
        }
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