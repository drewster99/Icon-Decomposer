//
//  DocumentView.swift
//  IconDecomposer
//
//  Main document window view
//

import SwiftUI
import UniformTypeIdentifiers
import ImageColorSegmentation

struct DocumentView: View {
    @ObservedObject var document: IconDecomposerDocument

    @State private var isProcessing = false
    @State private var selectedLayerIDs = Set<UUID>()

    var body: some View {
        HSplitView {
            // Left: Original image preview
            VStack {
                Text("Original Icon")
                    .font(.headline)
                    .padding(.top)

                if let sourceImage = document.sourceImage {
                    // Perfect square container
                    GeometryReader { geometry in
                        let size = min(min(geometry.size.width, geometry.size.height), 512)

                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(nsImage: sourceImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: size, height: size)
                                    .background(CheckerboardBackground())
                                    .border(Color.secondary.opacity(0.3))
                                    .onTapGesture(count: 2) {
                                        openIconInWindow(sourceImage)
                                    }
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    .frame(minWidth: 256, maxWidth: 512)
                } else {
                    // Import screen
                    ImportIconView { selectedImage in
                        document.setSourceImage(selectedImage)
                        // Automatically analyze after import
                        analyzeIcon()
                    }
                }

                if isProcessing {
                    ProgressView("Processing...")
                        .padding()
                }

                Spacer()

                // Action buttons
                if document.sourceImage != nil {
                    HStack {
                        Button("Import New Icon") {
                            importIcon()
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 256, maxWidth: 512)

            // Right: Layers
            VStack(alignment: .leading, spacing: 0) {
                Text("Layers")
                    .font(.headline)
                    .padding()

                if document.layers.isEmpty {
                    ContentUnavailableView {
                        Label("No Layers Yet", systemImage: "square.stack.3d.down.forward")
                    } description: {
                        Text("Import an icon to decompose it into layers")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Instruction text
                    Text("Drag layers onto each other to combine them")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    ScrollView {
                        LayerFlowGrid(
                            layers: document.layers,
                            selectedLayerIDs: selectedLayerIDs,
                            onToggle: { id in
                                toggleLayerSelection(id)
                            },
                            onDrop: { source, target in
                                combineLayers(source: source, target: target)
                            }
                        )
                        .padding()
                    }

                    Divider()

                    // Layer management buttons
                    HStack {
                        Button("Auto-Merge Layers") {
                            autoMergeLayers()
                        }

                        Button("Combine Selected") {
                            combineSelectedLayers()
                        }
                        .disabled(selectedLayerIDs.count < 2)

                        Button("Split Layer") {
                            splitSelectedLayer()
                        }
                        .disabled(selectedLayerIDs.count != 1)

                        Spacer()

                        Button("Export...") {
                            exportIconBundle()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(document.layers.isEmpty)
                    }
                    .padding()
                }
            }
            .frame(minWidth: 500)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Actions

    private func importIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Select an icon image (1024×1024 recommended)"

        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                document.setSourceImage(image)
            }
        }
    }

    private func analyzeIcon() {
        guard let sourceImage = document.sourceImage else { return }

        isProcessing = true

        Task {
            do {
                let layers = try await ProcessingCoordinator.processIcon(
                    sourceImage,
                    parameters: document.parameters
                )

                await MainActor.run {
                    document.updateLayers(layers)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    print("Processing error: \(error)")
                    // For now, use dummy layers until package is integrated
                    let dummyLayers = createDummyLayers(from: sourceImage)
                    document.updateLayers(dummyLayers)
                    isProcessing = false
                }
            }
        }
    }

    private func toggleLayerSelection(_ id: UUID) {
        if selectedLayerIDs.contains(id) {
            selectedLayerIDs.remove(id)
        } else {
            selectedLayerIDs.insert(id)
        }
    }

    private func openIconInWindow(_ image: NSImage) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 512, height: 512),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Original Icon"
        window.contentView = NSHostingView(rootView:
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(CheckerboardBackground())
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func autoMergeLayers() {
        guard let sourceImage = document.sourceImage else { return }

        isProcessing = true

        Task {
            do {
                // Re-run processing with auto-merge enabled
                let mergeParams = document.parameters
                // Use the auto-merge pipeline
                let labScale = LABScale(
                    l: mergeParams.lightnessWeight,
                    a: 1.0,
                    b: mergeParams.greenAxisScale
                )

                let pipeline = try ImagePipeline()
                    .convertColorSpace(to: .lab, scale: labScale)
                    .segment(
                        superpixels: mergeParams.numberOfSegments,
                        compactness: mergeParams.compactness
                    )
                    .cluster(into: mergeParams.numberOfClusters)
                    .autoMerge(threshold: mergeParams.autoMergeThreshold)
                    .extractLayers()

                let result = try await pipeline.execute(input: sourceImage)

                // Extract layers (reuse logic from ProcessingCoordinator)
                guard let clusterCount: Int = result.metadata(for: "clusterCount") else {
                    throw ProcessingError.processingFailed("No cluster count in result")
                }

                let width = Int(sourceImage.size.width)
                let height = Int(sourceImage.size.height)

                var layers: [Layer] = []

                for i in 0..<clusterCount {
                    guard let layerBuffer = result.buffer(named: "layer_\(i)"),
                          let layerImage = ProcessingCoordinator.createLayerImage(from: layerBuffer, width: width, height: height) else {
                        continue
                    }

                    let (pixelCount, avgColor) = ProcessingCoordinator.analyzeLayer(layerBuffer, width: width, height: height)

                    layers.append(Layer(
                        name: "Layer \(i + 1)",
                        image: layerImage,
                        pixelCount: pixelCount,
                        averageColor: avgColor,
                        isSelected: true
                    ))
                }

                layers.sort { $0.pixelCount > $1.pixelCount }
                for (index, layer) in layers.enumerated() {
                    var updatedLayer = layer
                    updatedLayer.name = "Layer \(index + 1)"
                    layers[index] = updatedLayer
                }

                await MainActor.run {
                    document.updateLayers(layers)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    print("Auto-merge error: \(error)")
                    isProcessing = false
                }
            }
        }
    }

    private func combineLayers(source: Layer, target: Layer) {
        guard let sourceImage = source.image,
              let targetImage = target.image else { return }

        // Combine the two images by compositing
        let size = sourceImage.size
        let combinedImage = NSImage(size: size)

        combinedImage.lockFocus()
        targetImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        sourceImage.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
        combinedImage.unlockFocus()

        // Create combined layer
        let combinedLayer = Layer(
            name: target.name, // Keep target's name
            image: combinedImage,
            pixelCount: source.pixelCount + target.pixelCount,
            averageColor: target.averageColor, // Use target's color
            isSelected: true
        )

        // Remove both source and target, add combined
        var newLayers = document.layers.filter { $0.id != source.id && $0.id != target.id }
        newLayers.append(combinedLayer)
        newLayers.sort { $0.pixelCount > $1.pixelCount }

        document.updateLayers(newLayers)
        selectedLayerIDs.remove(source.id)
        selectedLayerIDs.remove(target.id)
    }

    private func combineSelectedLayers() {
        guard selectedLayerIDs.count >= 2 else { return }

        let selectedLayers = document.layers.filter { selectedLayerIDs.contains($0.id) }
        guard let firstLayer = selectedLayers.first else { return }

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
        var newLayers = document.layers.filter { !selectedLayerIDs.contains($0.id) }
        newLayers.append(combinedLayer)
        newLayers.sort { $0.pixelCount > $1.pixelCount }

        document.updateLayers(newLayers)
        selectedLayerIDs.removeAll()
    }

    private func splitSelectedLayer() {
        // TODO: Implement layer splitting
    }

    private func exportIconBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.folder]
        panel.nameFieldStringValue = "Icon.icon"
        panel.message = "Choose where to save the .icon bundle"

        if panel.runModal() == .OK, let _ = panel.url {
            // TODO: Export .icon bundle
        }
    }

    // MARK: - Helpers

    private func createDummyLayers(from image: NSImage) -> [Layer] {
        // Temporary placeholder until we integrate processing
        return [
            Layer(name: "Layer 1", image: image, pixelCount: 1000000, averageColor: SIMD3<Float>(50, 0, 0)),
            Layer(name: "Layer 2", image: image, pixelCount: 500000, averageColor: SIMD3<Float>(70, 10, -10)),
            Layer(name: "Layer 3", image: image, pixelCount: 250000, averageColor: SIMD3<Float>(30, -5, 15))
        ]
    }
}

#Preview {
    DocumentView(document: IconDecomposerDocument())
}
