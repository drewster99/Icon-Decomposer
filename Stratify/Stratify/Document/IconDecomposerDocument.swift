//
//  StratifyDocument.swift
//  Stratify
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
    static let stratifyProjectUTType = UTType(exportedAs: "com.nuclearcyborg.Stratify.project")
}

class StratifyDocument: ReferenceFileDocument, ObservableObject {

    // MARK: - ReferenceFileDocument

    static var readableContentTypes: [UTType] { [.stratifyProjectUTType] }
    static var writableContentTypes: [UTType] { [.stratifyProjectUTType] }

    // MARK: - Undo Support

    var undoManager: UndoManager?

    required init(configuration: ReadConfiguration) throws {
        self.sourceImage = nil
        self.depthMap = nil
        self.parameters = ProcessingParameters.default
        self.layers = []
        self.layerGroups = []
        self.processingState = .idle

        if let data = configuration.file.regularFileContents, !data.isEmpty {
            do {
                let decoder = PropertyListDecoder()
                // @unchecked Sendable DocumentArchive can be safely decoded off main actor
                let archive = try decoder.decode(DocumentArchive.self, from: data)

                self.sourceImage = archive.sourceImage
                self.depthMap = archive.depthMap
                self.parameters = archive.parameters
                self.layers = archive.layers
                self.layerGroups = archive.layerGroups
                self.processingState = .completed
            } catch {
                // If decoding fails (e.g., from autosave corruption), start with empty document
                print("Warning: Failed to decode document data: \(error.localizedDescription)")
                // Keep the default empty values initialized above
            }
        }
    }

    func snapshot(contentType: UTType) throws -> DocumentArchive {
        // Allow snapshots only when there's content to save
        // This prevents autosave errors for empty documents
        guard let sourceImage = sourceImage else {
            throw NSError(
                domain: "StratifyDocument",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No source image to save"]
            )
        }

        return DocumentArchive(
            sourceImage: sourceImage,
            depthMap: depthMap,
            parameters: parameters,
            layers: layers,
            layerGroups: layerGroups
        )
    }

    // Override to prevent autosaving empty documents
    var isInViewingMode: Bool {
        return sourceImage == nil
    }

    nonisolated func fileWrapper(snapshot: DocumentArchive, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(snapshot)
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Properties

    /// Original source image
    @Published var sourceImage: NSImage?

    /// Depth map computed from source image (cached)
    @Published var depthMap: NSImage?

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
        self.depthMap = nil
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
        let oldLayers = self.layers

        // Combine the two images by compositing at exact pixel dimensions using Core Graphics
        guard let cgTarget = target.cgImage,
              let cgSource = source.cgImage else { return }

        let width = cgTarget.width
        let height = cgTarget.height

        // Create CGContext for compositing
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Draw both images
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgTarget, in: rect)
        context.draw(cgSource, in: rect)

        // Get the combined CGImage
        guard let combinedCGImage = context.makeImage() else { return }

        // Convert to PNG data for storage
        let bitmapRep = NSBitmapImageRep(cgImage: combinedCGImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        // Create combined layer using new imageData-based initializer
        let combinedLayer = Layer(
            name: target.name,
            imageData: pngData,
            pixelWidth: width,
            pixelHeight: height,
            pixelCount: source.pixelCount + target.pixelCount,
            averageColor: target.averageColor
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

        // Start with first layer's CGImage
        guard var currentCGImage = firstLayer.cgImage else { return }
        var totalPixelCount = firstLayer.pixelCount

        let width = currentCGImage.width
        let height = currentCGImage.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        // Combine all selected layers using Core Graphics
        for layer in selectedLayers.dropFirst() {
            guard let layerCGImage = layer.cgImage else { continue }

            // Create CGContext for compositing
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { continue }

            // Draw current combined image and new layer
            context.draw(currentCGImage, in: rect)
            context.draw(layerCGImage, in: rect)

            // Get the new combined CGImage
            guard let newCombined = context.makeImage() else { continue }
            currentCGImage = newCombined
            totalPixelCount += layer.pixelCount
        }

        // Convert final CGImage to PNG data for storage
        let bitmapRep = NSBitmapImageRep(cgImage: currentCGImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }

        let combinedLayer = Layer(
            name: firstLayer.name,
            imageData: pngData,
            pixelWidth: width,
            pixelHeight: height,
            pixelCount: totalPixelCount,
            averageColor: firstLayer.averageColor
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

        print("============================================================")
        print("🔪 STARTING SPLIT LAYER")
        print("  Source layer: '\(layer.name)'")
        print("  Source pixels: \(layer.pixelCount) px")
        print("  Source LAB color: \(layer.averageColor)")
        print("============================================================")

        let oldLayers = self.layers

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

        // Step 1: Extract visible pixels directly from the layer
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProcessingError.processingFailed("Failed to get CGImage")
        }

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

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Composite semi-transparent/transparent pixels over white background
        // This ensures transparent pixels cluster as white instead of black (matches POC behavior)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(fullRect)
        context.draw(cgImage, in: fullRect)

        // Extract visible pixels (alpha > 10) with their colors and positions
        let extractStartTime = CFAbsoluteTimeGetCurrent()

        struct VisiblePixel {
            let index: Int
            let lab: SIMD3<Float>
            let position: SIMD2<Float>
        }

        var visiblePixels: [VisiblePixel] = []
        visiblePixels.reserveCapacity(layer.pixelCount)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = imageData[offset + 3]

                // Only include non-transparent pixels (skip mask artifacts)
                if alpha > 10 {
                    // BGRA format
                    let b = Float(imageData[offset + 0]) / 255.0
                    let g = Float(imageData[offset + 1]) / 255.0
                    let r = Float(imageData[offset + 2]) / 255.0

                    var lab = ProcessingCoordinator.rgbToLab(r, g, b)

                    // Apply same color adjustments as SLIC for consistency
                    lab.x *= self.parameters.lightnessWeight  // Scale L channel
                    if lab.y < 0.0 {
                        lab.y *= self.parameters.greenAxisScale  // Scale green axis
                    }

                    // Normalize spatial coordinates to [0, 1]
                    let normalizedX = Float(x) / Float(width)
                    let normalizedY = Float(y) / Float(height)

                    visiblePixels.append(VisiblePixel(
                        index: y * width + x,
                        lab: lab,
                        position: SIMD2<Float>(normalizedX, normalizedY)
                    ))
                }
            }
        }

        let extractEndTime = CFAbsoluteTimeGetCurrent()
        let extractDuration = (extractEndTime - extractStartTime) * 1000.0
        print("  Visible pixels extracted: \(visiblePixels.count) px (alpha > 10)")
        print("  ⏱️  Pixel extraction time: \(String(format: "%.1f", extractDuration))ms")

        // Guard against too few pixels to split
        guard visiblePixels.count >= 20 else {
            throw ProcessingError.processingFailed("Layer has too few visible pixels (\(visiblePixels.count)) to split")
        }

        // Step 2: Prepare features for K-means (colors + positions)
        let pixelColors = visiblePixels.map { $0.lab }
        let pixelPositions = visiblePixels.map { $0.position }

        // Step 3: Cluster visible pixels directly using K-means with spatial+color features
        let kmeansProcessor = try KMeansProcessor(
            device: device,
            library: library,
            commandQueue: commandQueue
        )

        // Try different spatial weights: 0.3, 0.5, 0.8
        // Pick the one with largest color difference (most distinct color separation)
        let spatialWeights: [Float] = [0.3, 0.5, 0.8]
        var candidateResults: [(weight: Float, layers: [Layer], colorDifference: Float)] = []
        var lastAttemptCount = 0

        for spatialWeight in spatialWeights {
            let colorWeight = 1.0 - spatialWeight

            // Run K-means directly on visible pixels (not superpixels)
            let kmeansStartTime = CFAbsoluteTimeGetCurrent()

            let clusteringResult = try kmeansProcessor.clusterWithSpatial(
                superpixelColors: pixelColors,
                superpixelPositions: pixelPositions,
                numberOfClusters: 2,
                colorWeight: colorWeight,
                spatialWeight: spatialWeight,
                maxIterations: 300,
                convergenceDistance: 0.01
            )

            let kmeansEndTime = CFAbsoluteTimeGetCurrent()
            let kmeansDuration = (kmeansEndTime - kmeansStartTime) * 1000.0
            print("  ⏱️  K-means (weight=\(spatialWeight)): \(String(format: "%.1f", kmeansDuration))ms")

            // Step 4: Map cluster assignments back to full image
            // Initialize all pixels as transparent (cluster assignment doesn't matter)
            var pixelClusters = [UInt32](repeating: 0, count: width * height)

            // Assign clusters only for visible pixels
            for (pixelIndex, visiblePixel) in visiblePixels.enumerated() {
                let clusterAssignment = clusteringResult.clusterAssignments[pixelIndex]
                let clusterId = clusterAssignment >= 0 ? UInt32(clusterAssignment) : 0
                pixelClusters[visiblePixel.index] = clusterId
            }

            // Step 5: Extract layers
            let extractLayersStartTime = CFAbsoluteTimeGetCurrent()

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

            let extractLayersEndTime = CFAbsoluteTimeGetCurrent()
            let extractLayersDuration = (extractLayersEndTime - extractLayersStartTime) * 1000.0
            print("  ⏱️  Layer extraction (GPU): \(String(format: "%.1f", extractLayersDuration))ms")

            // Step 6: Create Layer objects on main actor
            let attemptLayers = await MainActor.run { () -> [Layer] in
                var layers: [Layer] = []

                for (i, layerBuffer) in layerBuffers.enumerated() {
                    guard let layerCGImage = ProcessingCoordinator.createLayerCGImage(from: layerBuffer, width: width, height: height) else {
                        continue
                    }

                    let (pixelCount, avgColor) = ProcessingCoordinator.analyzeLayer(layerBuffer, width: width, height: height)

                    // Skip empty layers
                    guard pixelCount > 0 else { continue }

                    layers.append(Layer(
                        name: "\(layer.name) - Part \(i + 1)",
                        cgImage: layerCGImage,
                        pixelCount: pixelCount,
                        averageColor: avgColor
                    ))
                }

                return layers
            }

            lastAttemptCount = attemptLayers.count

            // If we got exactly 2 layers, calculate color difference and store as candidate
            if attemptLayers.count == 2 {
                let colorDifference = labDistance(attemptLayers[0].averageColor, attemptLayers[1].averageColor)
                candidateResults.append((weight: spatialWeight, layers: attemptLayers, colorDifference: colorDifference))

                // Debug output
                print("🔍 SPLIT DEBUG - Spatial weight: \(spatialWeight)")
                print("  Layer 1: \(attemptLayers[0].pixelCount) px, LAB: \(attemptLayers[0].averageColor)")
                print("  Layer 2: \(attemptLayers[1].pixelCount) px, LAB: \(attemptLayers[1].averageColor)")
                print("  Color distance: \(colorDifference)")
            } else {
                print("🔍 SPLIT DEBUG - Spatial weight: \(spatialWeight) - FAILED (produced \(attemptLayers.count) layers)")
            }
        }

        // Pick the candidate with largest color difference (most distinct colors)
        // This ensures we separate different color regions rather than splitting uniform areas
        guard let bestResult = candidateResults.max(by: { $0.colorDifference < $1.colorDifference }) else {
            throw ProcessingError.processingFailed("Split produced \(lastAttemptCount) layers instead of 2 after trying multiple strategies. The layer may not be splittable.")
        }

        print("✅ SPLIT SELECTED - Spatial weight: \(bestResult.weight), Color distance: \(bestResult.colorDifference)")

        let splitLayers = bestResult.layers

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

    /// Calculate Euclidean distance between two LAB colors
    private func labDistance(_ color1: SIMD3<Float>, _ color2: SIMD3<Float>) -> Float {
        let diff = color1 - color2
        return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
    }

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

struct DocumentArchive: @unchecked Sendable {
    let sourceImageData: Data
    let depthMapData: Data?
    let parameters: ProcessingParameters
    let layers: [Layer]
    let layerGroups: [LayerGroup]

    nonisolated var sourceImage: NSImage? {
        return NSImage(data: sourceImageData)
    }

    nonisolated var depthMap: NSImage? {
        guard let depthMapData = depthMapData else { return nil }
        return NSImage(data: depthMapData)
    }

    init(sourceImage: NSImage, depthMap: NSImage?, parameters: ProcessingParameters, layers: [Layer], layerGroups: [LayerGroup]) {
        if let tiffData = sourceImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            self.sourceImageData = pngData
        } else {
            self.sourceImageData = Data()
        }

        if let depthMap = depthMap,
           let tiffData = depthMap.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            self.depthMapData = pngData
        } else {
            self.depthMapData = nil
        }

        self.parameters = parameters
        self.layers = layers
        self.layerGroups = layerGroups
    }
}

// Explicit Codable conformance to avoid main-actor isolation inference
extension DocumentArchive: Codable {
    enum CodingKeys: String, CodingKey {
        case sourceImageData
        case depthMapData
        case parameters
        case layers
        case layerGroups
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceImageData = try container.decode(Data.self, forKey: .sourceImageData)
        depthMapData = try container.decodeIfPresent(Data.self, forKey: .depthMapData)
        parameters = try container.decode(ProcessingParameters.self, forKey: .parameters)
        layers = try container.decode([Layer].self, forKey: .layers)
        layerGroups = try container.decode([LayerGroup].self, forKey: .layerGroups)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceImageData, forKey: .sourceImageData)
        try container.encodeIfPresent(depthMapData, forKey: .depthMapData)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(layers, forKey: .layers)
        try container.encode(layerGroups, forKey: .layerGroups)
    }
}
