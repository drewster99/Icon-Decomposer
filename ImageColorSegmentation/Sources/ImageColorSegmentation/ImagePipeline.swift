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
        guard let commandQueue = resources.device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineError.executionFailed("Failed to create command buffer")
        }

        // Create initial context with input image buffer
        var context = ExecutionContext(
            resources: resources,
            commandBuffer: commandBuffer,
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

        // Execute all operations
        for operation in operations {
            try await operation.execute(context: &context)
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

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

        guard let commandQueue = resources.device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineError.executionFailed("Failed to create command buffer")
        }

        // Start with parent's context (buffers and metadata)
        var context = ExecutionContext(
            resources: resources,
            commandBuffer: commandBuffer,
            buffers: parent.context.buffers,
            metadata: parent.context.metadata
        )

        // Find operations that aren't in the parent pipeline
        let parentOpCount = parent.pipeline.operations.count
        let newOperations = operations.dropFirst(parentOpCount)

        // Execute only NEW operations
        for operation in newOperations {
            try await operation.execute(context: &context)
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return PipelineExecution(
            pipeline: self,
            context: context,
            finalType: currentOutputType,
            commandBuffer: commandBuffer
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

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return buffer
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
    public func convertColorSpace(to colorSpace: ColorSpace, scale: LABScale = .default) throws -> Self {
        let operation = ColorConversionOperation(colorSpace: colorSpace, scale: scale)
        return try addOperation(operation)
    }

    /// Segment image into superpixels
    public func segment(superpixels: Int, compactness: Float = 25.0) throws -> Self {
        let operation = SegmentationOperation(superpixelCount: superpixels, compactness: compactness)
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
    public func autoMerge(threshold: Float) throws -> Self {
        let operation = MergeOperation(threshold: threshold)
        return try addOperation(operation)
    }
}

// MARK: - Supporting Types

public enum ColorSpace {
    case lab
    case rgb
}

public struct LABScale {
    public let l: Float
    public let a: Float
    public let b: Float

    public static let `default` = LABScale(l: 1.0, a: 1.0, b: 1.0)
    public static let emphasizeGreens = LABScale(l: 1.0, a: 1.0, b: 2.0)

    public init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }
}
