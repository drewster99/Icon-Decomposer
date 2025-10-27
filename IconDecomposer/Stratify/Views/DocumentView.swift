//
//  DocumentView.swift
//  Stratify
//
//  Main document window view
//

import SwiftUI
import UniformTypeIdentifiers
import ImageColorSegmentation

struct DocumentView: View {
    @ObservedObject var document: StratifyDocument
    @Environment(\.undoManager) var undoManager

    @State private var isProcessing = false
    @State private var selectedLayerIDs = Set<UUID>()
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        HSplitView {
            // Left: Original image preview
            VStack {
                Text(document.sourceImage == nil ? "Import your PNG or JPG icon file to get started" : "Original Icon")
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

                    // Parameters section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Processing parameters")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Initial layers:")
                                    .font(.caption)
                                    .frame(width: 100, alignment: .leading)

                                Slider(value: Binding(
                                    get: { Double(document.parameters.numberOfClusters) },
                                    set: { document.parameters.numberOfClusters = Int($0) }
                                ), in: 5...20, step: 1)
                                .frame(maxWidth: 150)

                                Text("\(document.parameters.numberOfClusters)")
                                    .font(.caption)
                                    .frame(width: 25, alignment: .trailing)
                            }

                            Button("Re-analyze") {
                                analyzeIcon()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isProcessing)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                } else {
                    // Import screen
                    ImportIconView { selectedImage in
                        document.setSourceImage(selectedImage, actionName: "Import Icon")
                        // Automatically analyze after import
                        analyzeIcon()
                    }
                }

                Spacer()
            }
            .frame(minWidth: 256, maxWidth: 512)

            // Right: Layers
            VStack(alignment: .leading, spacing: 0) {
                Text("Layers")
                    .font(.headline)
                    .padding()

                ZStack {
                    if document.layers.isEmpty {
                        ContentUnavailableView {
                            Label("No Layers Yet", systemImage: "square.stack.3d.down.forward")
                        } description: {
                            Text("Import an icon to decompose it into layers")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {

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

                            Spacer()
                            
                            // Instruction text
                            Text("Drag layers onto each other to combine them, or use the tools below:")
                                .font(.callout)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                            Divider()

                            // Layer management buttons
                            HStack {
                                Button("Auto-Merge Layers") {
                                    Task {
                                        await autoMergeLayers()
                                    }
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

                                // Undo/Redo buttons
                                Button(action: { undoManager?.undo() }) {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .disabled(!(undoManager?.canUndo ?? false))
                                .help("Undo")

                                Button(action: { undoManager?.redo() }) {
                                    Image(systemName: "arrow.uturn.forward")
                                }
                                .disabled(!(undoManager?.canRedo ?? false))
                                .help("Redo")

                                Button("Export...") {
                                    exportIconBundle()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(document.layers.isEmpty)
                            }
                            .padding()
                        }
                    }

                    // Processing overlay
                    if isProcessing {
                        ZStack {
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()

                            VStack(spacing: 20) {
                                ProgressView()
                                    .scaleEffect(2.0)
                                    .progressViewStyle(.circular)

                                Text("Processing...")
                                    .font(.title2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                            }
                            .padding(40)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                            )
                            .shadow(radius: 20)
                        }
                    }
                }
            }
            .frame(minWidth: 500)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            document.undoManager = undoManager

            // Check for pending image from welcome screen
            if let pendingImage = WelcomeWindow.pendingImage {
                WelcomeWindow.pendingImage = nil  // Clear it
                document.setSourceImage(pendingImage, actionName: "Import Icon")
                analyzeIcon()
            }
        }
        .alert("Split Layer Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Actions

    private func importIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Select an icon image (1024×1024 recommended)"

        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                document.setSourceImage(image, actionName: "Import Icon")
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
                    document.updateLayers(layers, actionName: "Analyze Icon")
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    print("Processing error: \(error)")
                    // For now, use dummy layers until package is integrated
                    let dummyLayers = createDummyLayers(from: sourceImage)
                    document.updateLayers(dummyLayers, actionName: "Analyze Icon")
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

    @MainActor
    private func autoMergeLayers() async {
        isProcessing = true

        // Yield to allow UI update
        await Task.yield()

        // Merge existing layers based on color similarity
        let threshold = document.parameters.autoMergeThreshold
        var layersToMerge = document.layers

        guard !layersToMerge.isEmpty else {
            isProcessing = false
            return
        }

        // Calculate LAB color distance between all pairs of layers
        func labDistance(_ color1: SIMD3<Float>, _ color2: SIMD3<Float>) -> Float {
            let diff = color1 - color2
            return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
        }

        // Apply weighting to LAB color (lightness reduction + green axis scaling)
        func applyWeighting(_ color: SIMD3<Float>, lightnessWeight: Float, greenAxisScale: Float) -> SIMD3<Float> {
            var a = color.y
            // Apply green axis scaling to negative 'a' values
            if a < 0 {
                a *= greenAxisScale
            }
            return SIMD3<Float>(color.x * lightnessWeight, a, color.z)
        }

        // Calculate weighted distance
        func weightedDistance(_ color1: SIMD3<Float>, _ color2: SIMD3<Float>, lightnessWeight: Float, greenAxisScale: Float) -> Float {
            let weighted1 = applyWeighting(color1, lightnessWeight: lightnessWeight, greenAxisScale: greenAxisScale)
            let weighted2 = applyWeighting(color2, lightnessWeight: lightnessWeight, greenAxisScale: greenAxisScale)
            return labDistance(weighted1, weighted2)
        }

        // Keep merging until no more similar layers found
        var didMerge = true
        while didMerge {
            didMerge = false

            // Find the most similar pair of layers
            var minDistance = Float.infinity
            var mergeIndices: (Int, Int)?

            for i in 0..<layersToMerge.count {
                for j in (i+1)..<layersToMerge.count {
                    let distance = labDistance(
                        layersToMerge[i].averageColor,
                        layersToMerge[j].averageColor
                    )
                    if distance < minDistance {
                        minDistance = distance
                        mergeIndices = (i, j)
                    }
                }
            }

            // If we found a pair within threshold, merge them
            if let (i, j) = mergeIndices, minDistance < threshold {
                let layer1 = layersToMerge[i]
                let layer2 = layersToMerge[j]

                // Combine the images
                guard let image1 = layer1.image,
                      let image2 = layer2.image else { continue }

                let size = image1.size
                let combinedImage = NSImage(size: size)

                combinedImage.lockFocus()
                image1.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
                image2.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .sourceOver, fraction: 1.0)
                combinedImage.unlockFocus()

                // Create merged layer (keep first layer's name, combine pixel counts)
                let mergedLayer = Layer(
                    name: layer1.name,
                    image: combinedImage,
                    pixelCount: layer1.pixelCount + layer2.pixelCount,
                    averageColor: layer1.averageColor,  // Use larger layer's color
                    isSelected: false
                )

                // Remove both layers and add merged layer
                layersToMerge.remove(at: j)  // Remove higher index first
                layersToMerge.remove(at: i)
                layersToMerge.append(mergedLayer)

                didMerge = true

                // Yield to allow UI updates
                await Task.yield()
            }
        }

        // Sort by pixel count and renumber
        layersToMerge.sort { $0.pixelCount > $1.pixelCount }
        for (index, layer) in layersToMerge.enumerated() {
            var updatedLayer = layer
            updatedLayer.name = "Layer \(index + 1)"
            layersToMerge[index] = updatedLayer
        }

        // Update document
        document.updateLayers(layersToMerge, actionName: "Auto-Merge Layers")
        isProcessing = false
    }

    private func combineLayers(source: Layer, target: Layer) {
        document.combineLayers(source: source, target: target)
        selectedLayerIDs.remove(source.id)
        selectedLayerIDs.remove(target.id)
    }

    private func combineSelectedLayers() {
        document.combineSelectedLayers(selectedLayerIDs)
        selectedLayerIDs.removeAll()
    }

    private func splitSelectedLayer() {
        guard selectedLayerIDs.count == 1,
              let layerID = selectedLayerIDs.first else { return }

        Task {
            do {
                try await document.splitLayer(layerID)
                selectedLayerIDs.removeAll()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
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
    DocumentView(document: StratifyDocument())
}
