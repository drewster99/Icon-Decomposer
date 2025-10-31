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
    @Environment(\.openWindow) private var openWindow

    @State private var isProcessing = false
    @State private var selectedLayerIDs = Set<UUID>()
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var debugTransparency = false

    #if DEBUG
    @State private var useDepthForProcessing = false
    #endif

    var body: some View {
        HSplitView {
            // Left: Original image preview
            VStack(spacing: 0) {
                // Header - always visible
                Text(document.sourceImage == nil ? "Import your PNG or JPG icon file to get started" : "Original Icon")
                    .font(.headline)
                    .padding(.top)
                    .padding(.bottom, 8)

                if let sourceImage = document.sourceImage {
                    // Scrollable content area
                    ScrollView {
                        VStack(spacing: 16) {
                            #if DEBUG
                            // Show both original and depth map vertically
                            // Original image
                            VStack(spacing: 8) {
                                Text("Original")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                // Square container for image
                                ZStack {
                                    Image(nsImage: sourceImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .background(CheckerboardBackground())
                                        .border(Color.secondary.opacity(0.3))
                                        .onTapGesture(count: 2) {
                                            openIconInWindow(sourceImage)
                                        }
                                        .help("Double-click to view at full size")
                                }
                                .frame(width: 259, height: 259)
                                .clipped()

                                Text("Double-click to enlarge")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // Depth map
                            VStack(spacing: 8) {
                                Text("Depth Map")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                // Square container for depth map
                                ZStack {
                                    if let depthMap = document.depthMap {
                                        Image(nsImage: depthMap)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .border(Color.secondary.opacity(0.3))
                                            .onTapGesture(count: 2) {
                                                openIconInWindow(depthMap)
                                            }
                                            .help("Double-click to view at full size")
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.1))
                                            .overlay(
                                                Text("Computing...")
                                                    .foregroundColor(.secondary)
                                            )
                                    }
                                }
                                .frame(width: 259, height: 259)
                                .clipped()

                                Text("Closer = Brighter")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            // Toggle for using depth map
                            Toggle("Use Depth Map for Processing", isOn: $useDepthForProcessing)
                                .help("When enabled, uses depth map instead of original image for layer extraction")
                                .onChange(of: useDepthForProcessing) { _, _ in
                                    // Clear layers when toggling to force reprocessing
                                    if !document.layers.isEmpty {
                                        document.updateLayers([], actionName: "Clear Layers")
                                    }
                                }
                            #else
                            // Release mode: just show original
                            VStack(spacing: 8) {
                                Image(nsImage: sourceImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 512, maxHeight: 512)
                                    .background(CheckerboardBackground())
                                    .border(Color.secondary.opacity(0.3))
                                    .onTapGesture(count: 2) {
                                        openIconInWindow(sourceImage)
                                    }
                                    .help("Double-click to view at full size")

                                Text("Double-click to enlarge")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            #endif
                        }
                        .padding()
                    }

                    // Parameters section - always visible at bottom
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

                            #if DEBUG
                            HStack {
                                Text("Depth weight:")
                                    .font(.caption)
                                    .frame(width: 100, alignment: .leading)

                                Slider(value: $document.parameters.depthWeightSLIC, in: 0...1, step: 0.05)
                                .frame(maxWidth: 150)
                                .disabled(document.depthMap == nil)
                                .onChange(of: document.parameters.depthWeightSLIC) { _, _ in
                                    // Recalculate as user drags slider
                                    if !document.layers.isEmpty {
                                        analyzeIcon()
                                    }
                                }

                                Text(String(format: "%.2f", document.parameters.depthWeightSLIC))
                                    .font(.caption)
                                    .frame(width: 25, alignment: .trailing)
                            }
                            .help("Weight of depth data in SLIC segmentation (0 = ignore, 1 = full weight)")
                            #endif

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
                    .padding(.bottom)
                } else {
                    // Import screen
                    ImportIconView { selectedImage in
                        document.setSourceImage(selectedImage, actionName: "Import Icon")
                        // Automatically analyze after import
                        analyzeIcon()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(minWidth: 276, maxWidth: document.sourceImage == nil ? 512 : 276)
            .animation(.easeInOut(duration: 0.3), value: document.sourceImage != nil)

            // Right: Layers
            VStack(alignment: .leading, spacing: 0) {
                // Header - always visible
                Text("Layers")
                    .font(.headline)
                    .padding(.top)
                    .padding(.bottom, 8)
                    .padding(.horizontal)

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
                            // Layer grid (has its own internal ScrollView)
                            LayerFlowGrid(
                                layers: document.layers,
                                selectedLayerIDs: selectedLayerIDs,
                                onToggle: { id in
                                    toggleLayerSelection(id)
                                },
                                onDrop: { source, target in
                                    combineLayers(source: source, target: target)
                                },
                                debugTransparency: debugTransparency
                            )
                            .layoutPriority(1)

                            // Instruction text
                            Text("Drag layers onto each other to combine them, or use the tools below:")
                                .font(.callout)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                                .padding(.top, 8)

                            // Bottom buttons section - always visible
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

                                #if DEBUG
                                Button(debugTransparency ? "Hide Transparency" : "Show Transparency") {
                                    debugTransparency.toggle()
                                }
                                .help("Debug: Show fully transparent pixels as green, partial transparency as opaque")

                                Button("Print Pixels") {
                                    printSelectedLayerPixels()
                                }
                                .disabled(selectedLayerIDs.count != 1)
                                .help("Debug: Print RGBA values for selected layer")

                                Button("Test Depth") {
                                    testDepthEstimation()
                                }
                                .disabled(document.sourceImage == nil)
                                .help("Debug: Estimate depth from source image")
                                #endif

                                Spacer()

                                // Undo/Redo buttons
                                Button(action: { undoManager?.undo() },
                                       label: {
                                    Image(systemName: "arrow.uturn.backward")
                                })
                                .disabled(!(undoManager?.canUndo ?? false))
                                .help("Undo")

                                Button(action: { undoManager?.redo() }, label: {
                                    Image(systemName: "arrow.uturn.forward")
                                })
                                .disabled(!(undoManager?.canRedo ?? false))
                                .help("Redo")

                                Button("Export...") {
                                    exportIconBundle()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(document.layers.isEmpty)

                                Button("Export for AI Analysis...") {
                                    exportForAIAnalysis()
                                }
                                .buttonStyle(.bordered)
                                .disabled(document.layers.isEmpty || document.sourceImage == nil)
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
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            document.undoManager = undoManager

            // Check for pending image from welcome screen
            if let pendingImage = WelcomeWindow.pendingImage {
                WelcomeWindow.pendingImage = nil  // Clear it
                document.setSourceImage(pendingImage, actionName: "Import Icon")
                #if DEBUG
                computeDepthMap()
                #endif
                analyzeIcon()
            }
        }
        #if DEBUG
        .onChange(of: document.sourceImage) { _, newImage in
            if newImage != nil {
                computeDepthMap()
            } else {
                document.depthMap = nil
            }
        }
        #endif
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
        #if DEBUG
        let imageToProcess: NSImage?
        if useDepthForProcessing, let depthMap = document.depthMap {
            imageToProcess = depthMap
            print("🧪 Processing using DEPTH MAP instead of original image")
        } else {
            imageToProcess = document.sourceImage
        }
        guard let imageToProcess = imageToProcess else { return }
        #else
        guard let imageToProcess = document.sourceImage else { return }
        #endif

        isProcessing = true

        Task {
            do {
                let layers = try await ProcessingCoordinator.processIcon(
                    imageToProcess,
                    parameters: document.parameters,
                    depthMap: document.depthMap
                )

                await MainActor.run {
                    document.updateLayers(layers, actionName: "Analyze Icon")
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    print("Processing error: \(error)")
                    // For now, use dummy layers until package is integrated
                    let dummyLayers = createDummyLayers(from: imageToProcess)
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
        // Create independent copy to ensure window has its own reference
        guard let imageCopy = image.copy() as? NSImage else { return }

        // Store the image and open the window
        OriginalIconStore.shared.currentImage = imageCopy
        openWindow(id: "original-icon")
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

                // Combine the images at exact pixel dimensions using Core Graphics
                guard let cgImage1 = layer1.cgImage,
                      let cgImage2 = layer2.cgImage else { continue }

                let width = cgImage1.width
                let height = cgImage1.height

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

                // Draw both images
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.draw(cgImage1, in: rect)
                context.draw(cgImage2, in: rect)

                // Get the combined CGImage
                guard let combinedCGImage = context.makeImage() else { continue }

                // Convert to PNG data for storage
                let bitmapRep = NSBitmapImageRep(cgImage: combinedCGImage)
                guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { continue }

                // Create merged layer (keep first layer's name, combine pixel counts)
                let mergedLayer = Layer(
                    name: layer1.name,
                    imageData: pngData,
                    pixelWidth: width,
                    pixelHeight: height,
                    pixelCount: layer1.pixelCount + layer2.pixelCount,
                    averageColor: layer1.averageColor  // Use larger layer's color
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
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let bundleURL = panel.url {
            guard let sourceImage = document.sourceImage else { return }

            do {
                // Use layer groups if available, otherwise export individual layers
                if !document.layerGroups.isEmpty {
                    try IconBundleExporter.exportIconBundleWithGroups(
                        layerGroups: document.layerGroups,
                        sourceImage: sourceImage,
                        to: bundleURL
                    )
                } else {
                    try IconBundleExporter.exportIconBundle(
                        layers: document.layers,
                        sourceImage: sourceImage,
                        to: bundleURL
                    )
                }

                // Show success notification
                let alert = NSAlert()
                alert.messageText = "Export Successful"
                alert.informativeText = "Icon bundle saved to:\n\(bundleURL.path)"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                }
            } catch {
                // Show error alert
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func exportForAIAnalysis() {
        guard let sourceImage = document.sourceImage else {
            return
        }

        let result = AIAnalysisExporter.exportForAIAnalysis(
            sourceImage: sourceImage,
            layers: document.layers
        )

        switch result {
        case .success:
            // Show success notification
            let alert = NSAlert()
            alert.messageText = "AI Analysis Export Successful"
            alert.informativeText = "Diagnostic image saved successfully"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .cancelled:
            // User cancelled - no alert needed
            break

        case .failed(let error):
            // Show error alert
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Helpers

    #if DEBUG
    private func printSelectedLayerPixels() {
        guard let selectedID = selectedLayerIDs.first,
              let layer = document.layers.first(where: { $0.id == selectedID }),
              let image = layer.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("❌ Could not get layer image")
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ Could not create context")
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            print("❌ Could not get pixel data")
            return
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: totalPixels * 4)

        // Analyze alpha distribution
        var alphaHistogram: [UInt8: Int] = [:]
        var nonZeroAlphaPixels: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = []

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = pixels[offset]
                let g = pixels[offset + 1]
                let b = pixels[offset + 2]
                let a = pixels[offset + 3]

                alphaHistogram[a, default: 0] += 1

                if a > 0 && nonZeroAlphaPixels.count < 20 {
                    nonZeroAlphaPixels.append((x, y, r, g, b, a))
                }
            }
        }

        print("============================================================")
        print("🔍 PIXEL ANALYSIS: '\(layer.name)'")
        print("  Dimensions: \(width)×\(height) = \(totalPixels) total pixels")
        print("  Layer reports: \(layer.pixelCount) non-transparent pixels")
        print("")
        print("📊 ALPHA HISTOGRAM:")
        let sortedAlpha = alphaHistogram.keys.sorted()
        for alpha in sortedAlpha {
            // swiftlint:disable:next force_unwrapping
            let count = alphaHistogram[alpha]!
            let percentage = Double(count) / Double(totalPixels) * 100.0
            print("  Alpha \(String(format: "%3d", alpha)): \(String(format: "%7d", count)) pixels (\(String(format: "%5.2f", percentage))%)")
        }
        print("")
        print("📝 SAMPLE NON-TRANSPARENT PIXELS (first 20):")
        for sample in nonZeroAlphaPixels {
            print("  [\(sample.x), \(sample.y)]: R=\(sample.r) G=\(sample.g) B=\(sample.b) A=\(sample.a)")
        }
        print("============================================================")
    }

    private func computeDepthMap() {
        guard let sourceImage = document.sourceImage else {
            return
        }

        Task {
            do {
                let estimator = try DepthEstimator()
                let startTime = CFAbsoluteTimeGetCurrent()
                let depth = try estimator.estimateDepth(from: sourceImage)
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

                print("🧪 Depth map computed in \(String(format: "%.1f", duration))ms")

                await MainActor.run {
                    self.document.depthMap = depth
                }
            } catch {
                print("❌ Depth computation failed: \(error.localizedDescription)")
            }
        }
    }

    private func testDepthEstimation() {
        guard let sourceImage = document.sourceImage else {
            return
        }

        print("============================================================")
        print("🧪 TESTING DEPTH ESTIMATION")
        print("  Source image: \(sourceImage.size.width)×\(sourceImage.size.height)")

        Task {
            do {
                let estimator = try DepthEstimator()
                let startTime = CFAbsoluteTimeGetCurrent()
                let depthResult = try estimator.estimateDepthValues(from: sourceImage)
                let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

                // Analyze depth value range
                let minDepth = depthResult.depths.min() ?? 0
                let maxDepth = depthResult.depths.max() ?? 1
                let avgDepth = depthResult.depths.reduce(0, +) / Float(depthResult.depths.count)

                print("  ✅ Depth estimation completed in \(String(format: "%.1f", duration))ms")
                print("  Depth map: \(depthResult.width)×\(depthResult.height)")
                print("  Depth range: \(String(format: "%.4f", minDepth)) to \(String(format: "%.4f", maxDepth))")
                print("  Average depth: \(String(format: "%.4f", avgDepth))")
                print("============================================================")

                // Create NSImage for display
                let depth = try estimator.estimateDepth(from: sourceImage)

                await MainActor.run {
                    self.document.depthMap = depth
                }
            } catch {
                print("  ❌ Depth estimation failed: \(error.localizedDescription)")
                print("============================================================")
            }
        }
    }
    #endif

    private func createDummyLayers(from image: NSImage) -> [Layer] {
        // Temporary placeholder until we integrate processing
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return [
            Layer(name: "Layer 1", cgImage: cgImage, pixelCount: 1000000, averageColor: SIMD3<Float>(50, 0, 0)),
            Layer(name: "Layer 2", cgImage: cgImage, pixelCount: 500000, averageColor: SIMD3<Float>(70, 10, -10)),
            Layer(name: "Layer 3", cgImage: cgImage, pixelCount: 250000, averageColor: SIMD3<Float>(30, -5, 15))
        ]
    }

    #if DEBUG
    /// Transform layer image to visualize transparency:
    /// - Fully transparent pixels (alpha = 0) → green with 0.5 alpha
    /// - Partially transparent pixels → make fully opaque
    static func debugVisualizeTransparency(_ image: NSImage?) -> NSImage? {
        guard let image = image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let width = cgImage.width
        let height = cgImage.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Draw original image
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get pixel data
        guard let data = context.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Transform pixels
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let a = pixels[offset + 3]

                if a == 0 {
                    // Fully transparent → green with 0.5 alpha
                    pixels[offset] = 0      // R
                    pixels[offset + 1] = 255  // G
                    pixels[offset + 2] = 0    // B
                    pixels[offset + 3] = 128  // A (0.5)
                } else if a < 255 {
                    // Partially transparent → make fully opaque
                    pixels[offset + 3] = 255
                }
            }
        }

        guard let outputCGImage = context.makeImage() else { return image }
        return NSImage(cgImage: outputCGImage, size: NSSize(width: width, height: height))
    }
    #endif
}

#Preview {
    DocumentView(document: StratifyDocument())
}
