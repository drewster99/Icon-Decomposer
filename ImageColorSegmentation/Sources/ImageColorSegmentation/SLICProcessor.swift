//
//  SLICProcessor.swift
//  ImageColorSegmentation
//
//  Metal-accelerated SLIC superpixel segmentation
//

import Foundation
import Metal
import MetalKit
import CoreGraphics

/// Handles SLIC superpixel segmentation using Metal shaders
public class SLICProcessor {

    private let device: MTLDevice
    private let library: MTLLibrary

    // Pipeline states
    private var gaussianBlurPipeline: MTLComputePipelineState
    private var rgbToLabPipeline: MTLComputePipelineState
    private var initializeCentersPipeline: MTLComputePipelineState
    private var assignPixelsPipeline: MTLComputePipelineState
    private var updateCentersPipeline: MTLComputePipelineState
    private var finalizeCentersPipeline: MTLComputePipelineState
    private var clearAccumulatorsPipeline: MTLComputePipelineState
    private var clearDistancesPipeline: MTLComputePipelineState
    private var enforceConnectivityPipeline: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        self.library = library

        // Create pipeline states
        self.gaussianBlurPipeline = try Self.createPipelineState(library: library, device: device, functionName: "gaussianBlur")
        self.rgbToLabPipeline = try Self.createPipelineState(library: library, device: device, functionName: "rgbToLab")
        self.initializeCentersPipeline = try Self.createPipelineState(library: library, device: device, functionName: "initializeCenters")
        self.assignPixelsPipeline = try Self.createPipelineState(library: library, device: device, functionName: "assignPixels")
        self.updateCentersPipeline = try Self.createPipelineState(library: library, device: device, functionName: "updateCenters")
        self.finalizeCentersPipeline = try Self.createPipelineState(library: library, device: device, functionName: "finalizeCenters")
        self.clearAccumulatorsPipeline = try Self.createPipelineState(library: library, device: device, functionName: "clearAccumulators")
        self.clearDistancesPipeline = try Self.createPipelineState(library: library, device: device, functionName: "clearDistances")
        self.enforceConnectivityPipeline = try Self.createPipelineState(library: library, device: device, functionName: "enforceConnectivity")
    }

    private static func createPipelineState(library: MTLLibrary, device: MTLDevice, functionName: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw PipelineError.executionFailed("Failed to find Metal function: \(functionName)")
        }
        return try device.makeComputePipelineState(function: function)
    }

    /// Process SLIC segmentation within the pipeline
    public func processSLIC(
        inputTexture: MTLTexture,
        commandQueue: MTLCommandQueue,
        nSegments: Int,
        compactness: Float,
        greenAxisScale: Float,
        iterations: Int = 10,
        enforceConnectivity: Bool = true
    ) throws -> (labBuffer: MTLBuffer, labelsBuffer: MTLBuffer, alphaBuffer: MTLBuffer, numCenters: Int) {

        let width = inputTexture.width
        let height = inputTexture.height

        // Create our own command buffer that we'll commit and wait on
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineError.executionFailed("Failed to create command buffer for SLIC")
        }

        // Calculate grid parameters
        let gridSpacing = Int(sqrt(Double(width * height) / Double(nSegments)))
        let searchRegion = 2 * gridSpacing
        let gridWidth = (width + gridSpacing - 1) / gridSpacing
        let gridHeight = (height + gridSpacing - 1) / gridSpacing
        let numCenters = gridWidth * gridHeight

        // Spatial weight for distance calculation
        let spatialWeight = compactness / Float(gridSpacing)

        // Create textures
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let blurredTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw PipelineError.executionFailed("Failed to create blurred texture")
        }

        // Create buffers
        let labBufferSize = width * height * MemoryLayout<SIMD3<Float>>.size
        guard let labBuffer = device.makeBuffer(length: labBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create LAB buffer")
        }

        let alphaBufferSize = width * height * MemoryLayout<Float>.size
        guard let alphaBuffer = device.makeBuffer(length: alphaBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create alpha buffer")
        }

        let centersBufferSize = numCenters * MemoryLayout<ClusterCenter>.size
        guard let centersBuffer = device.makeBuffer(length: centersBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create centers buffer")
        }

        let labelsBufferSize = width * height * MemoryLayout<UInt32>.size
        guard let labelsBuffer = device.makeBuffer(length: labelsBufferSize, options: .storageModeShared),
              let labelsBufferCopy = device.makeBuffer(length: labelsBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create labels buffers")
        }

        let distancesBufferSize = width * height * MemoryLayout<Float>.size
        guard let distancesBuffer = device.makeBuffer(length: distancesBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create distances buffer")
        }

        let accumulatorSize = numCenters * MemoryLayout<CenterAccumulator>.size
        guard let accumulatorBuffer = device.makeBuffer(length: accumulatorSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create accumulator buffer")
        }

        // Create params buffer
        var params = SLICParams(
            imageWidth: UInt32(width),
            imageHeight: UInt32(height),
            gridSpacing: UInt32(gridSpacing),
            searchRegion: UInt32(searchRegion),
            compactness: compactness,
            spatialWeight: spatialWeight,
            numCenters: UInt32(numCenters),
            iteration: 0
        )

        guard let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<SLICParams>.size, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create params buffer")
        }

        // Step 1: Gaussian Blur
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(gaussianBlurPipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(blurredTexture, index: 1)

            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        // Step 2: RGB to LAB conversion
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(rgbToLabPipeline)
            encoder.setTexture(blurredTexture, index: 0)
            encoder.setBuffer(labBuffer, offset: 0, index: 0)
            encoder.setBuffer(alphaBuffer, offset: 0, index: 1)

            var greenScale = greenAxisScale
            encoder.setBytes(&greenScale, length: MemoryLayout<Float>.size, index: 2)

            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        // Step 3: Initialize centers
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(initializeCentersPipeline)
            encoder.setBuffer(labBuffer, offset: 0, index: 0)
            encoder.setBuffer(centersBuffer, offset: 0, index: 1)
            encoder.setBuffer(paramsBuffer, offset: 0, index: 2)

            let threadsPerGrid = MTLSize(width: numCenters, height: 1, depth: 1)
            let threadsPerThreadgroup = MTLSize(width: min(numCenters, 256), height: 1, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        // Step 4: Iterative assignment and update
        for _ in 0..<iterations {
            // Clear distances
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(clearDistancesPipeline)
                encoder.setBuffer(distancesBuffer, offset: 0, index: 0)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

                let threadsPerGrid = MTLSize(width: width * height, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Assign pixels
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(assignPixelsPipeline)
                encoder.setBuffer(labBuffer, offset: 0, index: 0)
                encoder.setBuffer(centersBuffer, offset: 0, index: 1)
                encoder.setBuffer(labelsBuffer, offset: 0, index: 2)
                encoder.setBuffer(distancesBuffer, offset: 0, index: 3)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 4)
                encoder.setBuffer(alphaBuffer, offset: 0, index: 5)

                let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Clear accumulators
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(clearAccumulatorsPipeline)
                encoder.setBuffer(accumulatorBuffer, offset: 0, index: 0)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

                let threadsPerGrid = MTLSize(width: numCenters, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: min(numCenters, 256), height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Update centers (accumulate)
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(updateCentersPipeline)
                encoder.setBuffer(labBuffer, offset: 0, index: 0)
                encoder.setBuffer(labelsBuffer, offset: 0, index: 1)
                encoder.setBuffer(centersBuffer, offset: 0, index: 2)
                encoder.setBuffer(accumulatorBuffer, offset: 0, index: 3)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 4)

                let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Finalize centers
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(finalizeCentersPipeline)
                encoder.setBuffer(accumulatorBuffer, offset: 0, index: 0)
                encoder.setBuffer(centersBuffer, offset: 0, index: 1)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 2)

                let threadsPerGrid = MTLSize(width: numCenters, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: min(numCenters, 256), height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }
        }

        // Step 5: Enforce connectivity (if enabled)
        if enforceConnectivity {
            let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
            let labelsCopyPointer = labelsBufferCopy.contents().bindMemory(to: UInt32.self, capacity: width * height)
            memcpy(labelsCopyPointer, labelsPointer, labelsBufferSize)

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(enforceConnectivityPipeline)
                encoder.setBuffer(labelsBuffer, offset: 0, index: 0)
                encoder.setBuffer(labelsBufferCopy, offset: 0, index: 1)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 2)

                let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }
        }

        // Commit and wait for all GPU work to complete
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return (labBuffer: labBuffer, labelsBuffer: labelsBuffer, alphaBuffer: alphaBuffer, numCenters: numCenters)
    }
}

// Structure definitions to match Metal shader
struct SLICParams {
    let imageWidth: UInt32
    let imageHeight: UInt32
    let gridSpacing: UInt32
    let searchRegion: UInt32
    let compactness: Float
    let spatialWeight: Float
    let numCenters: UInt32
    let iteration: UInt32
}

struct ClusterCenter {
    var x: Float
    var y: Float
    var L: Float
    var a: Float
    var b: Float
}

struct CenterAccumulator {
    var sumX: Float
    var sumY: Float
    var sumL: Float
    var sumA: Float
    var sumB: Float
    var count: UInt32
}
