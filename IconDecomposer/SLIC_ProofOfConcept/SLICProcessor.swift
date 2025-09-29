//
//  SLICProcessor.swift
//  SLIC_ProofOfConcept
//
//  Swift class for SLIC superpixel segmentation using Metal
//

import Foundation
import Metal
import MetalKit
import CoreGraphics
import AppKit

class SLICProcessor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Pipeline states
    private var copyTexturePipeline: MTLComputePipelineState!
    private var gaussianBlurPipeline: MTLComputePipelineState!
    private var rgbToLabPipeline: MTLComputePipelineState!
    private var initializeCentersPipeline: MTLComputePipelineState!
    private var assignPixelsPipeline: MTLComputePipelineState!
    private var updateCentersPipeline: MTLComputePipelineState!
    private var finalizeCentersPipeline: MTLComputePipelineState!
    private var clearAccumulatorsPipeline: MTLComputePipelineState!
    private var clearDistancesPipeline: MTLComputePipelineState!
    private var enforceConnectivityPipeline: MTLComputePipelineState!
    private var drawBoundariesPipeline: MTLComputePipelineState!

    // Parameters
    struct Parameters {
        let nSegments: Int
        let compactness: Float
        let iterations: Int
        let enforceConnectivity: Bool
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return nil
        }

        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            print("Failed to create command queue")
            return nil
        }

        self.commandQueue = commandQueue

        // Load the shader library
        guard let library = device.makeDefaultLibrary() else {
            print("Failed to create default library")
            return nil
        }

        self.library = library

        // Create pipeline states
        do {
            copyTexturePipeline = try createPipelineState(functionName: "copyTexture")
            gaussianBlurPipeline = try createPipelineState(functionName: "gaussianBlur")
            rgbToLabPipeline = try createPipelineState(functionName: "rgbToLab")
            initializeCentersPipeline = try createPipelineState(functionName: "initializeCenters")
            assignPixelsPipeline = try createPipelineState(functionName: "assignPixels")
            updateCentersPipeline = try createPipelineState(functionName: "updateCenters")
            finalizeCentersPipeline = try createPipelineState(functionName: "finalizeCenters")
            clearAccumulatorsPipeline = try createPipelineState(functionName: "clearAccumulators")
            clearDistancesPipeline = try createPipelineState(functionName: "clearDistances")
            enforceConnectivityPipeline = try createPipelineState(functionName: "enforceConnectivity")
            drawBoundariesPipeline = try createPipelineState(functionName: "drawBoundaries")
        } catch {
            print("Failed to create pipeline states: \(error)")
            return nil
        }
    }

    private func createPipelineState(functionName: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw NSError(domain: "SLICProcessor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to find function: \(functionName)"])
        }

        return try device.makeComputePipelineState(function: function)
    }

    func processImage(_ nsImage: NSImage, parameters: Parameters) -> (original: NSImage, segmented: NSImage, processingTime: Double)? {
        let startTime = CFAbsoluteTimeGetCurrent()
        var timings: [String: Double] = [:]
        var lastTime = startTime

        func logTiming(_ stage: String) {
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = (now - lastTime) * 1000  // Convert to milliseconds
            timings[stage] = elapsed
            print(String(format: "  %-30@: %.2f ms", stage as NSString, elapsed))
            lastTime = now
        }

        print("\n=== SLIC Processing Started ===")

        // Convert NSImage to CGImage
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to convert NSImage to CGImage")
            return nil
        }
        logTiming("NSImage to CGImage")

        let width = cgImage.width
        let height = cgImage.height
        print("Image size: \(width)x\(height)")

        // Create textures
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let inputTexture = device.makeTexture(descriptor: textureDescriptor),
              let blurredTexture = device.makeTexture(descriptor: textureDescriptor),
              let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            print("Failed to create textures")
            return nil
        }
        logTiming("Create textures")

        // Load image data into input texture
        loadImageIntoTexture(cgImage: cgImage, texture: inputTexture)
        logTiming("Load image to texture")

        // Calculate grid parameters
        let gridSpacing = Int(sqrt(Double(width * height) / Double(parameters.nSegments)))
        let searchRegion = 2 * gridSpacing
        let gridWidth = (width + gridSpacing - 1) / gridSpacing
        let gridHeight = (height + gridSpacing - 1) / gridSpacing
        let numCenters = gridWidth * gridHeight

        // Spatial weight for distance calculation
        let spatialWeight = parameters.compactness / Float(gridSpacing)

        // Create buffers
        let labBufferSize = width * height * MemoryLayout<SIMD3<Float>>.size
        guard let labBuffer = device.makeBuffer(length: labBufferSize, options: .storageModeShared) else {
            print("Failed to create LAB buffer")
            return nil
        }

        let centersBufferSize = numCenters * MemoryLayout<ClusterCenter>.size
        guard let centersBuffer = device.makeBuffer(length: centersBufferSize, options: .storageModeShared) else {
            print("Failed to create centers buffer")
            return nil
        }

        let labelsBufferSize = width * height * MemoryLayout<UInt32>.size
        guard let labelsBuffer = device.makeBuffer(length: labelsBufferSize, options: .storageModeShared),
              let labelsBufferCopy = device.makeBuffer(length: labelsBufferSize, options: .storageModeShared) else {
            print("Failed to create labels buffers")
            return nil
        }

        let distancesBufferSize = width * height * MemoryLayout<Float>.size
        guard let distancesBuffer = device.makeBuffer(length: distancesBufferSize, options: .storageModeShared) else {
            print("Failed to create distances buffer")
            return nil
        }

        let accumulatorSize = numCenters * MemoryLayout<CenterAccumulator>.size
        guard let accumulatorBuffer = device.makeBuffer(length: accumulatorSize, options: .storageModeShared) else {
            print("Failed to create accumulator buffer")
            return nil
        }

        // Create params buffer
        var params = SLICParams(
            imageWidth: UInt32(width),
            imageHeight: UInt32(height),
            gridSpacing: UInt32(gridSpacing),
            searchRegion: UInt32(searchRegion),
            compactness: parameters.compactness,
            spatialWeight: spatialWeight,
            numCenters: UInt32(numCenters),
            iteration: 0
        )

        let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<SLICParams>.size, options: .storageModeShared)!
        logTiming("Create buffers")

        // Initialize distances to infinity and labels to 0
        let distancesPointer = distancesBuffer.contents().bindMemory(to: Float.self, capacity: width * height)
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        for i in 0..<(width * height) {
            distancesPointer[i] = Float.infinity
            labelsPointer[i] = 0
        }
        logTiming("Initialize buffers")

        // Execute SLIC algorithm
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create command buffer")
            return nil
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

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        logTiming("Initial GPU operations")

        // Step 4: Iterative assignment and update
        print("\nStarting \(parameters.iterations) iterations:")
        for iteration in 0..<parameters.iterations {
            let iterStartTime = CFAbsoluteTimeGetCurrent()
            guard let iterCommandBuffer = commandQueue.makeCommandBuffer() else { continue }

            // Clear distances for new iteration using GPU
            if let encoder = iterCommandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(clearDistancesPipeline)
                encoder.setBuffer(distancesBuffer, offset: 0, index: 0)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

                let threadsPerGrid = MTLSize(width: width * height, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Assign pixels to nearest centers
            if let encoder = iterCommandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(assignPixelsPipeline)
                encoder.setBuffer(labBuffer, offset: 0, index: 0)
                encoder.setBuffer(centersBuffer, offset: 0, index: 1)
                encoder.setBuffer(labelsBuffer, offset: 0, index: 2)
                encoder.setBuffer(distancesBuffer, offset: 0, index: 3)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 4)

                let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Clear accumulators
            if let encoder = iterCommandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(clearAccumulatorsPipeline)
                encoder.setBuffer(accumulatorBuffer, offset: 0, index: 0)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

                let threadsPerGrid = MTLSize(width: numCenters, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: min(numCenters, 256), height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            // Update centers (accumulate)
            if let encoder = iterCommandBuffer.makeComputeCommandEncoder() {
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

            // Finalize centers (compute means)
            if let encoder = iterCommandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(finalizeCentersPipeline)
                encoder.setBuffer(accumulatorBuffer, offset: 0, index: 0)
                encoder.setBuffer(centersBuffer, offset: 0, index: 1)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 2)

                let threadsPerGrid = MTLSize(width: numCenters, height: 1, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: min(numCenters, 256), height: 1, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            iterCommandBuffer.commit()
            iterCommandBuffer.waitUntilCompleted()

            let iterTime = (CFAbsoluteTimeGetCurrent() - iterStartTime) * 1000
            print(String(format: "  Iteration %d: %.2f ms", iteration + 1, iterTime))
        }
        logTiming("All iterations complete")

        // Step 5: Enforce connectivity (if enabled)
        if parameters.enforceConnectivity {
            guard let connectivityBuffer = commandQueue.makeCommandBuffer() else {
                print("Failed to create connectivity command buffer")
                return nil
            }

            // Copy labels for reference
            let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
            let labelsCopyPointer = labelsBufferCopy.contents().bindMemory(to: UInt32.self, capacity: width * height)
            memcpy(labelsCopyPointer, labelsPointer, labelsBufferSize)

            if let encoder = connectivityBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(enforceConnectivityPipeline)
                encoder.setBuffer(labelsBuffer, offset: 0, index: 0)
                encoder.setBuffer(labelsBufferCopy, offset: 0, index: 1)
                encoder.setBuffer(paramsBuffer, offset: 0, index: 2)

                let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
                let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
                encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
                encoder.endEncoding()
            }

            connectivityBuffer.commit()
            connectivityBuffer.waitUntilCompleted()
        }
        logTiming("Enforce connectivity")

        // Step 6: Draw boundaries
        guard let boundaryBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create boundary command buffer")
            return nil
        }

        if let encoder = boundaryBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(drawBoundariesPipeline)
            encoder.setTexture(inputTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBuffer(labelsBuffer, offset: 0, index: 0)
            encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

            let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
            let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
            encoder.endEncoding()
        }

        boundaryBuffer.commit()
        boundaryBuffer.waitUntilCompleted()
        logTiming("Draw boundaries")

        // Convert output texture to NSImage
        let segmentedImage = textureToNSImage(texture: outputTexture)
        logTiming("Convert texture to NSImage")

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        print("\n=== SLIC Processing Complete ===")
        print(String(format: "Total time: %.2f ms (%.3f seconds)", processingTime * 1000, processingTime))
        print("\nBreakdown:")
        for (stage, time) in timings.sorted(by: { $0.value > $1.value }) {
            let percentage = (time / (processingTime * 1000)) * 100
            print(String(format: "  %-30@: %6.2f ms (%5.1f%%)", stage as NSString, time, percentage))
        }
        print("")

        return (nsImage, segmentedImage, processingTime)
    }

    private func loadImageIntoTexture(cgImage: CGImage, texture: MTLTexture) {
        let width = cgImage.width
        let height = cgImage.height

        // With bgra8Unorm, we can load the image data directly
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let data = UnsafeMutableRawPointer.allocate(byteCount: height * bytesPerRow, alignment: 1)
        defer { data.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Use BGRA format to match our texture format
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(data: data,
                                     width: width,
                                     height: height,
                                     bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow,
                                     space: colorSpace,
                                     bitmapInfo: bitmapInfo) else {
            print("Failed to create CGContext for loading image")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Load directly into texture - no conversion needed!
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                       mipmapLevel: 0,
                       withBytes: data,
                       bytesPerRow: bytesPerRow)
    }

    private func textureToNSImage(texture: MTLTexture) -> NSImage {
        let width = texture.width
        let height = texture.height

        // With bgra8Unorm, we can read the data directly as UInt8
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let data = UnsafeMutableRawPointer.allocate(byteCount: height * bytesPerRow, alignment: 1)
        defer { data.deallocate() }

        texture.getBytes(data,
                        bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Match the BGRA format we're using
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let dataProvider = CGDataProvider(dataInfo: nil,
                                                data: data,
                                                size: height * bytesPerRow,
                                                releaseData: { _, _, _ in }) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        guard let cgImage = CGImage(width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bitsPerPixel: 32,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: true,
                                   intent: .defaultIntent) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
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