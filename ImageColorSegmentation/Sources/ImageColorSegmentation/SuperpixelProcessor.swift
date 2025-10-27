//
//  SuperpixelProcessor.swift
//  ImageColorSegmentation
//
//  Extracts superpixel features from SLIC output using Metal acceleration
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
public class SuperpixelProcessor {

    private let device: MTLDevice
    private let library: MTLLibrary
    private let commandQueue: MTLCommandQueue

    // Pipeline states
    private var accumulateSuperpixelFeaturesPipeline: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.library = library
        self.commandQueue = commandQueue

        guard let function = library.makeFunction(name: "accumulateSuperpixelFeatures") else {
            throw PipelineError.executionFailed("Failed to find Metal function: accumulateSuperpixelFeatures")
        }
        self.accumulateSuperpixelFeaturesPipeline = try device.makeComputePipelineState(function: function)
    }

    /// Represents a superpixel with its average color and metadata
    public struct Superpixel {
        public let id: Int
        public let labColor: SIMD3<Float>
        public let pixelCount: Int
        public let centerPosition: SIMD2<Float>
    }

    /// Result containing processed superpixel data
    public struct SuperpixelData {
        public let superpixels: [Superpixel]
        public let numSuperpixels: Int
    }

    /// Extract superpixel features using Metal GPU acceleration
    public func extractSuperpixelsMetal(
        from labBuffer: MTLBuffer,
        labelsBuffer: MTLBuffer,
        width: Int,
        height: Int
    ) throws -> SuperpixelData {

        let pixelCount = width * height

        // Find max label (CPU scan)
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: pixelCount)
        let transparentLabel: UInt32 = 0xFFFFFFFE
        var maxLabel: UInt32 = 0
        for i in 0..<pixelCount {
            let label = labelsPointer[i]
            if label != transparentLabel {
                maxLabel = max(maxLabel, label)
            }
        }
        let numSuperpixels = Int(maxLabel) + 1

        // Create Metal buffers for accumulation
        guard let colorAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 3,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create color accumulators buffer")
        }

        guard let positionAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 2,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create position accumulators buffer")
        }

        guard let pixelCountsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numSuperpixels,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create pixel counts buffer")
        }

        // Zero out buffers
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
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(accumulateSuperpixelFeaturesPipeline)
        encoder.setBuffer(labBuffer, offset: 0, index: 0)
        encoder.setBuffer(labelsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorAccumulatorsBuffer, offset: 0, index: 2)
        encoder.setBuffer(positionAccumulatorsBuffer, offset: 0, index: 3)
        encoder.setBuffer(pixelCountsBuffer, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<SuperpixelExtractionParams>.size, index: 5)

        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let groupsPerGrid = MTLSize(
            width: (pixelCount + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(groupsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back results and create Superpixel objects
        let colorAccumulators = colorAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 3)
        let positionAccumulators = positionAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 2)
        let pixelCounts = pixelCountsBuffer.contents().bindMemory(to: Int32.self, capacity: numSuperpixels)

        var superpixels: [Superpixel] = []

        for labelInt in 0..<numSuperpixels {
            let count = Int(pixelCounts[labelInt])
            guard count > 0 else { continue }

            // Skip transparent pixels
            if UInt32(labelInt) == transparentLabel {
                continue
            }

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

        return SuperpixelData(
            superpixels: superpixels,
            numSuperpixels: superpixels.count
        )
    }

    /// Extract LAB color features from superpixel data
    public static func extractColorFeatures(from superpixelData: SuperpixelData) -> [SIMD3<Float>] {
        return superpixelData.superpixels.map { $0.labColor }
    }

    /// Extract spatial features (normalized XY positions) from superpixel data
    /// - Parameters:
    ///   - superpixelData: Superpixel data with center positions
    ///   - imageWidth: Image width for normalization
    ///   - imageHeight: Image height for normalization
    /// - Returns: Array of normalized (x, y) positions scaled to 0-100 range
    public static func extractSpatialFeatures(
        from superpixelData: SuperpixelData,
        imageWidth: Int,
        imageHeight: Int
    ) -> [SIMD2<Float>] {
        return superpixelData.superpixels.map { superpixel in
            // Normalize to 0-100 range to match LAB scale
            let normalizedX = (superpixel.centerPosition.x / Float(imageWidth)) * 100.0
            let normalizedY = (superpixel.centerPosition.y / Float(imageHeight)) * 100.0
            return SIMD2<Float>(normalizedX, normalizedY)
        }
    }
}
