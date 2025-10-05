import ImageColorSegmentation

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// MARK: - Example 1: Basic Pipeline

func basicPipeline() async throws {
    let image = PlatformImage(named: "test-icon")! // Your image

    let pipeline = try ImagePipeline()
        .convertColorSpace(to: .lab, scale: .emphasizeGreens)
        .segment(superpixels: 1000, compactness: 25)
        .cluster(into: 5, seed: 42)
        .extractLayers()

    let result = try await pipeline.execute(input: image)

    // Access results
    print("Final type: \(result.finalType)")
    if let clusterCount: Int = result.metadata(for: "clusterCount") {
        print("Found \(clusterCount) clusters")
    }
}

// MARK: - Example 2: Reusable Template

func reusableTemplate() async throws {
    let template = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 5, seed: 42)
        .extractLayers()

    // Process multiple images with same configuration
    let image1 = PlatformImage(named: "icon1")!
    let image2 = PlatformImage(named: "icon2")!
    let image3 = PlatformImage(named: "icon3")!

    let result1 = try await template.execute(input: image1)
    let result2 = try await template.execute(input: image2)
    let result3 = try await template.execute(input: image3)

    print("Processed \(3) images")
}

// MARK: - Example 3: Batch Processing

func batchProcessing() async throws {
    let images = [
        PlatformImage(named: "icon1")!,
        PlatformImage(named: "icon2")!,
        PlatformImage(named: "icon3")!
    ]

    let pipeline = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 5)
        .extractLayers()

    let results = try await pipeline.execute(inputs: images)

    for (index, result) in results.enumerated() {
        print("Image \(index): \(result.finalType)")
    }
}

// MARK: - Example 4: Pipeline Branching

func pipelineBranching() async throws {
    let image = PlatformImage(named: "icon")!

    // Create parent pipeline up to SLIC (expensive operation)
    let slicPipeline = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)

    let slicResult = try await slicPipeline.execute(input: image)

    // Branch 1: Try 3 clusters
    let branch3 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 3, seed: 42)
        .extractLayers()

    // Branch 2: Try 5 clusters
    let branch5 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 5, seed: 42)
        .extractLayers()

    // Branch 3: Try 7 clusters
    let branch7 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 7, seed: 42)
        .extractLayers()

    // Execute all branches (reusing SLIC results)
    let result3 = try await branch3.execute(from: slicResult)
    let result5 = try await branch5.execute(from: slicResult)
    let result7 = try await branch7.execute(from: slicResult)

    print("Generated 3, 5, and 7 layer variants - SLIC only computed once!")
}

// MARK: - Example 5: Concurrent Branching

func concurrentBranching() async throws {
    let image = PlatformImage(named: "icon")!

    // Parent pipeline
    let slicPipeline = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)

    let slicResult = try await slicPipeline.execute(input: image)

    // Create branches
    let branch3 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 3)
        .extractLayers()

    let branch5 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 5)
        .extractLayers()

    let branch7 = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 7)
        .extractLayers()

    // Execute all branches concurrently!
    async let r3 = branch3.execute(from: slicResult)
    async let r5 = branch5.execute(from: slicResult)
    async let r7 = branch7.execute(from: slicResult)

    let (result3, result5, result7) = try await (r3, r5, r7)

    print("All three variants computed in parallel!")
}

// MARK: - Example 6: Custom LAB Scaling

func customLABScaling() async throws {
    let image = PlatformImage(named: "icon")!

    // Emphasize greens (common for nature/foliage)
    let greenPipeline = try ImagePipeline()
        .convertColorSpace(to: .lab, scale: .emphasizeGreens)  // b-axis scaled 2x
        .segment(superpixels: 1000)
        .cluster(into: 5)

    // Custom scaling for specific use case
    let customPipeline = try ImagePipeline()
        .convertColorSpace(to: .lab, scale: LABScale(l: 1.0, a: 1.5, b: 2.5))
        .segment(superpixels: 1000)
        .cluster(into: 5)

    let result1 = try await greenPipeline.execute(input: image)
    let result2 = try await customPipeline.execute(input: image)

    print("Processed with different LAB scalings")
}

// MARK: - Example 7: Multi-Stage Merging

func multiStageMerging() async throws {
    let image = PlatformImage(named: "icon")!

    let pipeline = try ImagePipeline()
        .convertColorSpace(to: .lab)
        .segment(superpixels: 1000)
        .cluster(into: 20)          // Start with many clusters
        .autoMerge(threshold: 0.20) // First merge pass
        .autoMerge(threshold: 0.35) // Second merge pass
        .extractLayers()

    let result = try await pipeline.execute(input: image)

    if let finalCount: Int = result.metadata(for: "clusterCount") {
        print("Reduced from 20 to \(finalCount) clusters through merging")
    }
}

// MARK: - Main

@main
struct ExampleApp {
    static func main() async throws {
        print("=== ImageColorSegmentation Examples ===\n")

        // Run examples
         try await basicPipeline()
        // try await reusableTemplate()
        // try await batchProcessing()
        // try await pipelineBranching()
        // try await concurrentBranching()
        // try await customLABScaling()
        // try await multiStageMerging()

        print("\nAll examples completed!")
    }
}
