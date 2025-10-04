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

    // Cluster average colors (mean of superpixels in each cluster)
    @State private var clusterAverageColors: [SIMD3<Float>] = []
    @State private var weightedClusterAverageColors: [SIMD3<Float>] = []

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
    @State private var lightnessWeight: Double = 0.35
    @State private var greenAxisScale: Double = 2.0

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
                        Slider(value: $nSegments, in: 25...3000, step: 50)
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
                        Slider(value: $nClusters, in: 2...30, step: 1)
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

                    HStack {
                        Text("Green Axis Scale: \(String(format: "%.1f", greenAxisScale))")
                            .frame(width: 150, alignment: .leading)
                        Slider(value: $greenAxisScale, in: 0.1...4.0, step: 0.1)
                    }
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

                    // Recomposed Image
                    VStack {
                        Text("Recomposed")
                            .font(.headline)
                        if let recomposed = recomposedImage {
                            Image(nsImage: recomposed)
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
                                    Text("Process to see final")
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
                    Text("Final Cluster Centers")
                        .font(.headline)
                        .padding(.horizontal)

                    HStack(alignment: .top, spacing: 15) {
                        ForEach(Array(clusterCenters.enumerated()), id: \.offset) { index, center in
                            ColorSwatchView(
                                topLabel: "Cluster \(index)",
                                labColor: center,
                                bottomLabel: "LAB",
                                greenAxisScale: Float(greenAxisScale),
                                swatchSize: 60
                            )
                        }
                        Spacer()
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

                                // Visualization image at top
                                HStack {
                                    Image(nsImage: snapshot.visualizationImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .background(CheckerboardBackground())
                                        .frame(width: 256, height: 256)
                                        .border(Color.gray.opacity(0.3), width: 1)
                                    Spacer()
                                }

                                // Cluster extractions with swatches below
                                ScrollView(.horizontal) {
                                    HStack(spacing: 15) {
                                        ForEach(Array(snapshot.layerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                            VStack(spacing: 5) {
                                                // Cluster label
                                                Text("Cluster \(layerIndex)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)

                                                // Layer image
                                                Image(nsImage: layerImage)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .background(CheckerboardBackground())
                                                    .frame(width: 150, height: 150)
                                                    .border(Color.gray.opacity(0.3), width: 1)

                                                // Cluster center swatch below
                                                if layerIndex < snapshot.clusterCenters.count {
                                                    let center = snapshot.clusterCenters[layerIndex]
                                                    ColorSwatchView(
                                                        labColor: center,
                                                        bottomLabel: "LAB",
                                                        greenAxisScale: Float(greenAxisScale)
                                                    )
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

                        ScrollView(.horizontal) {
                            HStack(spacing: 15) {
                                ForEach(Array(layerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                    VStack(spacing: 5) {
                                        // Cluster label
                                        Text("Cluster \(layerIndex)")
                                            .font(.caption)
                                            .fontWeight(.medium)

                                        // Layer image
                                        Image(nsImage: layerImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .background(CheckerboardBackground())
                                            .frame(width: 150, height: 150)
                                            .border(Color.gray.opacity(0.3), width: 1)

                                        // Cluster center swatch
                                        if layerIndex < clusterCenters.count {
                                            let center = clusterCenters[layerIndex]
                                            ColorSwatchView(
                                                topLabel: "Center",
                                                labColor: center,
                                                bottomLabel: "LAB",
                                                greenAxisScale: Float(greenAxisScale)
                                            )
                                        }

                                        // Cluster average color swatch
                                        if layerIndex < clusterAverageColors.count {
                                            let avgColor = clusterAverageColors[layerIndex]
                                            ColorSwatchView(
                                                topLabel: "Pixels",
                                                labColor: avgColor,
                                                bottomLabel: "LAB",
                                                greenAxisScale: Float(greenAxisScale)
                                            )
                                            .padding(.top, 10)

                                            // Distance between center and average
                                            if layerIndex < clusterCenters.count {
                                                let center = clusterCenters[layerIndex]
                                                let diff = center - avgColor
                                                let distance = sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
                                                Text("Δ \(String(format: "%.1f", distance))")
                                                    .font(.caption2)
                                                    .foregroundColor(.blue)
                                                    .padding(.top, 5)
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
                                                        getDistanceHighlightColor(distances: clusterDistances, row: i, col: j) ?? Color.clear
                                                    )
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Weighted Cluster Centers
                    if !weightedClusterCenters.isEmpty && useWeightedColors {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weighted (L×\(String(format: "%.2f", lightnessWeight)), a, b)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.horizontal)
                                .padding(.top, 20)

                            ScrollView(.horizontal) {
                                HStack(spacing: 15) {
                                    ForEach(Array(weightedLayerImages.enumerated()), id: \.offset) { layerIndex, layerImage in
                                        VStack(spacing: 5) {
                                            // Cluster label
                                            Text("Cluster \(layerIndex)")
                                                .font(.caption)
                                                .fontWeight(.medium)

                                            // Layer image
                                            Image(nsImage: layerImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .background(CheckerboardBackground())
                                                .frame(width: 150, height: 150)
                                                .border(Color.gray.opacity(0.3), width: 1)

                                            // Cluster center swatch
                                            if layerIndex < weightedClusterCenters.count {
                                                let center = weightedClusterCenters[layerIndex]
                                                ColorSwatchView(
                                                    topLabel: "Center",
                                                    labColor: center,
                                                    bottomLabel: "LAB",
                                                    greenAxisScale: Float(greenAxisScale)
                                                )
                                            }

                                            // Cluster average color swatch (weighted)
                                            if layerIndex < weightedClusterAverageColors.count {
                                                let avgColor = weightedClusterAverageColors[layerIndex]
                                                ColorSwatchView(
                                                    topLabel: "Pixels",
                                                    labColor: avgColor,
                                                    bottomLabel: "LAB",
                                                    greenAxisScale: Float(greenAxisScale)
                                                )
                                                .padding(.top, 10)

                                                // Distance between weighted center and weighted average
                                                if layerIndex < weightedClusterCenters.count {
                                                    let center = weightedClusterCenters[layerIndex]
                                                    let diff = center - avgColor
                                                    let distance = sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
                                                    Text("Δ \(String(format: "%.1f", distance))")
                                                        .font(.caption2)
                                                        .foregroundColor(.blue)
                                                        .padding(.top, 5)
                                                }
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
                                                        getDistanceHighlightColor(distances: weightedClusterDistances, row: i, col: j) ?? Color.clear
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
                        Image(nsImage: recomposed)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(CheckerboardBackground())
                            .frame(width: 512, height: 512)
                            .border(Color.gray.opacity(0.3), width: 1)
                        Spacer()
                    }
                    .padding(.horizontal)
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

    // MARK: - Color Swatch View Component

    /// Reusable color swatch view with consistent formatting
    struct ColorSwatchView: View {
        let topLabel: String?
        let labColor: SIMD3<Float>
        let bottomLabel: String?
        let greenAxisScale: Float
        let swatchSize: CGFloat

        init(
            topLabel: String? = nil,
            labColor: SIMD3<Float>,
            bottomLabel: String? = nil,
            greenAxisScale: Float = 2.0,
            swatchSize: CGFloat = 50
        ) {
            self.topLabel = topLabel
            self.labColor = labColor
            self.bottomLabel = bottomLabel
            self.greenAxisScale = greenAxisScale
            self.swatchSize = swatchSize
        }

        var body: some View {
            VStack(spacing: 3) {
                // Top label (optional)
                if let topLabel = topLabel {
                    Text(topLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                // Color swatch
                Rectangle()
                    .fill(Color(nsColor: labToNSColor(labColor, greenAxisScale: greenAxisScale)))
                    .frame(width: swatchSize, height: swatchSize)
                    .border(Color.gray, width: 0.5)

                // LAB values (formatted without parentheses, 1 decimal place)
                Text("\(String(format: "%.1f", labColor.x)), \(String(format: "%.1f", labColor.y)), \(String(format: "%.1f", labColor.z))")
                    .font(.caption2)
                    .fixedSize(horizontal: true, vertical: false)

                // Bottom label (optional)
                if let bottomLabel = bottomLabel {
                    Text(bottomLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }

        /// Convert LAB color to NSColor for SwiftUI display
        private func labToNSColor(_ lab: SIMD3<Float>, greenAxisScale: Float) -> NSColor {
            // Reverse green axis scaling if 'a' was scaled during RGB→LAB conversion
            let a = lab.y < 0 ? lab.y / greenAxisScale : lab.y

            // LAB to XYZ
            let fy = (lab.x + 16.0) / 116.0
            let fx = a / 500.0 + fy
            let fz = fy - lab.z / 200.0

            func f_inv(_ t: Float) -> Float {
                let delta: Float = 6.0 / 29.0
                return t > delta ? t * t * t : 3.0 * delta * delta * (t - 4.0 / 29.0)
            }

            let xn: Float = 0.95047
            let yn: Float = 1.00000
            let zn: Float = 1.08883

            let x = xn * f_inv(fx)
            let y = yn * f_inv(fy)
            let z = zn * f_inv(fz)

            // XYZ to RGB (sRGB D65)
            var r = 3.2406 * x - 1.5372 * y - 0.4986 * z
            var g = -0.9689 * x + 1.8758 * y + 0.0415 * z
            var b = 0.0557 * x - 0.2040 * y + 1.0570 * z

            // Gamma correction
            func gamma(_ c: Float) -> Float {
                return c > 0.0031308 ? 1.055 * pow(c, 1.0/2.4) - 0.055 : 12.92 * c
            }

            r = gamma(r)
            g = gamma(g)
            b = gamma(b)

            return NSColor(
                red: CGFloat(max(0, min(1, r))),
                green: CGFloat(max(0, min(1, g))),
                blue: CGFloat(max(0, min(1, b))),
                alpha: 1.0
            )
        }
    }

    // MARK: - Helper Methods

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
            enforceConnectivity: enforceConnectivity,
            greenAxisScale: Float(greenAxisScale)
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
                    superpixelAvgNSImage = SuperpixelProcessor.visualizeSuperpixelAverageColors(superpixelData: superpixelData, greenAxisScale: Float(self.greenAxisScale))

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
                        height: result.height,
                        greenAxisScale: Float(self.greenAxisScale)
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
                            height: result.height,
                            greenAxisScale: Float(self.greenAxisScale)
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

                    // Use weighted centers before recalculation if available, otherwise apply weighting manually
                    if let weightedCenters = debugClusterResult?.weightedCentersBeforeRecalc {
                        self.weightedClusterCenters = weightedCenters
                    } else {
                        self.weightedClusterCenters = self.applyLightnessWeighting(self.clusterCenters, weight: Float(self.lightnessWeight))
                    }

                    // Calculate cluster average colors from original image pixels
                    if let clResult = debugClusterResult, !debugPixelClusters.isEmpty {
                        self.clusterAverageColors = self.calculateTrueClusterAverageColors(
                            originalImage: image,
                            pixelClusters: debugPixelClusters,
                            numberOfClusters: clResult.numberOfClusters,
                            width: result.width,
                            height: result.height,
                            greenAxisScale: Float(self.greenAxisScale)
                        )
                        self.weightedClusterAverageColors = self.applyLightnessWeighting(self.clusterAverageColors, weight: Float(self.lightnessWeight))
                    }

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

    /// Calculate average LAB colors for each cluster from superpixels
    private func calculateClusterAverageColors(
        superpixelData: SuperpixelProcessor.SuperpixelData,
        clusterResult: KMeansProcessor.ClusteringResult
    ) -> [SIMD3<Float>] {
        let numClusters = clusterResult.numberOfClusters
        var clusterSums = Array(repeating: SIMD3<Float>(0, 0, 0), count: numClusters)
        var clusterCounts = Array(repeating: 0, count: numClusters)

        // Accumulate LAB colors for each cluster
        for (superpixelIndex, clusterAssignment) in clusterResult.clusterAssignments.enumerated() {
            if superpixelIndex < superpixelData.superpixels.count {
                let superpixel = superpixelData.superpixels[superpixelIndex]
                clusterSums[clusterAssignment] += superpixel.labColor
                clusterCounts[clusterAssignment] += 1
            }
        }

        // Calculate averages
        var averages: [SIMD3<Float>] = []
        for i in 0..<numClusters {
            if clusterCounts[i] > 0 {
                averages.append(clusterSums[i] / Float(clusterCounts[i]))
            } else {
                // Empty cluster - use cluster center as fallback
                averages.append(clusterResult.clusterCenters[i])
            }
        }

        return averages
    }

    /// Convert RGB (0-1 range) to LAB color space
    private func rgbToLab(_ r: Float, _ g: Float, _ b: Float, greenAxisScale: Float) -> SIMD3<Float> {
        // Inverse gamma correction (sRGB to linear RGB)
        func invGamma(_ c: Float) -> Float {
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        let rLinear = invGamma(r)
        let gLinear = invGamma(g)
        let bLinear = invGamma(b)

        // Linear RGB to XYZ (D65 illuminant)
        let x = rLinear * 0.4124 + gLinear * 0.3576 + bLinear * 0.1805
        let y = rLinear * 0.2126 + gLinear * 0.7152 + bLinear * 0.0722
        let z = rLinear * 0.0193 + gLinear * 0.1192 + bLinear * 0.9505

        // XYZ to LAB
        let xn: Float = 0.95047
        let yn: Float = 1.00000
        let zn: Float = 1.08883

        func f(_ t: Float) -> Float {
            let delta: Float = 6.0 / 29.0
            return t > delta * delta * delta ? pow(t, 1.0/3.0) : t / (3.0 * delta * delta) + 4.0 / 29.0
        }

        let fx = f(x / xn)
        let fy = f(y / yn)
        let fz = f(z / zn)

        let L = 116.0 * fy - 16.0
        var a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)

        // Apply green axis scaling to negative 'a' values (matching SLIC processor behavior)
        if a < 0 {
            a *= greenAxisScale
        }

        return SIMD3<Float>(L, a, b)
    }

    /// Calculate true average LAB colors for each cluster from original image pixels
    private func calculateTrueClusterAverageColors(
        originalImage: NSImage,
        pixelClusters: [UInt32],
        numberOfClusters: Int,
        width: Int,
        height: Int,
        greenAxisScale: Float
    ) -> [SIMD3<Float>] {
        // Extract pixel data from original image
        guard let cgImage = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage for average color calculation")
            return Array(repeating: SIMD3<Float>(0, 0, 0), count: numberOfClusters)
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
            print("Failed to create CGContext for average color calculation")
            return Array(repeating: SIMD3<Float>(0, 0, 0), count: numberOfClusters)
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(fullRect)
        context.draw(cgImage, in: fullRect)

        let pixels = imageData.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        // Accumulate RGB values for each cluster
        var clusterRGBSums = Array(repeating: SIMD3<Float>(0, 0, 0), count: numberOfClusters)
        var clusterCounts = Array(repeating: 0, count: numberOfClusters)

        for i in 0..<pixelClusters.count {
            let clusterID = Int(pixelClusters[i])

            // Skip transparent pixels (marked with special label)
            let transparentLabel: UInt32 = 0xFFFFFFFE
            if pixelClusters[i] == transparentLabel {
                continue
            }

            // Ensure cluster ID is valid
            guard clusterID < numberOfClusters else {
                continue
            }

            // Get BGRA pixel values (premultiplied first + little endian)
            let pixelOffset = i * bytesPerPixel
            let b = Float(pixels[pixelOffset + 0]) / 255.0
            let g = Float(pixels[pixelOffset + 1]) / 255.0
            let r = Float(pixels[pixelOffset + 2]) / 255.0

            // Accumulate RGB
            clusterRGBSums[clusterID] += SIMD3<Float>(r, g, b)
            clusterCounts[clusterID] += 1
        }

        // Calculate average RGB and convert to LAB for each cluster
        var averages: [SIMD3<Float>] = []
        for i in 0..<numberOfClusters {
            if clusterCounts[i] > 0 {
                // Average RGB values
                let avgRGB = clusterRGBSums[i] / Float(clusterCounts[i])

                // Convert to LAB
                let lab = rgbToLab(avgRGB.x, avgRGB.y, avgRGB.z, greenAxisScale: greenAxisScale)
                averages.append(lab)
            } else {
                // Empty cluster - use black as fallback
                averages.append(SIMD3<Float>(0, 0, 0))
            }
        }

        return averages
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

    /// Get highlight color for distance matrix cell based on value
    /// Only highlights upper triangle (j > i) with value-based colors
    private func getDistanceHighlightColor(distances: [[Float]], row: Int, col: Int) -> Color? {
        // Don't highlight diagonal or lower triangle
        if col <= row {
            return row == col ? Color.gray.opacity(0.2) : nil
        }

        let value = distances[row][col]

        // Color based on distance value
        if value < 10 {
            return Color.green.opacity(0.5)
        } else if value <= 20 {
            return Color.yellow.opacity(0.5)
        } else if value <= 30 {
            return Color.orange.opacity(0.3)
        } else {
            return nil  // No highlight for values > 30
        }
    }

    /// Convert LAB color to NSColor for SwiftUI display
    private func labToNSColor(_ lab: SIMD3<Float>, greenAxisScale: Float = 2.0) -> NSColor {
        // Reverse green axis scaling if 'a' was scaled during RGB→LAB conversion
        let a = lab.y < 0 ? lab.y / greenAxisScale : lab.y

        // LAB to XYZ
        let fy = (lab.x + 16.0) / 116.0
        let fx = a / 500.0 + fy
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
