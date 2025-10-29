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
import AppKit

/// Parameters for superpixel extraction (matches Metal struct)
struct SuperpixelExtractionParams {
    let imageWidth: UInt32
    let imageHeight: UInt32
    let maxLabel: UInt32
}

/// Processes SLIC output to extract superpixel features for clustering
class SuperpixelProcessor {

    // Metal objects for GPU acceleration
    private static let device: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        return device
    }()

    private static let commandQueue: MTLCommandQueue = {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        return queue
    }()

    private static let library: MTLLibrary = {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load Metal default library")
        }
        return library
    }()

    // Lazy-loaded pipeline states
    private static var findMaxLabelPipeline: MTLComputePipelineState = {
        guard let function = library.makeFunction(name: "findMaxLabel") else {
            fatalError("Failed to load findMaxLabel Metal function")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            fatalError("Failed to create findMaxLabel pipeline state: \(error)")
        }
    }()

    private static var accumulateSuperpixelFeaturesPipeline: MTLComputePipelineState = {
        guard let function = library.makeFunction(name: "accumulateSuperpixelFeatures") else {
            fatalError("Failed to load accumulateSuperpixelFeatures Metal function")
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            fatalError("Failed to create accumulateSuperpixelFeatures pipeline state: \(error)")
        }
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

                if var color = colorAccumulators[label] {
                    color += labColor
                    colorAccumulators[label] = color
                }
                if var position = positionAccumulators[label] {
                    position += SIMD2<Float>(Float(x), Float(y))
                    positionAccumulators[label] = position
                }
                if let count = pixelCounts[label] {
                    pixelCounts[label] = count + 1
                }
            }
        }

        // Calculate averages and create superpixel objects
        var superpixels: [Superpixel] = []

        for label in uniqueLabels.sorted() {
            guard let pixelCount = pixelCounts[label], pixelCount != 0 else { continue }

            guard let avgColorAccumulator = colorAccumulators[label],
                  let avgPositionAccumulator = positionAccumulators[label] else {
                continue
            }

            let avgColor = avgColorAccumulator / Float(pixelCount)
            let avgPosition = avgPositionAccumulator / Float(pixelCount)

            let superpixel = Superpixel(
                id: Int(label),
                labColor: avgColor,
                pixelCount: pixelCount,
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

        // Find max label (CPU scan - GPU version has atomic contention issues)
        #if DEBUG
        let findMaxStart = CFAbsoluteTimeGetCurrent()
        #endif

        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: pixelCount)
        let transparentLabel: UInt32 = 0xFFFFFFFE
        var maxLabel: UInt32 = 0
        for i in 0..<pixelCount {
            let label = labelsPointer[i]
            // Skip transparent label when finding max
            if label != transparentLabel {
                maxLabel = max(maxLabel, label)
            }
        }
        let numSuperpixels = Int(maxLabel) + 1  // Labels are 0-indexed

        #if DEBUG
        let findMaxTime = CFAbsoluteTimeGetCurrent() - findMaxStart
        print(String(format: "  Find maxLabel (CPU): %.2f ms", findMaxTime * 1000))
        #endif

        // Create Metal buffers for accumulation
        // Use maxLabel+1 as array size to handle sparse labels
        #if DEBUG
        let buffersStart = CFAbsoluteTimeGetCurrent()
        #endif

        guard let colorAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 3,
            options: .storageModeShared
        ) else {
            fatalError("Failed to create colorAccumulatorsBuffer")
        }

        guard let positionAccumulatorsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numSuperpixels * 2,
            options: .storageModeShared
        ) else {
            fatalError("Failed to create positionAccumulatorsBuffer")
        }

        guard let pixelCountsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numSuperpixels,
            options: .storageModeShared
        ) else {
            fatalError("Failed to create pixelCountsBuffer")
        }

        // Zero out the accumulator buffers
        memset(colorAccumulatorsBuffer.contents(), 0, colorAccumulatorsBuffer.length)
        memset(positionAccumulatorsBuffer.contents(), 0, positionAccumulatorsBuffer.length)
        memset(pixelCountsBuffer.contents(), 0, pixelCountsBuffer.length)

        #if DEBUG
        let buffersTime = CFAbsoluteTimeGetCurrent() - buffersStart
        print(String(format: "  Create/zero buffers: %.2f ms", buffersTime * 1000))
        #endif

        // Create parameter struct
        var params = SuperpixelExtractionParams(
            imageWidth: UInt32(width),
            imageHeight: UInt32(height),
            maxLabel: maxLabel
        )

        // Dispatch Metal kernel
        #if DEBUG
        let gpuAccumulateStart = CFAbsoluteTimeGetCurrent()
        #endif

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create Metal command buffer")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            fatalError("Failed to create Metal compute encoder")
        }

        encoder.setComputePipelineState(accumulateSuperpixelFeaturesPipeline)
        encoder.setBuffer(labBuffer, offset: 0, index: 0)
        encoder.setBuffer(labelsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorAccumulatorsBuffer, offset: 0, index: 2)
        encoder.setBuffer(positionAccumulatorsBuffer, offset: 0, index: 3)
        encoder.setBuffer(pixelCountsBuffer, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<SuperpixelExtractionParams>.size, index: 5)

        let accumulateThreadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let accumulateGroupsPerGrid = MTLSize(
            width: (pixelCount + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(accumulateGroupsPerGrid, threadsPerThreadgroup: accumulateThreadsPerGroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #if DEBUG
        let gpuAccumulateTime = CFAbsoluteTimeGetCurrent() - gpuAccumulateStart
        print(String(format: "  GPU accumulate: %.2f ms", gpuAccumulateTime * 1000))
        #endif

        // Read back results and create Superpixel objects
        #if DEBUG
        let readbackStart = CFAbsoluteTimeGetCurrent()
        #endif

        let colorAccumulators = colorAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 3)
        let positionAccumulators = positionAccumulatorsBuffer.contents().bindMemory(to: Float.self, capacity: numSuperpixels * 2)
        let pixelCounts = pixelCountsBuffer.contents().bindMemory(to: Int32.self, capacity: numSuperpixels)

        var superpixels: [Superpixel] = []
        var uniqueLabels = Set<UInt32>()
        var transparentPixelCount = 0

        // Build uniqueLabels by scanning pixelCounts array (avoids full labelMap scan)
        for labelInt in 0..<numSuperpixels {
            let pixelCount = Int(pixelCounts[labelInt])

            guard pixelCount != 0 else { continue }

            // Skip transparent pixels (assigned to special trash label)
            let transparentLabel: UInt32 = 0xFFFFFFFE
            if UInt32(labelInt) == transparentLabel {
                transparentPixelCount = pixelCount
                continue
            }

            uniqueLabels.insert(UInt32(labelInt))

            // Calculate averages
            let colorBaseIndex = labelInt * 3
            let avgColor = SIMD3<Float>(
                colorAccumulators[colorBaseIndex + 0] / Float(pixelCount),
                colorAccumulators[colorBaseIndex + 1] / Float(pixelCount),
                colorAccumulators[colorBaseIndex + 2] / Float(pixelCount)
            )

            let positionBaseIndex = labelInt * 2
            let avgPosition = SIMD2<Float>(
                positionAccumulators[positionBaseIndex + 0] / Float(pixelCount),
                positionAccumulators[positionBaseIndex + 1] / Float(pixelCount)
            )

            let superpixel = Superpixel(
                id: labelInt,
                labColor: avgColor,
                pixelCount: pixelCount,
                centerPosition: avgPosition
            )
            superpixels.append(superpixel)
        }

        #if DEBUG
        let readbackTime = CFAbsoluteTimeGetCurrent() - readbackStart
        print(String(format: "  Create Superpixel objects: %.2f ms", readbackTime * 1000))
        #endif

        let totalPixels = width * height
        let transparentPercent = Double(transparentPixelCount) / Double(totalPixels) * 100.0

        print("Extracted \(superpixels.count) superpixels from \(width)x\(height) image (Metal GPU)")
        if transparentPixelCount > 0 {
            print(String(format: "  Excluded %d transparent pixels (%.1f%%) from clustering", transparentPixelCount, transparentPercent))
        }

        // Build labelMap from buffer (only done once at the end)
        // Reuse labelsPointer from above
        #if DEBUG
        let labelMapStart = CFAbsoluteTimeGetCurrent()
        #endif

        let labelMap = Array(UnsafeBufferPointer(start: labelsPointer, count: pixelCount))

        #if DEBUG
        let labelMapTime = CFAbsoluteTimeGetCurrent() - labelMapStart
        print(String(format: "  Build labelMap: %.2f ms", labelMapTime * 1000))
        #endif

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

    /// Visualize superpixels by filling each with its average LAB color
    /// - Parameters:
    ///   - superpixelData: Processed superpixel data
    ///   - greenAxisScale: Scale factor for negative 'a' values
    /// - Returns: NSImage where each superpixel shows its average color
    static func visualizeSuperpixelAverageColors(superpixelData: SuperpixelData, greenAxisScale: Float) -> NSImage {
        let width = superpixelData.imageWidth
        let height = superpixelData.imageHeight

        // Create mapping from superpixel ID to average LAB color
        var superpixelColors = [UInt32: SIMD3<Float>]()
        for superpixel in superpixelData.superpixels {
            superpixelColors[UInt32(superpixel.id)] = superpixel.labColor
        }

        // Create pixel data
        var pixelData = Data(count: width * height * 4)

        pixelData.withUnsafeMutableBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let superpixelLabel = superpixelData.labelMap[idx]

                    // Get LAB color for this superpixel
                    guard let labColor = superpixelColors[superpixelLabel] else {
                        // Fallback to black for unmapped labels
                        let pixelOffset = idx * 4
                        pixels[pixelOffset + 0] = 0  // B
                        pixels[pixelOffset + 1] = 0  // G
                        pixels[pixelOffset + 2] = 0  // R
                        pixels[pixelOffset + 3] = 255  // A
                        continue
                    }

                    // Convert LAB to RGB
                    let rgb = labToRGB(labColor, greenAxisScale: greenAxisScale)

                    // Write BGRA pixels with byteOrder32Little
                    let pixelOffset = idx * 4
                    pixels[pixelOffset + 0] = UInt8(rgb.z * 255)  // B
                    pixels[pixelOffset + 1] = UInt8(rgb.y * 255)  // G
                    pixels[pixelOffset + 2] = UInt8(rgb.x * 255)  // R
                    pixels[pixelOffset + 3] = 255                  // A
                }
            }
        }

        // Convert Data to CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let dataProvider = CGDataProvider(data: pixelData as CFData),
              let cgImage = CGImage(
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
            // Return empty image on failure
            return NSImage(size: NSSize(width: width, height: height))
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Convert LAB color to RGB (same as KMeansProcessor)
    private static func labToRGB(_ lab: SIMD3<Float>, greenAxisScale: Float) -> SIMD3<Float> {
        // Reverse green axis scaling if 'a' was scaled during RGB→LAB conversion
        let a = lab.y < 0 ? lab.y / greenAxisScale : lab.y

        // LAB to XYZ
        let fy = (lab.x + 16.0) / 116.0
        let fx = a / 500.0 + fy
        let fz = fy - lab.z / 200.0

        let xr = fx > 0.206897 ? fx * fx * fx : (fx - 16.0/116.0) / 7.787
        let yr = fy > 0.206897 ? fy * fy * fy : (fy - 16.0/116.0) / 7.787
        let zr = fz > 0.206897 ? fz * fz * fz : (fz - 16.0/116.0) / 7.787

        let x = xr * 95.047
        let y = yr * 100.000
        let z = zr * 108.883

        // XYZ to RGB (sRGB)
        let r =  3.2406 * x / 100.0 - 1.5372 * y / 100.0 - 0.4986 * z / 100.0
        let g = -0.9689 * x / 100.0 + 1.8758 * y / 100.0 + 0.0415 * z / 100.0
        let b =  0.0557 * x / 100.0 - 0.2040 * y / 100.0 + 1.0570 * z / 100.0

        // Apply gamma correction and clamp
        let gammaCorrect: (Float) -> Float = { value in
            let clamped = max(0, min(1, value))
            return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0/2.4) - 0.055
        }

        return SIMD3<Float>(
            gammaCorrect(r),
            gammaCorrect(g),
            gammaCorrect(b)
        )
    }
}
