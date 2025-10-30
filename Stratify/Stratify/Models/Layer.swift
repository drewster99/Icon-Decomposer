//
//  Layer.swift
//  Stratify
//
//  Represents a single color-separated layer
//

import Foundation
import AppKit
import simd

struct Layer: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var pixelCount: Int
    var averageColor: SIMD3<Float>  // LAB color space

    /// Image data stored as PNG
    private var imageData: Data

    /// Explicit pixel dimensions (not points)
    private var pixelWidth: Int
    private var pixelHeight: Int

    /// Computed property for display - creates NSImage for SwiftUI
    nonisolated var image: NSImage? {
        guard let cgImage = CGImage.create(from: imageData) else { return nil }
        // Create NSImage with explicit size to avoid Retina confusion
        return NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
    }

    /// Direct access to CGImage for operations (no NSImage overhead)
    nonisolated var cgImage: CGImage? {
        return CGImage.create(from: imageData)
    }

    init(id: UUID = UUID(),
         name: String,
         cgImage: CGImage,
         pixelCount: Int,
         averageColor: SIMD3<Float>) {
        self.id = id
        self.name = name
        self.pixelCount = pixelCount
        self.averageColor = averageColor

        // Store explicit pixel dimensions from CGImage
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height

        // Convert CGImage directly to PNG data (no TIFF intermediate)
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            self.imageData = pngData

            // Diagnostic: Verify what was stored
            print("💾 Stored layer '\(name)': \(self.pixelWidth)×\(self.pixelHeight)px, \(cgImage.bitsPerComponent)-bit")
        } else {
            self.imageData = Data()
            print("⚠️ Layer '\(name)': Failed to encode image data")
        }
    }

    // Convenience init for creating merged/combined layers from existing image data
    init(id: UUID = UUID(),
         name: String,
         imageData: Data,
         pixelWidth: Int,
         pixelHeight: Int,
         pixelCount: Int,
         averageColor: SIMD3<Float>) {
        self.id = id
        self.name = name
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelCount = pixelCount
        self.averageColor = averageColor
    }

    // Make Layer mutable for renaming
    mutating func rename(_ newName: String) {
        self.name = newName
    }
}

// MARK: - CGImage Extension
extension CGImage {
    /// Create CGImage from PNG/JPEG data
    nonisolated static func create(from data: Data) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        // Try PNG first
        if let cgImage = CGImage(
            pngDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return cgImage
        }

        // Try JPEG if PNG fails
        if let cgImage = CGImage(
            jpegDataProviderSource: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            return cgImage
        }

        return nil
    }
}

// MARK: - SIMD3 Codable Extension
// Note: SIMD3 already conforms to Codable in Swift, but we need explicit handling for our use case

extension SIMD3 where Scalar == Float {
    func toArray() -> [Float] {
        return [x, y, z]
    }

    init(fromArray array: [Float]) {
        self.init(array[0], array[1], array[2])
    }
}
