import Foundation
import ImageColorSegmentation

#if os(macOS)
import AppKit
#endif

@main
struct DemoApp {
    static func main() async throws {
        print("=== ImageColorSegmentation Package Demo ===\n")

        // Create a simple test image
        #if os(macOS)
        let testImage = createTestImage()
        print("✅ Created test image (200x200)")
        #else
        print("❌ This demo requires macOS")
        return
        #endif

        // Example 1: Basic Pipeline
        print("\n📊 Example 1: Basic Pipeline")
        try await runBasicPipeline(testImage)

        // Example 2: Pipeline Branching
        print("\n🌿 Example 2: Pipeline Branching")
        try await runBranchingPipeline(testImage)

        // Example 3: Concurrent Branching
        print("\n⚡️ Example 3: Concurrent Branching")
        try await runConcurrentBranching(testImage)

        print("\n✨ All demos completed successfully!\n")
    }

    #if os(macOS)
    static func createTestImage() -> NSImage {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)

        image.lockFocus()

        // Create a gradient with multiple colors
        let colors = [
            NSColor.red,
            NSColor.green,
            NSColor.blue,
            NSColor.yellow,
            NSColor.purple
        ]

        let stripHeight = size.height / CGFloat(colors.count)

        for (index, color) in colors.enumerated() {
            color.setFill()
            let rect = NSRect(
                x: 0,
                y: CGFloat(index) * stripHeight,
                width: size.width,
                height: stripHeight
            )
            rect.fill()
        }

        image.unlockFocus()
        return image
    }

    static func runBasicPipeline(_ image: NSImage) async throws {
        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: .emphasizeGreens)
            .segment(superpixels: 100, compactness: 25)
            .cluster(into: 5, seed: 42)
            .extractLayers()

        let result = try await pipeline.execute(input: image)

        let width: Int? = result.metadata(for: "width")
        let height: Int? = result.metadata(for: "height")
        let superpixels: Int? = result.metadata(for: "superpixelCount")
        let clusters: Int? = result.metadata(for: "clusterCount")

        print("  ✅ Image: \(width ?? 0)x\(height ?? 0)")
        print("  ✅ Superpixels: \(superpixels ?? 0)")
        print("  ✅ Clusters: \(clusters ?? 0)")
        print("  ✅ Final type: \(result.finalType)")
    }

    static func runBranchingPipeline(_ image: NSImage) async throws {
        // Parent: expensive SLIC operation
        let slicPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let slicResult = try await slicPipeline.execute(input: image)
        print("  ✅ SLIC completed (shared across branches)")

        // Branch 1: 3 clusters
        let branch3 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 3, seed: 42)
            .extractLayers()

        let result3 = try await branch3.execute(from: slicResult)
        let count3: Int? = result3.metadata(for: "clusterCount")
        print("  ✅ Branch 1: \(count3 ?? 0) clusters")

        // Branch 2: 5 clusters
        let branch5 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5, seed: 42)
            .extractLayers()

        let result5 = try await branch5.execute(from: slicResult)
        let count5: Int? = result5.metadata(for: "clusterCount")
        print("  ✅ Branch 2: \(count5 ?? 0) clusters")

        print("  💡 SLIC computed only once, reused for both branches!")
    }

    static func runConcurrentBranching(_ image: NSImage) async throws {
        // Parent pipeline
        let slicPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let slicResult = try await slicPipeline.execute(input: image)
        print("  ✅ SLIC completed")

        // Create three branches
        let branch3 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 3)
            .extractLayers()

        let branch5 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5)
            .extractLayers()

        let branch7 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 7)
            .extractLayers()

        // Execute all concurrently
        async let r3 = branch3.execute(from: slicResult)
        async let r5 = branch5.execute(from: slicResult)
        async let r7 = branch7.execute(from: slicResult)

        let (result3, result5, result7) = try await (r3, r5, r7)

        let count3: Int? = result3.metadata(for: "clusterCount")
        let count5: Int? = result5.metadata(for: "clusterCount")
        let count7: Int? = result7.metadata(for: "clusterCount")

        print("  ✅ Branch 1: \(count3 ?? 0) clusters")
        print("  ✅ Branch 2: \(count5 ?? 0) clusters")
        print("  ✅ Branch 3: \(count7 ?? 0) clusters")
        print("  💡 All three branches executed concurrently!")
    }
    #endif
}
