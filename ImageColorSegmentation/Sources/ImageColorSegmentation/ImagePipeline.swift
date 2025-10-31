import Foundation
import Metal
import MetalKit

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

public enum PipelineError: Error {
    case invalidOperationSequence(String)
    case metalDeviceUnavailable
    case incompatibleDataTypes(expected: DataType, got: DataType)
    case executionFailed(String)
}

/// Main pipeline class for image processing
/// Uses OKLAB color space for perceptually uniform color operations
public class ImagePipeline {
    internal var operations: [PipelineOperation] = []
    private var currentOutputType: DataType = .none
    let resources: MetalResources

    /// Initialize pipeline with optional Metal resources and input image
    public init(resources: MetalResources? = nil, input: PlatformImage? = nil) {
        self.resources = resources ?? defaultResources

        if input != nil {
            currentOutputType = .rgbaImage
        }
    }

    /// Add an operation to the pipeline
    private func addOperation(_ operation: PipelineOperation) throws -> Self {
        // Validate type compatibility
        // Skip validation if this is the first operation or if types match
        if currentOutputType != .none &&
           currentOutputType != operation.inputType &&
           !currentOutputType.canFeedInto(operation.inputType) {
            throw PipelineError.incompatibleDataTypes(
                expected: operation.inputType,
                got: currentOutputType
            )
        }

        operations.append(operation)
        currentOutputType = operation.outputType
        return self
    }

    /// Create a copy of this pipeline for branching
    internal func copy() -> ImagePipeline {
        let newPipeline = ImagePipeline(resources: resources)
        newPipeline.operations = self.operations
        newPipeline.currentOutputType = self.currentOutputType
        return newPipeline
    }

    /// Execute the pipeline with an input image
    public func execute(input: PlatformImage) async throws -> PipelineExecution {
        // Create initial context with input image buffer
        var context = ExecutionContext(
            resources: resources,
            buffers: [:],
            metadata: [
                "width": Int(input.size.width),
                "height": Int(input.size.height)
            ]
        )

        // Convert input image to Metal buffer
        let inputBuffer = try createMetalBuffer(from: input)
        context.buffers["input"] = inputBuffer
        context.buffers["rgbaImage"] = inputBuffer

        // Execute all operations (each creates its own command buffer)
        for operation in operations {
            try await operation.execute(context: &context)
        }

        return PipelineExecution(
            pipeline: self,
            context: context,
            finalType: currentOutputType
        )
    }

    /// Execute the pipeline with an input image and optional depth map
    public func execute(input: PlatformImage, depthMap: PlatformImage) async throws -> PipelineExecution {
        // Create initial context with input image buffer
        var context = ExecutionContext(
            resources: resources,
            buffers: [:],
            metadata: [
                "width": Int(input.size.width),
                "height": Int(input.size.height)
            ]
        )

        // Convert input image to Metal buffer
        let inputBuffer = try createMetalBuffer(from: input)
        context.buffers["input"] = inputBuffer
        context.buffers["rgbaImage"] = inputBuffer

        // Convert depth map to Metal buffer (grayscale float buffer)
        let depthBuffer = try createDepthBuffer(from: depthMap)
        context.buffers["depthBuffer"] = depthBuffer

        // Execute all operations (each creates its own command buffer)
        for operation in operations {
            try await operation.execute(context: &context)
        }

        return PipelineExecution(
            pipeline: self,
            context: context,
            finalType: currentOutputType
        )
    }

    /// Execute the pipeline with multiple input images
    public func execute(inputs: [PlatformImage]) async throws -> [PipelineExecution] {
        var results: [PipelineExecution] = []

        for input in inputs {
            let result = try await execute(input: input)
            results.append(result)
        }

        return results
    }

    /// Execute pipeline branching from a parent execution
    /// This allows you to reuse results from a parent pipeline (e.g., SLIC) and only run new operations
    public func execute(from parent: PipelineExecution) async throws -> PipelineExecution {
        // Wait for parent to complete (or at least the steps we need)
        await parent.waitForStep(currentOutputType)

        // Start with parent's context (buffers and metadata)
        var context = ExecutionContext(
            resources: resources,
            buffers: parent.context.buffers,
            metadata: parent.context.metadata
        )

        // Find operations that aren't in the parent pipeline
        let parentOpCount = parent.pipeline.operations.count
        let newOperations = operations.dropFirst(parentOpCount)

        // Execute only NEW operations (each creates its own command buffer)
        for operation in newOperations {
            try await operation.execute(context: &context)
        }

        return PipelineExecution(
            pipeline: self,
            context: context,
            finalType: currentOutputType
        )
    }

    /// Convert platform image to Metal buffer
    private func createMetalBuffer(from image: PlatformImage) throws -> MTLBuffer {
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PipelineError.executionFailed("Failed to get CGImage")
        }
        #else
        guard let cgImage = image.cgImage else {
            throw PipelineError.executionFailed("Failed to get CGImage")
        }
        #endif

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bufferSize = height * bytesPerRow

        guard let buffer = resources.device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create Metal buffer")
        }

        // Draw image into buffer using BGRA format (premultipliedFirst + byteOrder32Little)
        // This matches Metal's bgra8Unorm texture format
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
            throw PipelineError.executionFailed("Failed to create CGContext")
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Composite semi-transparent/transparent pixels over white background
        // This ensures transparent pixels cluster as white instead of black
        #if os(macOS)
        context.setFillColor(NSColor.white.cgColor)
        #else
        context.setFillColor(UIColor.white.cgColor)
        #endif
        context.fill(fullRect)
        context.draw(cgImage, in: fullRect)

        return buffer
    }

    /// Convert depth map image to Metal float buffer
    private func createDepthBuffer(from depthMap: PlatformImage) throws -> MTLBuffer {
        #if os(macOS)
        guard let cgImage = depthMap.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PipelineError.executionFailed("Failed to get CGImage from depth map")
        }
        #else
        guard let cgImage = depthMap.cgImage else {
            throw PipelineError.executionFailed("Failed to get CGImage from depth map")
        }
        #endif

        let width = cgImage.width
        let height = cgImage.height
        let floatBufferSize = width * height * MemoryLayout<Float>.size

        guard let floatBuffer = resources.device.makeBuffer(length: floatBufferSize, options: .storageModeShared) else {
            throw PipelineError.executionFailed("Failed to create depth Metal buffer")
        }

        // Create temporary CPU buffer for RGBA data (will be deallocated when out of scope)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let rgbaBufferSize = height * bytesPerRow
        var tempData = Data(count: rgbaBufferSize)

        // Draw depth map into temporary CPU buffer
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = tempData.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> CGContext? in
            return CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        }

        guard let context = context else {
            throw PipelineError.executionFailed("Failed to create CGContext for depth extraction")
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: fullRect)

        // Extract grayscale values and convert to floats (0-1 range)
        let floatPointer = floatBuffer.contents().bindMemory(to: Float.self, capacity: width * height)
        tempData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let rgbaPointer = bytes.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                // BGRA format: extract R channel (all channels should be the same for grayscale)
                let pixelOffset = i * 4
                let grayValue = rgbaPointer[pixelOffset + 2]  // R channel in BGRA
                floatPointer[i] = Float(grayValue) / 255.0
            }
        }

        return floatBuffer
    }
}

/// Result of pipeline execution
public class PipelineExecution {
    public let pipeline: ImagePipeline
    public let context: ExecutionContext
    public let finalType: DataType
    private let commandBuffer: MTLCommandBuffer?
    private var stepEvents: [DataType: MTLSharedEvent] = [:]
    private var isCompleted: Bool = false

    init(
        pipeline: ImagePipeline,
        context: ExecutionContext,
        finalType: DataType,
        commandBuffer: MTLCommandBuffer? = nil,
        stepEvents: [DataType: MTLSharedEvent] = [:]
    ) {
        self.pipeline = pipeline
        self.context = context
        self.finalType = finalType
        self.commandBuffer = commandBuffer
        self.stepEvents = stepEvents
    }

    /// Get a specific buffer from the execution context
    public func buffer(named name: String) -> MTLBuffer? {
        return context.buffers[name]
    }

    /// Get metadata value
    public func metadata<T>(for key: String) -> T? {
        return context.metadata[key] as? T
    }

    /// Wait for execution to complete
    public func waitUntilCompleted() {
        guard !isCompleted else { return }
        commandBuffer?.waitUntilCompleted()
        isCompleted = true
    }

    /// Check if a specific step has completed
    public func isStepCompleted(_ type: DataType) -> Bool {
        guard let event = stepEvents[type] else { return false }
        return event.signaledValue > 0
    }

    /// Wait for a specific step to complete
    public func waitForStep(_ type: DataType) async {
        guard let event = stepEvents[type] else { return }

        if event.signaledValue > 0 {
            return  // Already completed
        }

        // For now, just wait for the whole buffer
        // TODO: Implement proper event-based waiting with MTLSharedEventListener
        waitUntilCompleted()
    }
}

// MARK: - Pipeline Building Methods

extension ImagePipeline {
    /// Convert color space
    public func convertColorSpace(to colorSpace: ColorSpace, adjustments: LABColorAdjustments = .default) throws -> Self {
        let operation = ColorConversionOperation(colorSpace: colorSpace, adjustments: adjustments)
        return try addOperation(operation)
    }

    /// Segment image into superpixels
    public func segment(superpixels: Int, compactness: Float = 25.0, depthWeight: Float = 0.0) throws -> Self {
        let operation = SegmentationOperation(superpixelCount: superpixels, compactness: compactness, depthWeight: depthWeight)
        return try addOperation(operation)
    }

    /// Cluster features using K-means++ algorithm
    public func cluster(into k: Int, seed: Int? = nil) throws -> Self {
        let operation = ClusteringOperation(clusterCount: k, seed: seed)
        return try addOperation(operation)
    }

    /// Extract layers from clusters
    public func extractLayers() throws -> Self {
        let operation = LayerExtractionOperation()
        return try addOperation(operation)
    }

    /// Merge similar clusters
    public func autoMerge(threshold: Float, strategy: MergeStrategy = .simple) throws -> Self {
        let operation = MergeOperation(threshold: threshold, strategy: strategy)
        return try addOperation(operation)
    }
}

// MARK: - Supporting Types

public enum ColorSpace {
    case lab
    case rgb
}

public struct LABColorAdjustments {
    public let lightnessScale: Float
    public let greenAxisScale: Float  // Not used with OKLAB, kept for compatibility

    /// Default adjustments optimized for OKLAB color space
    /// - lightnessScale: 1.0 (OKLAB is more uniform, start without scaling)
    /// - greenAxisScale: 1.0 (OKLAB doesn't need axis-specific scaling)
    public static let `default` = LABColorAdjustments(
        lightnessScale: 1.0,
        greenAxisScale: 1.0
    )

    public init(lightnessScale: Float, greenAxisScale: Float) {
        self.lightnessScale = lightnessScale
        self.greenAxisScale = greenAxisScale
    }
}

public enum MergeStrategy {
    /// Simple merge: merges all cluster pairs below threshold in one pass
    case simple

    /// Iterative weighted merge: uses weighted distances to find pairs, checks unweighted threshold to stop
    /// - Parameter adjustments: Optional color adjustments. If nil, uses pipeline default.
    case iterativeWeighted(adjustments: LABColorAdjustments? = nil)
}
