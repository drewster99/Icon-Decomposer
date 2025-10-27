//
//  IconDecomposerDocument.swift
//  IconDecomposer
//
//  Document model for icon decomposition projects
//

import SwiftUI
import Cocoa
import Combine
import UniformTypeIdentifiers

extension UTType {
    static let iconDecomposerProject = UTType(exportedAs: "com.nuclearcyborg.Stratify.project")
}

class IconDecomposerDocument: ReferenceFileDocument, ObservableObject {

    // MARK: - ReferenceFileDocument

    static var readableContentTypes: [UTType] { [.iconDecomposerProject] }

    required init(configuration: ReadConfiguration) throws {
        self.sourceImage = nil
        self.parameters = ProcessingParameters.default
        self.layers = []
        self.layerGroups = []
        self.processingState = .idle

        if let data = configuration.file.regularFileContents {
            let decoder = PropertyListDecoder()
            let archive = try decoder.decode(DocumentArchive.self, from: data)

            self.sourceImage = archive.sourceImage
            self.parameters = archive.parameters
            self.layers = archive.layers
            self.layerGroups = archive.layerGroups
            self.processingState = .completed
        }
    }

    func snapshot(contentType: UTType) throws -> DocumentArchive {
        guard let sourceImage = sourceImage else {
            throw NSError(domain: "IconDecomposerDocument",
                         code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No source image to save"])
        }

        return DocumentArchive(
            sourceImage: sourceImage,
            parameters: parameters,
            layers: layers,
            layerGroups: layerGroups
        )
    }

    func fileWrapper(snapshot: DocumentArchive, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(snapshot)
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Properties

    /// Original source image
    @Published var sourceImage: NSImage?

    /// Processing parameters used
    @Published var parameters = ProcessingParameters.default

    /// All extracted layers
    @Published private(set) var layers: [Layer] = []

    /// Organized layer groups (max 4 for .icon format)
    @Published var layerGroups: [LayerGroup] = []

    /// Processing state
    enum ProcessingState {
        case idle
        case processing
        case completed
        case failed(Error)
    }

    @Published var processingState: ProcessingState = .idle

    // MARK: - Initialization

    init() {
        self.sourceImage = nil
        self.parameters = ProcessingParameters.default
        self.layers = []
        self.layerGroups = []
        self.processingState = .idle
    }

    // MARK: - Public Methods

    /// Set source image and trigger processing
    func setSourceImage(_ image: NSImage) {
        self.sourceImage = image
    }

    /// Update layers after processing
    func updateLayers(_ newLayers: [Layer]) {
        self.layers = newLayers
        // Don't auto-group - let user manually organize layers
        self.layerGroups = []
    }

    /// Combine selected layers into one
    func combineSelectedLayers(in group: LayerGroup) {
        // TODO: Implement layer combination
    }

    /// Split a layer into sub-layers
    func splitLayer(_ layer: Layer) {
        // TODO: Implement layer splitting
    }

    // MARK: - Private Methods

    /// Auto-group layers into ≤4 groups for .icon export
    private func autoGroupLayers(_ layers: [Layer]) -> [LayerGroup] {
        guard !layers.isEmpty else { return [] }

        // Sort layers by size (largest first)
        let sortedLayers = layers.sorted { $0.pixelCount > $1.pixelCount }

        var groups: [LayerGroup] = []

        // Group 1: Largest layer (bottom, with glass effect)
        if let largest = sortedLayers.first {
            var effects = GroupEffects()
            effects.hasGlass = true
            effects.lighting = .individual

            groups.append(LayerGroup(
                name: "Background",
                layers: [largest],
                effects: effects
            ))
        }

        // Remaining layers distributed across up to 3 more groups
        let remainingLayers = Array(sortedLayers.dropFirst())
        if !remainingLayers.isEmpty {
            // Simple distribution: divide remaining into groups
            let groupCount = min(3, remainingLayers.count)
            let layersPerGroup = Int(ceil(Double(remainingLayers.count) / Double(groupCount)))

            for i in 0..<groupCount {
                let start = i * layersPerGroup
                let end = min(start + layersPerGroup, remainingLayers.count)
                if start < remainingLayers.count {
                    let groupLayers = Array(remainingLayers[start..<end])
                    groups.append(LayerGroup(
                        name: "Group \(i + 2)",
                        layers: groupLayers,
                        effects: GroupEffects()
                    ))
                }
            }
        }

        return groups
    }
}

// MARK: - Document Archive Structure

struct DocumentArchive: Codable {
    let sourceImageData: Data
    let parameters: ProcessingParameters
    let layers: [Layer]
    let layerGroups: [LayerGroup]

    var sourceImage: NSImage? {
        return NSImage(data: sourceImageData)
    }

    init(sourceImage: NSImage, parameters: ProcessingParameters, layers: [Layer], layerGroups: [LayerGroup]) {
        if let tiffData = sourceImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            self.sourceImageData = pngData
        } else {
            self.sourceImageData = Data()
        }

        self.parameters = parameters
        self.layers = layers
        self.layerGroups = layerGroups
    }
}
