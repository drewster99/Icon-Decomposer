//
//  ContentView.swift
//  SLIC_ProofOfConcept
//
//  Created by Andrew Benson on 9/28/25.
//

import SwiftUI
import AppKit

struct CheckerboardBackground: View {
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
    @State private var kmeansImage: NSImage?
    @State private var processingTime: Double = 0
    @State private var kmeansProcessingTime: Double = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var lastProcessingResult: SLICProcessor.ProcessingResult?
    @State private var layerImages: [NSImage] = []

    // Test image names (will be added to Assets.xcassets)
    let testImageNames = ["TestIcon1", "TestIcon2", "TestIcon3", "TestIcon4", "TestIcon5", "TestIcon6", "TestIcon7"]

    // SLIC parameters (matching Python defaults)
    @State private var nSegments: Double = 1000
    @State private var compactness: Double = 25
    @State private var iterations: Double = 10
    @State private var enforceConnectivity = true

    // K-means parameters
    @State private var nClusters: Double = 5
    @State private var useWeightedColors = true

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
                                Text("Layer \(index + 1)")
                                    .font(.caption)
                                Image(nsImage: layerImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .background(CheckerboardBackground())
                                    .frame(width: 256, height: 256)
                                    .border(Color.gray.opacity(0.3), width: 1)
                            }
                        }
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
        kmeansImage = nil
        layerImages = []
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
                var kmeansTime: Double = 0
                var layers: [NSImage] = []

                if let labBuffer = result.labBuffer,
                   let labelsBuffer = result.labelsBuffer {

                    let kmeansStartTime = CFAbsoluteTimeGetCurrent()

                    // Extract superpixels
                    let extractStart = CFAbsoluteTimeGetCurrent()
                    let superpixelData = SuperpixelProcessor.extractSuperpixels(
                        from: labBuffer,
                        labelsBuffer: labelsBuffer,
                        width: result.width,
                        height: result.height
                    )
                    let extractTime = CFAbsoluteTimeGetCurrent() - extractStart
                    #if DEBUG
                    print(String(format: "Extract superpixels: %.2f ms", extractTime * 1000))
                    #endif

                    // Perform K-means clustering
                    let clusterStart = CFAbsoluteTimeGetCurrent()
                    let kmeansParams = KMeansProcessor.Parameters(
                        numberOfClusters: Int(self.nClusters),
                        useWeightedColors: self.useWeightedColors
                    )

                    let clusterResult = KMeansProcessor.cluster(
                        superpixelData: superpixelData,
                        parameters: kmeansParams
                    )
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
                    self.kmeansImage = kmeansNSImage
                    self.layerImages = layers
                    self.processingTime = result.processingTime
                    self.kmeansProcessingTime = kmeansTime
                    self.lastProcessingResult = result
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
}

#Preview {
    ContentView()
}
