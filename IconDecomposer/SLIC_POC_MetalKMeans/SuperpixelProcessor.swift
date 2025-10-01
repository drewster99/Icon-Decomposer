//
//  SuperpixelProcessor.swift
//  SLIC_ProofOfConcept
//
//  Bridge between SLIC output and K-means clustering input.
//  This class extracts superpixel features from SLIC Metal buffers
//  and prepares them for clustering algorithms.
//

import Foundation
import Metal
import simd

/// Parameters for superpixel extraction (matches Metal struct)
struct SuperpixelExtractionParams {
    let imageWidth: UInt32
    let imageHeight: UInt32
    let maxLabel: UInt32
}

/// Processes SLIC output to extract superpixel features for clustering
class SuperpixelProcessor {

    // Metal objects for GPU acceleration
    private static let device = MTLCreateSystemDefaultDevice()!
    private static let commandQueue = device.makeCommandQueue()!
    private static let library = device.makeDefaultLibrary()!

    // Lazy-loaded pipeline state
    private static var accumulateSuperpixelFeaturesPipeline: MTLComputePipelineState = {
        let function = library.makeFunction(name: "accumulateSuperpixelFeatures")!
        return try! device.makeComputePipelineState(function: function)
    }()

    /// Represents a superpixel with its average color and metadata
    struct Superpixel {
        let id: Int
        let labColor: SIMD3<Float>  // LAB color space
        let pixelCount: Int
        let centerPosition: SIMD2<Float>
    }

    /// Result containing processed superpixel data
    struct SuperpixelData {
        let superpixels: [Superpixel]
        let labelMap: [UInt32]  // Original pixel labels
        let imageWidth: Int
        let imageHeight: Int
        let uniqueLabels: Set<UInt32>
    }

    /// Extract superpixel features from SLIC output buffers
    /// - Parameters:
    ///   - labBuffer: Buffer containing LAB color values for each pixel
    ///   - labelsBuffer: Buffer containing superpixel label for each pixel
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Processed superpixel data ready for clustering
    static func extractSuperpixels(
        from labBuffer: MTLBuffer,
        labelsBuffer: MTLBuffer,
        width: Int,
        height: Int
    ) -> SuperpixelData {

        let pixelCount = width * height

        // Access buffer data
        let labPointer = labBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: pixelCount)
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: pixelCount)

        // Copy labels for later use
        var labelMap = Array<UInt32>(repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            labelMap[i] = labelsPointer[i]
        }

        // Find unique superpixel labels
        let uniqueLabels = Set(labelMap)

        // Accumulate color and position for each superpixel
        var colorAccumulators = [UInt32: SIMD3<Float>]()
        var positionAccumulators = [UInt32: SIMD2<Float>]()
        var pixelCounts = [UInt32: Int]()

        // Initialize accumulators
        for label in uniqueLabels {
            colorAccumulators[label] = SIMD3<Float>(0, 0, 0)
            positionAccumulators[label] = SIMD2<Float>(0, 0)
            pixelCounts[label] = 0
        }

        // Accumulate values for each superpixel
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let label = labelsPointer[idx]
                let labColor = labPointer[idx]

                colorAccumulators[label]! += labColor
                positionAccumulators[label]! += SIMD2<Float>(Float(x), Float(y))
                pixelCounts[label]! += 1
            }
        }

        // Calculate averages and create superpixel objects
        var superpixels: [Superpixel] = []

        for label in uniqueLabels.sorted() {
            let count = pixelCounts[label]!
            guard count > 0 else { continue }

            let avgColor = colorAccumulators[label]! / Float(count)
            let avgPosition = positionAccumulators[label]! / Float(count)

            let superpixel = Superpixel(
                id: Int(label),
                labColor: avgColor,
                pixelCount: count,
                centerPosition: avgPosition
            )
            superpixels.append(superpixel)
        }

        print("Extracted \(superpixels.count) superpixels from \(width)x\(height) image (CPU)")

        return SuperpixelData(
            superpixels: superpixels,
            labelMap: labelMap,
            imageWidth: width,
            imageHeight: height,
            uniqueLabels: uniqueLabels
        )
    }

    /// Extract superpixel features using Metal GPU acceleration
    /// - Parameters:
    ///   - labBuffer: Buffer containing LAB color values for each pixel
    ///   - labelsBuffer: Buffer containing superpixel label for each pixel
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Processed superpixel data ready for clustering
    static func extractSuperpixelsMetal(
        from labBuffer: MTLBuffer,
        labelsBuffer: MTLBuffer,
        width: Int,
        height: Int
    ) -> SuperpixelData {

        let pixelCount = width * height

        // First, find unique labels and max label (need to do on CPU)
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: pixelCount)
        var labelMap = Array<UInt32>(repeating: 0, count: pixelCount)
        var maxLabel: UInt32 = 0

        for i in 0..<pixelCount {
            let label = labelsPointer[i]
            labelMap[i] = label
            maxLabel = max(maxLabel, label)
        }

        let uniqueLabels = Set(labelMap)
        let numSuperpixels = Int(maxLabel) + 1  // Labels are 0-indexed

        // Create Metal buffers for accumulation
        // Use maxLabel+1 as array size to handle sparse labels
        let colorAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 3,
            options: .storageModeShared
        )!

        let positionAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 2,
            options: .storageModeShared
        )!

        let pixelCountsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numSuperpixels,
            options: .storageModeShared
        )!

        // Zero out the accumulator buffers
        memset(colorAccumulatorsBuffer.contents(), 0, colorAccumulatorsBuffer.length)
        memset(positionAccumulatorsBuffer.contents(), 0, positionAccumulatorsBuffer.length)
        memset(pixelCountsBuffer.contents(), 0, pixelCountsBuffer.length)

        // Create parameter struct
        var params = SuperpixelExtractionParams(
            imageWidth: UInt32(width),
            imageHeight: UInt32(height),
            maxLabel: maxLabel
        )

        // Dispatch Metal kernel
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(accumulateSuperpixelFeaturesPipeline)
        encoder.setBuffer(labBuffer, offset: 0, index: 0)
        encoder.setBuffer(labelsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorAccumulatorsBuffer, offset: 0, index: 2)
        encoder.setBuffer(positionAccumulatorsBuffer, offset: 0, index: 3)
        encoder.setBuffer(pixelCountsBuffer, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<SuperpixelExtractionParams>.size, index: 5)

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

        // Read back results and create Superpixel objects
        let colorAccumulators = colorAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 3)
        let positionAccumulators = positionAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 2)
        let pixelCounts = pixelCountsBuffer.contents().bindMemory(to: Int32.self, capacity: numSuperpixels)

        var superpixels: [Superpixel] = []

        for label in uniqueLabels.sorted() {
            let labelInt = Int(label)
            let count = Int(pixelCounts[labelInt])

            guard count > 0 else { continue }

            // Calculate averages
            let colorBaseIndex = labelInt * 3
            let avgColor = SIMD3<Float>(
                colorAccumulators[colorBaseIndex + 0] / Float(count),
                colorAccumulators[colorBaseIndex + 1] / Float(count),
                colorAccumulators[colorBaseIndex + 2] / Float(count)
            )

            let positionBaseIndex = labelInt * 2
            let avgPosition = SIMD2<Float>(
                positionAccumulators[positionBaseIndex + 0] / Float(count),
                positionAccumulators[positionBaseIndex + 1] / Float(count)
            )

            let superpixel = Superpixel(
                id: labelInt,
                labColor: avgColor,
                pixelCount: count,
                centerPosition: avgPosition
            )
            superpixels.append(superpixel)
        }

        print("Extracted \(superpixels.count) superpixels from \(width)x\(height) image (Metal GPU)")

        return SuperpixelData(
            superpixels: superpixels,
            labelMap: labelMap,
            imageWidth: width,
            imageHeight: height,
            uniqueLabels: uniqueLabels
        )
    }

    /// Create LAB color array suitable for K-means clustering
    /// - Parameter superpixelData: Processed superpixel data
    /// - Returns: Array of LAB colors as SIMD3<Float>
    static func extractColorFeatures(from superpixelData: SuperpixelData) -> [SIMD3<Float>] {
        return superpixelData.superpixels.map { $0.labColor }
    }

    /// Create weighted LAB colors with reduced lightness influence
    /// - Parameters:
    ///   - superpixelData: Processed superpixel data
    ///   - lightnessWeight: Weight for L channel (default 0.65 like Python)
    /// - Returns: Array of weighted LAB colors
    static func extractWeightedColorFeatures(
        from superpixelData: SuperpixelData,
        lightnessWeight: Float = 0.65
    ) -> [SIMD3<Float>] {
        return superpixelData.superpixels.map { superpixel in
            SIMD3<Float>(
                superpixel.labColor.x * lightnessWeight,  // L channel
                superpixel.labColor.y,                     // a channel
                superpixel.labColor.z                      // b channel
            )
        }
    }

    /// Map cluster assignments back to pixel labels
    /// - Parameters:
    ///   - clusterAssignments: Cluster ID for each superpixel
    ///   - superpixelData: Original superpixel data
    /// - Returns: Array of cluster IDs for each pixel
    static func mapClustersToPixels(
        clusterAssignments: [Int],
        superpixelData: SuperpixelData
    ) -> [UInt32] {

        // Create mapping from superpixel ID to cluster ID
        var superpixelToCluster = [UInt32: UInt32]()
        for (index, superpixel) in superpixelData.superpixels.enumerated() {
            let clusterAssignment = clusterAssignments[index]
            // Handle unassigned clusters (-1) by defaulting to 0
            let clusterId = clusterAssignment >= 0 ? UInt32(clusterAssignment) : 0
            superpixelToCluster[UInt32(superpixel.id)] = clusterId
        }

        // Map each pixel's superpixel label to cluster ID
        var pixelClusters = Array<UInt32>(repeating: 0, count: superpixelData.labelMap.count)
        for i in 0..<superpixelData.labelMap.count {
            let superpixelLabel = superpixelData.labelMap[i]
            pixelClusters[i] = superpixelToCluster[superpixelLabel] ?? 0
        }

        return pixelClusters
    }
}