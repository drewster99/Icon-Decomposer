//
//  DepthEstimator.swift
//  Stratify
//
//  Wrapper for DepthAnythingV2 CoreML model
//

import Foundation
import CoreImage
import CoreML
import AppKit

/// Estimates depth from images using DepthAnythingV2 CoreML model
class DepthEstimator {

    /// The depth model (F32 precision)
    private var model: DepthAnythingV2SmallF32?

    /// CIContext for image processing
    private let context = CIContext()

    /// Target size expected by the model
    private let targetSize = CGSize(width: 518, height: 392)

    /// Pixel buffer for model input (reused to avoid allocations)
    private let inputPixelBuffer: CVPixelBuffer

    init() throws {
        // Create a reusable buffer to avoid allocating memory for every model invocation
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(targetSize.width),
            Int(targetSize.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer = buffer else {
            throw DepthEstimatorError.failedToCreatePixelBuffer
        }
        self.inputPixelBuffer = buffer

        // Load model
        print("Loading DepthAnythingV2SmallF32 model...")
        let startTime = CFAbsoluteTimeGetCurrent()
        self.model = try DepthAnythingV2SmallF32()
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("Model loaded in \(String(format: "%.2f", duration * 1000))ms")
    }

    /// Estimate depth from an NSImage
    /// - Parameter image: Input image
    /// - Returns: Depth map as NSImage (grayscale, normalized to 0-1)
    func estimateDepth(from image: NSImage) throws -> NSImage {
        guard let model = model else {
            throw DepthEstimatorError.modelNotLoaded
        }

        // Convert NSImage to CIImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DepthEstimatorError.failedToConvertImage
        }

        let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
        let inputImage = CIImage(cgImage: cgImage).resized(to: targetSize)

        // Render to pixel buffer
        context.render(inputImage, to: inputPixelBuffer)

        // Run inference
        let result = try model.prediction(image: inputPixelBuffer)

        // Convert depth output to NSImage
        let depthCIImage = CIImage(cvPixelBuffer: result.depth)
            .resized(to: originalSize)

        guard let depthCGImage = context.createCGImage(depthCIImage, from: depthCIImage.extent) else {
            throw DepthEstimatorError.failedToConvertImage
        }

        return NSImage(cgImage: depthCGImage, size: originalSize)
    }

    /// Estimate depth and return as normalized float array
    /// - Parameter image: Input image
    /// - Returns: Depth values normalized to 0-1 range (closer = higher value)
    func estimateDepthValues(from image: NSImage) throws -> (width: Int, height: Int, depths: [Float]) {
        guard let model = model else {
            throw DepthEstimatorError.modelNotLoaded
        }

        // Convert NSImage to CIImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DepthEstimatorError.failedToConvertImage
        }

        let width = cgImage.width
        let height = cgImage.height
        let inputImage = CIImage(cgImage: cgImage).resized(to: targetSize)

        // Render to pixel buffer
        context.render(inputImage, to: inputPixelBuffer)

        // Run inference
        let result = try model.prediction(image: inputPixelBuffer)

        // Extract depth values from output pixel buffer
        let depthBuffer = result.depth
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthBuffer)
        let depthHeight = CVPixelBufferGetHeight(depthBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            throw DepthEstimatorError.failedToAccessPixelBuffer
        }

        // Read grayscale values (assuming single-channel output)
        // The depth map is likely a single-channel float or grayscale image
        var depths = [Float]()
        depths.reserveCapacity(width * height)

        // Scale depth values from model resolution back to original resolution
        for y in 0..<height {
            for x in 0..<width {
                // Map original coordinates to depth map coordinates
                let depthX = Int(Float(x) * Float(depthWidth) / Float(width))
                let depthY = Int(Float(y) * Float(depthHeight) / Float(height))

                let offset = depthY * bytesPerRow + depthX * 4  // Assuming BGRA format
                let pixels = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * depthHeight)

                // Extract grayscale value (all channels should be the same for grayscale)
                let value = Float(pixels[offset]) / 255.0
                depths.append(value)
            }
        }

        return (width, height, depths)
    }
}

enum DepthEstimatorError: Error, LocalizedError {
    case modelNotLoaded
    case failedToCreatePixelBuffer
    case failedToConvertImage
    case failedToAccessPixelBuffer

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Depth model is not loaded"
        case .failedToCreatePixelBuffer:
            return "Failed to create pixel buffer for model input"
        case .failedToConvertImage:
            return "Failed to convert image format"
        case .failedToAccessPixelBuffer:
            return "Failed to access pixel buffer data"
        }
    }
}

// MARK: - CIImage Extension

extension CIImage {
    /// Resize CIImage to target size
    func resized(to size: CGSize) -> CIImage {
        let scaleX = size.width / extent.width
        let scaleY = size.height / extent.height
        return transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}
