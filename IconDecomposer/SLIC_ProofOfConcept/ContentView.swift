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
    @State private var processingTime: Double = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // Test image names (will be added to Assets.xcassets)
    let testImageNames = ["TestIcon1", "TestIcon2", "TestIcon3", "TestIcon4"]

    // SLIC parameters (matching Python defaults)
    @State private var nSegments: Double = 1000
    @State private var compactness: Double = 25
    @State private var iterations: Double = 10
    @State private var enforceConnectivity = true

    private let processor = SLICProcessor()

    var body: some View {
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
                }
                .frame(maxWidth: 600)

                // Process button
                Button(action: processImage) {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    } else {
                        Text("Process Image")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || originalImage == nil)

                // Performance metrics - always rendered to reserve space
                VStack(spacing: 5) {
                    Text("Processing Time: \(String(format: "%.3f", processingTime)) seconds")
                        .font(.headline)
                    let fps = Int(processingTime > 0.0 ? 1.0/processingTime : 0.0)
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
            HStack(spacing: 20) {
                VStack {
                    Text("Original")
                        .font(.headline)
                    if let original = originalImage {
                        Image(nsImage: original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(CheckerboardBackground())
                            .frame(maxWidth: 512, maxHeight: 512)
                            .border(Color.gray.opacity(0.3), width: 1)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .aspectRatio(1.0, contentMode: .fit)
                            .frame(maxWidth: 512, maxHeight: 512)
                            .overlay(
                                Text("No image loaded")
                                    .foregroundColor(.gray)
                            )
                    }
                }

                VStack {
                    Text("Segmented (Boundaries)")
                        .font(.headline)
                    if let segmented = segmentedImage {
                        GeometryReader { geometry in
                            Image(nsImage: segmented)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .background(CheckerboardBackground())
                                .frame(width: min(512, geometry.size.width),
                                       height: min(512, geometry.size.height))
                        }
                        .frame(maxWidth: 512, maxHeight: 512)
                        .border(Color.gray.opacity(0.3), width: 1)
                    } else if let original = originalImage {
                        // Use original image with opacity 0 to maintain exact size
                        Image(nsImage: original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0)
                            .background(CheckerboardBackground())
                            .overlay(
                                Rectangle()
                                    .fill(Color.gray.opacity(0.1))
                                    .overlay(
                                        Text("Process an image to see results")
                                            .foregroundColor(.gray)
                                    )
                            )
                            .frame(maxWidth: 512, maxHeight: 512)
                            .border(Color.gray.opacity(0.3), width: 1)
                    } else {
                        // No original image loaded
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .aspectRatio(1.0, contentMode: .fit)
                            .frame(maxWidth: 512, maxHeight: 512)
                            .overlay(
                                Text("Process an image to see results")
                                    .foregroundColor(.gray)
                            )
                            .border(Color.gray.opacity(0.3), width: 1)
                    }
                }
            }
            .padding()

            Spacer()
        }
        .padding()
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            loadSelectedImage()
        }
    }

    private func loadSelectedImage() {
        errorMessage = nil
        segmentedImage = nil
        processingTime = 0

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
        guard let image = originalImage,
              let processor = processor else {
            errorMessage = processor == nil ? "Metal processor not available" : "No image available"
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
                DispatchQueue.main.async {
                    print("Processing succeeded")
                    print("Segmented image size: \(result.1.size)")
                    print("Segmented image isValid: \(result.1.isValid)")
                    print("Segmented image representations: \(result.1.representations)")
                    self.segmentedImage = result.1  // result.segmented is the second element in tuple
                    self.processingTime = result.2   // result.processingTime is the third element
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
}

#Preview {
    ContentView()
}
