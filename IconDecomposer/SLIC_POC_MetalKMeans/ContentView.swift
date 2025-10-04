//
//  ContentView.swift
//  SLIC_ProofOfConcept
//
//  Created by Andrew Benson on 9/28/25.
//

import SwiftUI
import AppKit

struct CheckerboardBackground: View {
    var body: some View {
        Color.blue.opacity(0.6)
            .background(xCheckerboardBackground())
    }
}
struct xCheckerboardBackground: View {
    let squareSize: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let rows = Int(ceil(size.height / squareSize))
                let columns = Int(ceil(size.width / squareSize))

                for row in 0..<rows {
                    for column in 0..<columns {
                        let isLight = (row + column) % 2 == 0
                        let color = isLight ? Color(white: 0.95) : Color(white: 0.85)

                        let rect = CGRect(
                            x: CGFloat(column) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )

                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @State private var selectedImageIndex = 0
    @State private var originalImage: NSImage?
    @State private var segmentedImage: NSImage?
    @State private var superpixelAvgImage: NSImage?
    @State private var kmeansImage: NSImage?
    @State private var weightedKmeansImage: NSImage?
    @State private var processingTime: Double = 0
    @State private var kmeansProcessingTime: Double = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var lastProcessingResult: SLICProcessor.ProcessingResult?
    @State private var layerImages: [NSImage] = []
    @State private var weightedLayerImages: [NSImage] = []

    // Debug data for layer inspection
    @State private var extractedLayers: [LayerExtractor.Layer] = []
    @State private var pixelClusters: [UInt32] = []
    @State private var debugSuperpixelData: SuperpixelProcessor.SuperpixelData?
    @State private var debugClusterResult: KMeansProcessor.ClusteringResult?

    // Cluster centers for visualization
    @State private var clusterCenters: [SIMD3<Float>] = []
    @State private var weightedClusterCenters: [SIMD3<Float>] = []

    // Distance matrix between cluster centers
    @State private var clusterDistances: [[Float]] = []
    @State private var weightedClusterDistances: [[Float]] = []

    // K-means iteration history
    @State private var iterationSnapshots: [KMeansProcessor.IterationSnapshot] = []

    // Recomposed image from final layers
    @State private var recomposedImage: NSImage?

    // Test image names (will be added to Assets.xcassets)
    let testImageNames = ["TestIcon1", "TestIcon2", "TestIcon3", "TestIcon4"]

    // SLIC parameters (matching Python defaults)
    @State private var nSegments: Double = 1000
    @State private var compactness: Double = 25
    @State private var iterations: Double = 10
    @State private var enforceConnectivity = true

    // K-means parameters
    @State private var nClusters: Double = 5
    @State private var useWeightedColors = true
    @State private var lightnessWeight: Double = 0.65

    private let processor = SLICProcessor()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Title and controls
                VStack(spacing: 15) {
                VStack(spacing: 10) {
                    Text("SLIC Superpixel Segmentation")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("(Simple Linear Iterative Clustering)")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                // Image selector
                Picker("Test Image", selection: $selectedImageIndex) {
                    ForEach(0..<testImageNames.count, id: \.self) { index in
                        Text("Test Image \(index + 1)").tag(index)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(maxWidth: 400)
                .onChange(of: selectedImageIndex) { _, _ in
                    loadSelectedImage()
                }

                // Parameters
                VStack(spacing: 10) {
                    HStack {
                        Text("Segments: \(Int(nSegments))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $nSegments, in: 200...2000, step: 50)
                    }

                    HStack {
                        Text("Compactness: \(Int(compactness))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $compactness, in: 1...50, step: 1)
                    }

                    HStack {
                        Text("Iterations: \(Int(iterations))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $iterations, in: 5...20, step: 1)
                    }

                    Toggle("Enforce Connectivity", isOn: $enforceConnectivity)
                        .frame(maxWidth: 300)

                    Divider()

                    // K-means parameters
                    HStack {
                        Text("Clusters: \(Int(nClusters))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $nClusters, in: 2...10, step: 1)
                    }

                    Toggle("Use Weighted Colors", isOn: $useWeightedColors)
                        .frame(maxWidth: 300)

                    HStack {
                        Text("Lightness Weight: \(String(format: "%.2f", lightnessWeight))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $lightnessWeight, in: 0.1...1.0, step: 0.05)
                    }
                    .disabled(!useWeightedColors)
                    .opacity(useWeightedColors ? 1.0 : 0.5)
                }
                .frame(maxWidth: 600)

                // Process button
                Button(action: processImage) {
                    Text("Process Image")
                        .overlay(content: {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                                .opacity(isProcessing ? 1.0 : 0.0)
                            
                        })
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || originalImage == nil)

                // Performance metrics - always rendered to reserve space
                VStack(spacing: 5) {
                    let totalTime = processingTime + kmeansProcessingTime
                    Text("Processing Time: \(String(format: "%.3f", totalTime)) seconds")
                        .font(.headline)
                    HStack {
                        Text("SLIC: \(String(format: "%.0f", processingTime * 1000))ms")
                            .font(.caption)
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("K-means: \(String(format: "%.0f", kmeansProcessingTime * 1000))ms")
                            .font(.caption)
                    }
                    let fps = Int(totalTime > 0.0 ? 1.0/totalTime : 0.0)
                    Text("FPS Equivalent: \(fps)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
                .opacity(processingTime > 0 ? 1.0 : 0.0)

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
            }

            Divider()

            // Image display
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    // Original Image
                    VStack {
                        Text("Original")
                            .font(.headline)
                        if let original = originalImage {
                            Image(nsImage: original)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(CheckerboardBackground())
                                .frame(width: 256, height: 256)
                                .border(Color.gray.opacity(0.3), width: 1)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.1))
                                .frame(width: 256, height: 256)
                                .overlay(
                                    Text("No image loaded")
                                        .foregroundColor(.gray)
                                )
                        }
                    }

                    // SLIC Segmentation
                    VStack {
                        Text("SLIC Boundaries")
                            .font(.headline)
                        if let segmented = segmentedImage {
                            Image(nsImage: segmented)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(CheckerboardBackground())
                                .frame(width: 256, height: 256)
                                .border(Color.gray.opacity(0.3), width: 1)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.1))
                                .frame(width: 256, height: 256)
                                .overlay(
                                    Text("Process to see SLIC")
                                        .foregroundColor(.gray)
                                )
                        }
                    }

                    // Superpixel Average Colors
                    VStack {
                        Text("Superpixel Avg Colors")
                            .font(.headline)
                        if let superpixelAvg = superpixelAvgImage {
                            Image(nsImage: superpixelAvg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(CheckerboardBackground())
                                .frame(width: 256, height: 256)
                                .border(Color.gray.opacity(0.3), width: 1)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.1))
                                .frame(width: 256, height: 256)
                                .overlay(
                                    Text("Process to see superpixels")
                                        .foregroundColor(.gray)
                                )
                        }
                    }

                    // K-means Clustering
                    VStack {
                        Text("K-means Clusters")
                            .font(.headline)
                        if let kmeans = kmeansImage {
                            Image(nsImage: kmeans)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(CheckerboardBackground())
                                .frame(width: 256, height: 256)
                                .border(Color.gray.opacity(0.3), width: 1)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.1))
                                .frame(width: 256, height: 256)
                                .overlay(
                                    Text("Process to see clusters")
                                        .foregroundColor(.gray)
                                )
                        }
                    }
                }
                .padding()
            }

            // Cluster Centers section
            if !clusterCenters.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Cluster Centers")
                        .font(.headline)
                        .padding(.horizontal)

                    HStack(spacing: 15) {
                        ForEach(Array(clusterCenters.enumerated()), id: \.offset) { index, center in
                            VStack(spacing: 5) {
                                Text("Cluster \(index)")
                                    .font(.caption)
                                Rectangle()
                                    .fill(Color(nsColor: labToNSColor(center)))
                                    .frame(width: 60, height: 60)
                                    .border(Color.gray, width: 1)
                                Text("LAB(\(String(format: "%.1f", center.x)), \(String(format: "%.1f", center.y)), \(String(format: "%.1f", center.z)))")
                                    .font(.caption2)
                                    .frame(width: 100)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // K-means Iteration History section
            if !iterationSnapshots.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("K-means Iteration History (\(iterationSnapshots.count) iterations)")
                        .font(.headline)
                        .padding(.horizontal)

                    VStack(spacing: 20) {
                        ForEach(Array(iterationSnapshots.enumerated()), id: \.offset) { index, snapshot in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Iteration \(snapshot.iterationNumber)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                HStack(alignment: .top, spacing: 15) {
                                    // Left side: visualization image and cluster centers
                                    VStack(spacing: 8) {
                                        Image(nsImage: snapshot.visualizationImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .background(CheckerboardBackground())
                                            .frame(width: 256, height: 256)
                                            .border(Color.gray.opacity(0.3), width: 1)

                                        // Cluster center swatches with LAB values
                                        VStack(spacing: 5) {
                                            Text("Cluster Centers")
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                            HStack(spacing: 8) {
                                                ForEach(Array(snapshot.clusterCenters.enumerated()), id: \.offset) { centerIndex, center in
                                                    VStack(spacing: 3) {
                                                        Rectangle()
                                                            .fill(Color(nsColor: labToNSColor(center)))
                                                            .frame(width: 40, height: 40)
                                                            .border(Color.gray, width: 0.5)
                                                        Text("\(centerIndex)")
                                                            .font(.caption2)
                                                        Text("LAB(\(String(format: "%.0f", center.x)),\(String(format: "%.0f", center.y)),\(String(format: "%.0f", center.z)))")
                                                            .font(.caption2)
                                                            .frame(width: 80)
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Right side: extracted layers
                                    ScrollView(.horizontal) {
                                        HStack(spacing: 10) {
                                            ForEach(Array(snapshot.layerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                                VStack(spacing: 5) {
                                                    Text("Cluster \(layerIndex)")
                                                        .font(.caption2)
                                                    Image(nsImage: layerImage)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fit)
                                                        .background(CheckerboardBackground())
                                                        .frame(width: 150, height: 150)
                                                        .border(Color.gray.opacity(0.3), width: 1)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)

                            Divider()
                        }
                    }
                }
            }

            // Final Cluster Analysis section
            if !clusterCenters.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 15) {
                    Text("Final Cluster Analysis")
                        .font(.headline)
                        .padding(.horizontal)

                    // Unweighted (True Color) Cluster Centers
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Unweighted (True LAB Colors)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 15) {
                            // Cluster center swatches
                            HStack(spacing: 8) {
                                ForEach(Array(clusterCenters.enumerated()), id: \.offset) { index, center in
                                    VStack(spacing: 3) {
                                        Rectangle()
                                            .fill(Color(nsColor: labToNSColor(center)))
                                            .frame(width: 60, height: 60)
                                            .border(Color.gray, width: 1)
                                        Text("\(index)")
                                            .font(.caption2)
                                        Text("LAB(\(String(format: "%.0f", center.x)),\(String(format: "%.0f", center.y)),\(String(format: "%.0f", center.z)))")
                                            .font(.caption2)
                                            .frame(width: 100)
                                    }
                                }
                            }

                            // Extracted layers
                            if !layerImages.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach(Array(layerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                            VStack(spacing: 5) {
                                                Text("Cluster \(layerIndex)")
                                                    .font(.caption2)
                                                Image(nsImage: layerImage)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .background(CheckerboardBackground())
                                                    .frame(width: 150, height: 150)
                                                    .border(Color.gray.opacity(0.3), width: 1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Weighted Cluster Centers
                    if !weightedClusterCenters.isEmpty && useWeightedColors {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weighted (L×\(String(format: "%.2f", lightnessWeight)), a, b)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.horizontal)

                            VStack(alignment: .leading, spacing: 15) {
                                // Cluster center swatches
                                HStack(spacing: 8) {
                                    ForEach(Array(weightedClusterCenters.enumerated()), id: \.offset) { index, center in
                                        VStack(spacing: 3) {
                                            Rectangle()
                                                .fill(Color(nsColor: labToNSColor(center)))
                                                .frame(width: 60, height: 60)
                                                .border(Color.gray, width: 1)
                                            Text("\(index)")
                                                .font(.caption2)
                                            Text("LAB(\(String(format: "%.0f", center.x)),\(String(format: "%.0f", center.y)),\(String(format: "%.0f", center.z)))")
                                                .font(.caption2)
                                                .frame(width: 100)
                                        }
                                    }
                                }

                                // Extracted layers
                                if !weightedLayerImages.isEmpty {
                                    ScrollView(.horizontal) {
                                        HStack(spacing: 10) {
                                            ForEach(Array(weightedLayerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                                VStack(spacing: 5) {
                                                    Text("Cluster \(layerIndex)")
                                                        .font(.caption2)
                                                    Image(nsImage: layerImage)
                                                        .resizable()
                                                        .aspectRatio(contentMode: .fit)
                                                        .background(CheckerboardBackground())
                                                        .frame(width: 150, height: 150)
                                                        .border(Color.gray.opacity(0.3), width: 1)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Distance Matrix - Unweighted
                    if !clusterDistances.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Unweighted Cluster Distance Matrix (LAB Euclidean)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.horizontal)

                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 3) {
                                    // Header row
                                    HStack(spacing: 0) {
                                        Text("")
                                            .frame(width: 40)
                                        ForEach(0..<clusterCenters.count, id: \.self) { j in
                                            Text("\(j)")
                                                .font(.caption2)
                                                .frame(width: 50)
                                        }
                                    }

                                    // Data rows
                                    ForEach(0..<clusterDistances.count, id: \.self) { i in
                                        HStack(spacing: 0) {
                                            Text("\(i)")
                                                .font(.caption2)
                                                .frame(width: 40)
                                            ForEach(0..<clusterDistances[i].count, id: \.self) { j in
                                                Text(String(format: "%.1f", clusterDistances[i][j]))
                                                    .font(.caption2)
                                                    .frame(width: 50)
                                                    .background(
                                                        i == j ? Color.gray.opacity(0.2) :
                                                        shouldHighlightCell(distances: clusterDistances, row: i, col: j) ? Color.yellow.opacity(0.3) :
                                                        Color.clear
                                                    )
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Distance Matrix - Weighted
                    if !weightedClusterDistances.isEmpty && useWeightedColors {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Weighted Cluster Distance Matrix (LAB Euclidean, L×\(String(format: "%.2f", lightnessWeight)))")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.horizontal)

                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 3) {
                                    // Header row
                                    HStack(spacing: 0) {
                                        Text("")
                                            .frame(width: 40)
                                        ForEach(0..<weightedClusterCenters.count, id: \.self) { j in
                                            Text("\(j)")
                                                .font(.caption2)
                                                .frame(width: 50)
                                        }
                                    }

                                    // Data rows
                                    ForEach(0..<weightedClusterDistances.count, id: \.self) { i in
                                        HStack(spacing: 0) {
                                            Text("\(i)")
                                                .font(.caption2)
                                                .frame(width: 40)
                                            ForEach(0..<weightedClusterDistances[i].count, id: \.self) { j in
                                                Text(String(format: "%.1f", weightedClusterDistances[i][j]))
                                                    .font(.caption2)
                                                    .frame(width: 50)
                                                    .background(
                                                        i == j ? Color.gray.opacity(0.2) :
                                                        shouldHighlightCell(distances: weightedClusterDistances, row: i, col: j) ? Color.yellow.opacity(0.3) :
                                                        Color.clear
                                                    )
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            }

            // Layer view section
            if !layerImages.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Extracted Layers (\(layerImages.count))")
                        .font(.headline)
                        .padding(.horizontal)

                    // Use LazyVGrid for wrapping layout
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 256))], spacing: 15) {
                        ForEach(Array(layerImages.enumerated()), id: \.offset) { index, layerImage in
                            VStack {
                                Text("Cluster \(index) (tap for debug info)")
                                    .font(.caption)
                                Image(nsImage: layerImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .background(CheckerboardBackground())
                                    .frame(width: 256, height: 256)
                                    .border(Color.gray.opacity(0.3), width: 1)
                                    .onTapGesture {
                                        debugLayer(index: index)
                                    }
                            }
                        }
                    }
                    .padding()
                }
            }

            // Recomposed Image section
            if let recomposed = recomposedImage {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recomposed Image")
                        .font(.headline)
                        .padding(.horizontal)

                    Text("All final layers combined")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)

                    HStack {
                        Spacer()
                        Image(nsImage: recomposed)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(CheckerboardBackground())
                            .frame(width: 512, height: 512)
                            .border(Color.gray.opacity(0.3), width: 1)
                        Spacer()
                    }
                    .padding()
                }
            }

            Spacer()
        }
        .padding()
    }
    .frame(minWidth: 900, minHeight: 800)
        .onAppear {
            loadSelectedImage()
        }
    }

    private func loadSelectedImage() {
        errorMessage = nil
        segmentedImage = nil
        superpixelAvgImage = nil
        kmeansImage = nil
        weightedKmeansImage = nil
        layerImages = []
        weightedLayerImages = []
        clusterCenters = []
        weightedClusterCenters = []
        clusterDistances = []
        weightedClusterDistances = []
        iterationSnapshots = []
        recomposedImage = nil
        processingTime = 0
        kmeansProcessingTime = 0
        lastProcessingResult = nil

        let imageName = testImageNames[selectedImageIndex]

        // For now, create a placeholder image
        // In the real implementation, this will load from Assets.xcassets
        if let image = NSImage(named: imageName) {
            originalImage = image
        } else {
            // Create a placeholder gradient image for testing
            originalImage = createPlaceholderImage()
        }
    }

    private func createPlaceholderImage() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)

        image.lockFocus()

        // Create different patterns for each test image
        let context = NSGraphicsContext.current!.cgContext

            let colors = [NSColor.purple, NSColor.magenta]
            for y in stride(from: 0, to: 1024, by: 128) {
                for x in stride(from: 0, to: 1024, by: 128) {
                    let colorIndex = ((x / 128) + (y / 128)) % 2
                    context.setFillColor(colors[colorIndex].cgColor)
                    context.fill(CGRect(x: x, y: y, width: 128, height: 128))
                }
            }


        image.unlockFocus()
        return image
    }

    private func processImage() {
        guard let image = originalImage else {
            errorMessage = "No image available"
            return
        }

        guard let processor = processor else {
            errorMessage = "Metal processor not available"
            return
        }

        isProcessing = true
        errorMessage = nil

        let parameters = SLICProcessor.Parameters(
            nSegments: Int(nSegments),
            compactness: Float(compactness),
            iterations: Int(iterations),
            enforceConnectivity: enforceConnectivity
        )

        DispatchQueue.global(qos: .userInitiated).async {
            if let result = processor.processImage(image, parameters: parameters) {
                // Process with K-means if buffers are available
                var kmeansNSImage: NSImage?
                var weightedKmeansNSImage: NSImage?
                var superpixelAvgNSImage: NSImage?
                var recomposedNSImage: NSImage?
                var kmeansTime: Double = 0
                var layers: [NSImage] = []
                var weightedLayers: [NSImage] = []

                // Debug data storage
                var debugExtractedLayers: [LayerExtractor.Layer] = []
                var debugPixelClusters: [UInt32] = []
                var debugSuperpixelData: SuperpixelProcessor.SuperpixelData?
                var debugClusterResult: KMeansProcessor.ClusteringResult?

                if let labBuffer = result.labBuffer,
                   let labelsBuffer = result.labelsBuffer {

                    let kmeansStartTime = CFAbsoluteTimeGetCurrent()

                    // Extract superpixels (using Metal GPU acceleration)
                    let extractStart = CFAbsoluteTimeGetCurrent()
                    let superpixelData = SuperpixelProcessor.extractSuperpixelsMetal(
                        from: labBuffer,
                        labelsBuffer: labelsBuffer,
                        width: result.width,
                        height: result.height
                    )
                    debugSuperpixelData = superpixelData
                    let extractTime = CFAbsoluteTimeGetCurrent() - extractStart
                    #if DEBUG
                    print(String(format: "Extract superpixels: %.2f ms", extractTime * 1000))
                    #endif

                    // Generate superpixel average color visualization
                    superpixelAvgNSImage = SuperpixelProcessor.visualizeSuperpixelAverageColors(superpixelData: superpixelData)

                    // Check if we have any visible superpixels to cluster
                    guard !superpixelData.superpixels.isEmpty else {
                        print("Warning: No visible superpixels found (image is completely transparent)")
                        DispatchQueue.main.async {
                            self.segmentedImage = result.segmented
                            self.processingTime = result.processingTime
                            self.errorMessage = "Image is completely transparent - no layers to extract"
                            self.isProcessing = false
                        }
                        return
                    }

                    // Perform K-means clustering
                    let clusterStart = CFAbsoluteTimeGetCurrent()
                    let kmeansParams = KMeansProcessor.Parameters(
                        numberOfClusters: Int(self.nClusters),
                        useWeightedColors: self.useWeightedColors,
                        lightnessWeight: Float(self.lightnessWeight)
                    )

                    let clusterResult = KMeansProcessor.cluster(
                        superpixelData: superpixelData,
                        parameters: kmeansParams,
                        originalImage: image,
                        imageWidth: result.width,
                        imageHeight: result.height
                    )
                    debugClusterResult = clusterResult
                    let clusterTime = CFAbsoluteTimeGetCurrent() - clusterStart
                    #if DEBUG
                    print(String(format: "K-means clustering: %.2f ms", clusterTime * 1000))
                    #endif

                    // Map clusters back to pixels
                    let mapStart = CFAbsoluteTimeGetCurrent()
                    let pixelClusters = SuperpixelProcessor.mapClustersToPixels(
                        clusterAssignments: clusterResult.clusterAssignments,
                        superpixelData: superpixelData
                    )
                    debugPixelClusters = pixelClusters
                    let mapTime = CFAbsoluteTimeGetCurrent() - mapStart
                    #if DEBUG
                    print(String(format: "Map clusters to pixels: %.2f ms", mapTime * 1000))
                    #endif

                    // Create visualization
                    let vizStart = CFAbsoluteTimeGetCurrent()
                    let pixelData = KMeansProcessor.visualizeClusters(
                        pixelClusters: pixelClusters,
                        clusterCenters: clusterResult.clusterCenters,
                        width: result.width,
                        height: result.height
                    )
                    let vizTime = CFAbsoluteTimeGetCurrent() - vizStart
                    #if DEBUG
                    print(String(format: "Create visualization: %.2f ms", vizTime * 1000))
                    #endif

                    // Convert to NSImage
                    let convertStart = CFAbsoluteTimeGetCurrent()
                    if let cgImage = self.createCGImage(from: pixelData, width: result.width, height: result.height) {
                        kmeansNSImage = NSImage(cgImage: cgImage, size: NSSize(width: result.width, height: result.height))
                    }
                    let convertTime = CFAbsoluteTimeGetCurrent() - convertStart
                    #if DEBUG
                    print(String(format: "Convert to NSImage: %.2f ms", convertTime * 1000))
                    #endif

                    // Create weighted visualization
                    if self.useWeightedColors {
                        let weightedCenters = self.applyLightnessWeighting(clusterResult.clusterCenters, weight: Float(self.lightnessWeight))
                        let weightedPixelData = KMeansProcessor.visualizeClusters(
                            pixelClusters: pixelClusters,
                            clusterCenters: weightedCenters,
                            width: result.width,
                            height: result.height
                        )
                        if let weightedCGImage = self.createCGImage(from: weightedPixelData, width: result.width, height: result.height) {
                            weightedKmeansNSImage = NSImage(cgImage: weightedCGImage, size: NSSize(width: result.width, height: result.height))
                        }
                    }

                    // Extract layers from clustering results
                    let layerStart = CFAbsoluteTimeGetCurrent()
                    if let originalImage = self.originalImage {
                        let extractedLayers = LayerExtractor.extractLayers(
                            from: originalImage,
                            pixelClusters: pixelClusters,
                            clusterCenters: clusterResult.clusterCenters,
                            width: result.width,
                            height: result.height
                        )
                        layers = extractedLayers.map { $0.image }
                        debugExtractedLayers = extractedLayers

                        // Recompose layers back into a single image
                        recomposedNSImage = self.recomposeLayers(layers, width: result.width, height: result.height)

                        // Extract layers using weighted cluster centers
                        if self.useWeightedColors, let weightedVizImage = weightedKmeansNSImage {
                            let weightedCenters = self.applyLightnessWeighting(clusterResult.clusterCenters, weight: Float(self.lightnessWeight))
                            let weightedExtractedLayers = LayerExtractor.extractLayers(
                                from: weightedVizImage,  // Use weighted visualization, not original image
                                pixelClusters: pixelClusters,
                                clusterCenters: weightedCenters,
                                width: result.width,
                                height: result.height
                            )
                            weightedLayers = weightedExtractedLayers.map { $0.image }
                        }
                    }
                    let layerTime = CFAbsoluteTimeGetCurrent() - layerStart
                    #if DEBUG
                    print(String(format: "Extract layers: %.2f ms", layerTime * 1000))
                    #endif

                    kmeansTime = CFAbsoluteTimeGetCurrent() - kmeansStartTime
                    #if DEBUG
                    print(String(format: "Total K-means pipeline: %.2f ms", kmeansTime * 1000))
                    #endif
                }

                DispatchQueue.main.async {
                    print("Processing succeeded")
                    self.segmentedImage = result.segmented
                    self.superpixelAvgImage = superpixelAvgNSImage
                    self.kmeansImage = kmeansNSImage
                    self.weightedKmeansImage = weightedKmeansNSImage
                    self.layerImages = layers
                    self.weightedLayerImages = weightedLayers
                    self.clusterCenters = debugClusterResult?.clusterCenters ?? []
                    self.weightedClusterCenters = self.applyLightnessWeighting(self.clusterCenters, weight: Float(self.lightnessWeight))
                    self.clusterDistances = self.calculateClusterDistances(self.clusterCenters)
                    self.weightedClusterDistances = self.calculateClusterDistances(self.weightedClusterCenters)
                    self.iterationSnapshots = debugClusterResult?.iterationSnapshots ?? []
                    self.recomposedImage = recomposedNSImage
                    self.processingTime = result.processingTime
                    self.kmeansProcessingTime = kmeansTime
                    self.lastProcessingResult = result

                    // Store debug data for layer inspection
                    self.extractedLayers = debugExtractedLayers
                    self.pixelClusters = debugPixelClusters
                    self.debugSuperpixelData = debugSuperpixelData
                    self.debugClusterResult = debugClusterResult

                    self.isProcessing = false
                }
            } else {
                DispatchQueue.main.async {
                    print("Processing returned nil")
                    self.errorMessage = "Processing failed"
                    self.isProcessing = false
                }
            }
        }
    }

    private func debugLayer(index: Int) {
        guard index < extractedLayers.count else {
            print("Layer index out of range")
            return
        }

        let layer = extractedLayers[index]
        let transparentLabel: UInt32 = 0xFFFFFFFE

        print("\n" + String(repeating: "=", count: 80))
        print("DEBUG INFO FOR LAYER \(index + 1)")
        print(String(repeating: "=", count: 80))

        // Basic layer info
        print("\nLayer Metadata:")
        print("  Cluster ID: \(layer.clusterId)")
        print("  Pixel count: \(layer.pixelCount)")
        print("  Average LAB color: L=\(String(format: "%.1f", layer.averageColor.x)), a=\(String(format: "%.1f", layer.averageColor.y)), b=\(String(format: "%.1f", layer.averageColor.z))")

        // Find which superpixels belong to this cluster
        guard let superpixelData = debugSuperpixelData,
              let clusterResult = debugClusterResult else {
            print("  No debug data available")
            return
        }

        var superpixelsInCluster: [SuperpixelProcessor.Superpixel] = []
        for (idx, assignment) in clusterResult.clusterAssignments.enumerated() {
            if assignment == layer.clusterId && idx < superpixelData.superpixels.count {
                superpixelsInCluster.append(superpixelData.superpixels[idx])
            }
        }

        print("\nSuperpixels assigned to this cluster: \(superpixelsInCluster.count)")
        for (idx, sp) in superpixelsInCluster.prefix(10).enumerated() {
            print(String(format: "  SP #%d: id=%d, pixels=%d, LAB=(%.1f, %.1f, %.1f), center=(%.1f, %.1f)",
                        idx, sp.id, sp.pixelCount,
                        sp.labColor.x, sp.labColor.y, sp.labColor.z,
                        sp.centerPosition.x, sp.centerPosition.y))
        }
        if superpixelsInCluster.count > 10 {
            print("  ... and \(superpixelsInCluster.count - 10) more")
        }

        // Get actual pixel RGBA values from original image
        guard let result = lastProcessingResult,
              let image = originalImage else {
            print("  No image data available")
            return
        }

        let width = result.width
        let height = result.height

        // Extract pixel data from original image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("  Failed to get CGImage")
            return
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let imageData = UnsafeMutableRawPointer.allocate(byteCount: height * bytesPerRow, alignment: 1)
        defer { imageData.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: imageData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            print("  Failed to create CGContext")
            return
        }
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(fullRect)
        context.draw(cgImage, in: fullRect)
        let pixels = imageData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Calculate alpha statistics for this layer
        var alphaValues: [UInt8] = []
        for i in 0..<pixelClusters.count {
            if pixelClusters[i] == layer.clusterId {
                let pixelOffset = i * 4
                let alpha = pixels[pixelOffset + 3]  // BGRA format, alpha is at +3
                alphaValues.append(alpha)
            }
        }

        if !alphaValues.isEmpty {
            let minAlpha = alphaValues.min() ?? 0
            let maxAlpha = alphaValues.max() ?? 0
            let avgAlpha = alphaValues.reduce(0, { $0 + Int($1) }) / alphaValues.count
            print("\nAlpha statistics for this layer:")
            print(String(format: "  Min: %d, Max: %d, Average: %d (out of 255)", minAlpha, maxAlpha, avgAlpha))
        }

        // Sample some actual pixels with RGBA values
        print("\nSample pixels from this layer (first 20):")
        var sampleCount = 0

        for i in 0..<pixelClusters.count {
            if pixelClusters[i] == layer.clusterId {
                let x = i % width
                let y = i / width
                let superpixelLabel = superpixelData.labelMap[i]

                // Get BGRA values (premultiplied first + little endian = BGRA)
                let pixelOffset = i * 4
                let b = pixels[pixelOffset + 0]
                let g = pixels[pixelOffset + 1]
                let r = pixels[pixelOffset + 2]
                let a = pixels[pixelOffset + 3]

                print(String(format: "  Pixel (%d, %d): RGBA=(%d,%d,%d,%d) superpixel=%d cluster=%d",
                            x, y, r, g, b, a, superpixelLabel, pixelClusters[i]))
                sampleCount += 1
                if sampleCount >= 20 { break }
            }
        }

        // Check for transparent or special labels
        var transparentCount = 0
        for cluster in pixelClusters {
            if cluster == transparentLabel {
                transparentCount += 1
            }
        }
        if transparentCount > 0 {
            print("\nNote: \(transparentCount) pixels have transparent label (0xFFFFFFFE)")
        }

        print(String(repeating: "=", count: 80) + "\n")
    }

    private func createCGImage(from pixelData: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA format to match SLIC processor
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let dataProvider = CGDataProvider(data: pixelData as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Recompose layers back into a single image
    private func recomposeLayers(_ layers: [NSImage], width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let compositeImage = NSImage(size: size)

        compositeImage.lockFocus()

        // Draw each layer on top
        for layer in layers {
            layer.draw(in: NSRect(origin: .zero, size: size))
        }

        compositeImage.unlockFocus()

        return compositeImage
    }

    /// Apply lightness weighting to cluster centers
    private func applyLightnessWeighting(_ centers: [SIMD3<Float>], weight: Float) -> [SIMD3<Float>] {
        return centers.map { center in
            SIMD3<Float>(center.x * weight, center.y, center.z)
        }
    }

    /// Calculate distance matrix between cluster centers
    private func calculateClusterDistances(_ centers: [SIMD3<Float>]) -> [[Float]] {
        let n = centers.count
        var distances = Array(repeating: Array(repeating: Float(0), count: n), count: n)

        for i in 0..<n {
            for j in 0..<n {
                if i == j {
                    distances[i][j] = 0
                } else {
                    // Euclidean distance in LAB space
                    let diff = centers[i] - centers[j]
                    let distSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z
                    distances[i][j] = sqrt(distSq)
                }
            }
        }

        return distances
    }

    /// Check if a cell should be highlighted (min in row, excluding diagonal)
    private func shouldHighlightCell(distances: [[Float]], row: Int, col: Int) -> Bool {
        if row == col {
            return false  // Don't highlight diagonal
        }

        let n = distances.count
        let value = distances[row][col]

        // Check if minimum in row (excluding diagonal)
        for j in 0..<n {
            if j != row && distances[row][j] < value {
                return false
            }
        }

        return true
    }

    /// Convert LAB color to NSColor for SwiftUI display
    private func labToNSColor(_ lab: SIMD3<Float>) -> NSColor {
        // LAB to XYZ
        let fy = (lab.x + 16.0) / 116.0
        let fx = lab.y / 500.0 + fy
        let fz = fy - lab.z / 200.0

        let xr = fx > 0.206897 ? fx * fx * fx : (fx - 16.0/116.0) / 7.787
        let yr = fy > 0.206897 ? fy * fy * fy : (fy - 16.0/116.0) / 7.787
        let zr = fz > 0.206897 ? fz * fz * fz : (fz - 16.0/116.0) / 7.787

        let x = xr * 95.047
        let y = yr * 100.000
        let z = zr * 108.883

        // XYZ to RGB (sRGB)
        let r =  3.2406 * x / 100.0 - 1.5372 * y / 100.0 - 0.4986 * z / 100.0
        let g = -0.9689 * x / 100.0 + 1.8758 * y / 100.0 + 0.0415 * z / 100.0
        let b =  0.0557 * x / 100.0 - 0.2040 * y / 100.0 + 1.0570 * z / 100.0

        // Apply gamma correction and clamp
        let gammaCorrect: (Float) -> CGFloat = { value in
            let clamped = max(0, min(1, value))
            return CGFloat(clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0/2.4) - 0.055)
        }

        return NSColor(
            calibratedRed: gammaCorrect(r),
            green: gammaCorrect(g),
            blue: gammaCorrect(b),
            alpha: 1.0
        )
    }
}

#Preview {
    ContentView()
}
