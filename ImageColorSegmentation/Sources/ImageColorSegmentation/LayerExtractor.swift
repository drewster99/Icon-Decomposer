//
//  LayerExtractor.swift
//  ImageColorSegmentation
//
//  Extracts individual layers from K-means clustering results using Metal
//

import Foundation
import CoreGraphics
import Metal

public class LayerExtractor {

    private let device: MTLDevice
    private let library: MTLLibrary
    private let commandQueue: MTLCommandQueue

    // Pipeline state
    private var extractLayerPipeline: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.library = library
        self.commandQueue = commandQueue

        guard let function = library.makeFunction(name: "extractLayer") else {
            throw PipelineError.executionFailed("Failed to find Metal function: extractLayer")
        }
        self.extractLayerPipeline = try device.makeComputePipelineState(function: function)
    }

    /// Extract layers from clustering results using GPU acceleration
    public func extractLayersGPU(
        originalImageBuffer: MTLBuffer,
        pixelClusters: [UInt32],
        numberOfClusters: Int,
        width: Int,
        height: Int
    ) throws -> [MTLBuffer] {

        let pixelCount = width * height

        // Create clusters buffer
        guard let clustersBuffer = device.makeBuffer(
            bytes: pixelClusters,
            length: pixelCount * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create clusters buffer")
        }

        var layerBuffers: [MTLBuffer] = []

        for clusterId in 0..<numberOfClusters {
            // Create layer and mask buffers
            guard let layerBuffer = device.makeBuffer(
                length: pixelCount * 4,
                options: .storageModeShared
            ),
            let maskBuffer = device.makeBuffer(
                length: pixelCount,
                options: .storageModeShared
            ) else {
                throw PipelineError.executionFailed("Failed to create layer/mask buffers")
            }

            // Dispatch Metal kernel
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw PipelineError.executionFailed("Failed to create command buffer/encoder")
            }

            encoder.setComputePipelineState(extractLayerPipeline)
            encoder.setBuffer(originalImageBuffer, offset: 0, index: 0)
            encoder.setBuffer(clustersBuffer, offset: 0, index: 1)
            encoder.setBuffer(layerBuffer, offset: 0, index: 2)
            encoder.setBuffer(maskBuffer, offset: 0, index: 3)
            var target = UInt32(clusterId)
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

            layerBuffers.append(layerBuffer)
        }

        return layerBuffers
    }

    /// Map cluster assignments to pixels
    public static func mapClustersToPixels(
        clusterAssignments: [Int32],
        superpixelData: SuperpixelProcessor.SuperpixelData,
        labelMap: [UInt32]
    ) -> [UInt32] {

        // Create mapping from superpixel ID to cluster ID
        var superpixelToCluster = [UInt32: UInt32]()
        for (index, superpixel) in superpixelData.superpixels.enumerated() {
            let clusterAssignment = clusterAssignments[index]
            let clusterId = clusterAssignment >= 0 ? UInt32(clusterAssignment) : 0
            superpixelToCluster[UInt32(superpixel.id)] = clusterId
        }

        // Map each pixel's superpixel label to cluster ID
        var pixelClusters = Array<UInt32>(repeating: 0, count: labelMap.count)
        for i in 0..<labelMap.count {
            let superpixelLabel = labelMap[i]
            pixelClusters[i] = superpixelToCluster[superpixelLabel] ?? 0
        }

        return pixelClusters
    }
}
