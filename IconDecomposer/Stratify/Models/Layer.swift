//
//  Layer.swift
//  IconDecomposer
//
//  Represents a single color-separated layer
//

import Foundation
import AppKit
import simd

struct Layer: Identifiable, Codable {
    let id: UUID
    var name: String
    var pixelCount: Int
    var averageColor: SIMD3<Float>  // LAB color space
    var isSelected: Bool

    /// Image data stored as PNG
    private var imageData: Data

    /// Computed property for the actual image
    var image: NSImage? {
        get {
            return NSImage(data: imageData)
        }
        set {
            if let newImage = newValue,
               let tiffData = newImage.tiffRepresentation,
               let bitmapImage = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapImage.representation(using: .png, properties: [:]) {
                imageData = pngData
            }
        }
    }

    init(id: UUID = UUID(),
         name: String,
         image: NSImage,
         pixelCount: Int,
         averageColor: SIMD3<Float>,
         isSelected: Bool = true) {
        self.id = id
        self.name = name
        self.pixelCount = pixelCount
        self.averageColor = averageColor
        self.isSelected = isSelected

        // Convert image to PNG data
        if let tiffData = image.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            self.imageData = pngData
        } else {
            self.imageData = Data()
        }
    }

    // Make Layer mutable for renaming
    mutating func rename(_ newName: String) {
        self.name = newName
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
