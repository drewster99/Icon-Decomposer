import Foundation
import Metal

/// Execution context passed through the pipeline
public struct ExecutionContext {
    public let resources: MetalResources
    public let commandBuffer: MTLCommandBuffer
    public var buffers: [String: MTLBuffer]
    public var metadata: [String: Any]

    // Convenient accessors
    public var device: MTLDevice { resources.device }
    public var library: MTLLibrary { resources.library }

    public init(
        resources: MetalResources,
        commandBuffer: MTLCommandBuffer,
        buffers: [String: MTLBuffer] = [:],
        metadata: [String: Any] = [:]
    ) {
        self.resources = resources
        self.commandBuffer = commandBuffer
        self.buffers = buffers
        self.metadata = metadata
    }
}

/// Protocol for pipeline operations
public protocol PipelineOperation {
    /// The type of data this operation expects as input
    var inputType: DataType { get }

    /// The type of data this operation produces as output
    var outputType: DataType { get }

    /// Execute the operation
    func execute(context: inout ExecutionContext) async throws
}

/// Operation that validates type compatibility before execution
public class ValidatedOperation: PipelineOperation {
    public let inputType: DataType
    public let outputType: DataType
    private let executeBlock: (inout ExecutionContext) async throws -> Void

    public init(
        inputType: DataType,
        outputType: DataType,
        execute: @escaping (inout ExecutionContext) async throws -> Void
    ) {
        self.inputType = inputType
        self.outputType = outputType
        self.executeBlock = execute
    }

    public func execute(context: inout ExecutionContext) async throws {
        try await executeBlock(&context)
    }
}
