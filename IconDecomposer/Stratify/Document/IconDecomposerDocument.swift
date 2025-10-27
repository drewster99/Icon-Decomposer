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
import Metal
import ImageColorSegmentation

extension UTType {
    static let iconDecomposerProject = UTType(exportedAs: "com.nuclearcyborg.Stratify.project")
}

class IconDecomposerDocument: ReferenceFileDocument, ObservableObject {

    // MARK: - ReferenceFileDocument

    static var readableContentTypes: [UTType] { [.iconDecomposerProject] }

    // MARK: - Undo Support

    var undoManager: UndoManager?

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
    func setSourceImage(_ image: NSImage, actionName: String = "Change Source Image") {
        let oldImage = self.sourceImage

        undoManager?.registerUndo(withTarget: self) { target in
            if let old = oldImage {
                target.setSourceImage(old, actionName: actionName)
            } else {
                target.clearSourceImage(actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)

        self.sourceImage = image
    }

    /// Clear source image (for undo)
    private func clearSourceImage(actionName: String = "Clear Source Image") {
        let oldImage = self.sourceImage

        undoManager?.registerUndo(withTarget: self) { target in
            if let old = oldImage {
                target.setSourceImage(old, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)

        self.sourceImage = nil
        self.layers = []
        self.layerGroups = []
    }

    /// Update layers after processing
    func updateLayers(_ newLayers: [Layer], actionName: String = "Update Layers") {
        let oldLayers = self.layers
        let oldGroups = self.layerGroups

        undoManager?.registerUndo(withTarget: self) { target in
            target.updateLayers(oldLayers, actionName: actionName)
            target.layerGroups = oldGroups
        }
        undoManager?.setActionName(actionName)

        self.layers = newLayers
        // Don't auto-group - let user manually organize layers
        self.layerGroups = []
    }

    /// Combine two layers
    func combineLayers(source: Layer, target: Layer, actionName: String = "Combine Layers") {
        guard let sourceImage = source.image,
              let targetImage = target.image else { return }

        let oldLayers = self.layers

        // Combine the two images by compositing
        let size = sourceImage.size
        let combinedImage = NSImage(size: size)

        combinedImage.lockFocus()
        targetImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        sourceImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        combinedImage.unlockFocus()

        // Create combined layer
        let combinedLayer = Layer(
            name: target.name,
            image: combinedImage,
            pixelCount: source.pixelCount + target.pixelCount,
            averageColor: target.averageColor,
            isSelected: true
        )

        // Remove both source and target, add combined
        var newLayers = layers.filter { $0.id != source.id && $0.id != target.id }
        newLayers.append(combinedLayer)
        newLayers.sort { $0.pixelCount > $1.pixelCount }

        undoManager?.registerUndo(withTarget: self) { target in
            target.updateLayers(oldLayers, actionName: actionName)
        }
        undoManager?.setActionName(actionName)

        self.layers = newLayers
    }

    /// Combine selected layers into one
    func combineSelectedLayers(_ selectedIDs: Set<UUID>, actionName: String = "Combine Selected Layers") {
        guard selectedIDs.count >= 2 else { return }

        let selectedLayers = layers.filter { selectedIDs.contains($0.id) }
        guard let firstLayer = selectedLayers.first else { return }

        let oldLayers = self.layers

        // Combine all selected layers into the first one
        var combinedImage = firstLayer.image
        var totalPixelCount = firstLayer.pixelCount

        for layer in selectedLayers.dropFirst() {
            guard let layerImage = layer.image,
                  let combined = combinedImage else { continue }

            let size = combined.size
            let newCombined = NSImage(size: size)

            newCombined.lockFocus()
            combined.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
            layerImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
            newCombined.unlockFocus()

            combinedImage = newCombined
            totalPixelCount += layer.pixelCount
        }

        guard let finalImage = combinedImage else { return }

        let combinedLayer = Layer(
            name: firstLayer.name,
            image: finalImage,
            pixelCount: totalPixelCount,
            averageColor: firstLayer.averageColor,
            isSelected: true
        )

        // Remove all selected layers, add combined
        var newLayers = layers.filter { !selectedIDs.contains($0.id) }
        newLayers.append(combinedLayer)
        newLayers.sort { $0.pixelCount > $1.pixelCount }

        undoManager?.registerUndo(withTarget: self) { target in
            target.updateLayers(oldLayers, actionName: actionName)
        }
        undoManager?.setActionName(actionName)

        self.layers = newLayers
    }

    /// Split a layer into 2 sub-layers using spatial+color clustering
    func splitLayer(_ layerID: UUID, actionName: String = "Split Layer") async throws {
        guard let layer = layers.first(where: { $0.id == layerID }),
              let image = layer.image else {
            throw ProcessingError.processingFailed("Layer not found")
        }

        let oldLayers = self.layers
        let processingParams = self.parameters

        let width = Int(image.size.width)
        let height = Int(image.size.height)

        // Get Metal device and library
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProcessingError.metalNotAvailable
        }

        let metalResources = try await MetalResources(device: device)
        let library = metalResources.library
        guard let commandQueue = device.makeCommandQueue() else {
            throw ProcessingError.metalNotAvailable
        }

        // Step 1: Run SLIC segmentation
        let slicProcessor = try SLICProcessor(device: device, library: library)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProcessingError.processingFailed("Failed to get CGImage")
        }

        // Create texture from image
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let inputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ProcessingError.processingFailed("Failed to create texture")
        }

        // Copy image data to texture
        let bytesPerRow = width * 4
        var imageData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &imageData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ProcessingError.processingFailed("Failed to create context")
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        inputTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: imageData,
            bytesPerRow: bytesPerRow
        )

        // Run SLIC with split-specific parameters
        // Use fewer, larger superpixels since layer is sparse (mostly transparent)
        let slicResult = try slicProcessor.processSLIC(
            inputTexture: inputTexture,
            commandQueue: commandQueue,
            nSegments: 150,              // Fewer segments to concentrate on actual content
            compactness: 12.0,            // Lower compactness for irregular layer shapes
            greenAxisScale: processingParams.greenAxisScale,
            iterations: 10,
            enforceConnectivity: true
        )

        // Step 2: Extract superpixel features (color + spatial)
        let superpixelProcessor = try SuperpixelProcessor(
            device: device,
            library: library,
            commandQueue: commandQueue
        )

        let superpixelData = try superpixelProcessor.extractSuperpixelsMetal(
            from: slicResult.labBuffer,
            labelsBuffer: slicResult.labelsBuffer,
            width: width,
            height: height
        )

        let superpixelColors = SuperpixelProcessor.extractColorFeatures(from: superpixelData)
        let superpixelPositions = SuperpixelProcessor.extractSpatialFeatures(
            from: superpixelData,
            imageWidth: width,
            imageHeight: height
        )

        // Step 3: Cluster using spatial+color features (50/50 weighting)
        let kmeansProcessor = try KMeansProcessor(
            device: device,
            library: library,
            commandQueue: commandQueue
        )

        let clusteringResult = try kmeansProcessor.clusterWithSpatial(
            superpixelColors: superpixelColors,
            superpixelPositions: superpixelPositions,
            numberOfClusters: 2,
            colorWeight: 0.2,      // 20% color
            spatialWeight: 0.8,    // 80% spatial - emphasize position for splitting
            maxIterations: 300,
            convergenceDistance: 0.01
        )

        // Step 4: Map cluster assignments to pixels
        let labelsPointer = slicResult.labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        let labelMap = Array(UnsafeBufferPointer(start: labelsPointer, count: width * height))

        let pixelClusters = LayerExtractor.mapClustersToPixels(
            clusterAssignments: clusteringResult.clusterAssignments,
            superpixelData: superpixelData,
            labelMap: labelMap
        )

        // Step 5: Extract layers
        guard let originalImageBuffer = device.makeBuffer(
            bytes: imageData,
            length: width * height * 4,
            options: .storageModeShared
        ) else {
            throw ProcessingError.processingFailed("Failed to create image buffer")
        }

        let layerExtractor = try LayerExtractor(
            device: device,
            library: library,
            commandQueue: commandQueue
        )

        let layerBuffers = try layerExtractor.extractLayersGPU(
            originalImageBuffer: originalImageBuffer,
            pixelClusters: pixelClusters,
            numberOfClusters: 2,
            width: width,
            height: height
        )

        // Step 6: Create Layer objects on main actor
        let splitLayers = await MainActor.run { () -> [Layer] in
            var layers: [Layer] = []

            for (i, layerBuffer) in layerBuffers.enumerated() {
                guard let layerImage = ProcessingCoordinator.createLayerImage(from: layerBuffer, width: width, height: height) else {
                    continue
                }

                let (pixelCount, avgColor) = ProcessingCoordinator.analyzeLayer(layerBuffer, width: width, height: height)

                // Skip empty layers
                guard pixelCount > 0 else { continue }

                layers.append(Layer(
                    name: "\(layer.name) - Part \(i + 1)",
                    image: layerImage,
                    pixelCount: pixelCount,
                    averageColor: avgColor,
                    isSelected: false
                ))
            }

            return layers
        }

        // Verify we got exactly 2 non-empty layers
        guard splitLayers.count == 2 else {
            throw ProcessingError.processingFailed("Split produced \(splitLayers.count) layers instead of 2. The layer may not be splittable using current parameters.")
        }

        await MainActor.run {
            // Remove original layer and add split layers
            var newLayers = self.layers.filter { $0.id != layerID }
            newLayers.append(contentsOf: splitLayers)
            newLayers.sort { $0.pixelCount > $1.pixelCount }

            self.undoManager?.registerUndo(withTarget: self) { target in
                target.updateLayers(oldLayers, actionName: actionName)
            }
            self.undoManager?.setActionName(actionName)

            self.layers = newLayers
        }
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
