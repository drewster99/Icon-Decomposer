import XCTest
@testable import ImageColorSegmentation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class PipelineBranchingTests: XCTestCase {

    func createTestImage(width: Int = 100, height: Int = 100) -> PlatformImage {
        #if os(macOS)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
        #else
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        #endif
    }

    func testBasicBranching() async throws {
        let testImage = createTestImage()

        // Create parent pipeline up to segmentation
        let parentPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let parentResult = try await parentPipeline.execute(input: testImage)

        // Branch 1: cluster into 3
        let branch1 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 3, seed: 42)
            .extractLayers()

        let result1 = try await branch1.execute(from: parentResult)

        // Branch 2: cluster into 5
        let branch2 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5, seed: 42)
            .extractLayers()

        let result2 = try await branch2.execute(from: parentResult)

        // Both should have different cluster counts
        let clusterCount1: Int? = result1.metadata(for: "clusterCount")
        let clusterCount2: Int? = result2.metadata(for: "clusterCount")

        XCTAssertEqual(clusterCount1, 3)
        XCTAssertEqual(clusterCount2, 5)

        // Both should share the same SLIC results (same superpixel count)
        let superpixelCount1: Int? = result1.metadata(for: "superpixelCount")
        let superpixelCount2: Int? = result2.metadata(for: "superpixelCount")

        XCTAssertEqual(superpixelCount1, 100)
        XCTAssertEqual(superpixelCount2, 100)
    }

    func testConcurrentBranching() async throws {
        let testImage = createTestImage()

        // Create parent pipeline
        let parentPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let parentResult = try await parentPipeline.execute(input: testImage)

        // Create multiple branches
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

        // Execute all branches concurrently
        async let result3 = branch3.execute(from: parentResult)
        async let result5 = branch5.execute(from: parentResult)
        async let result7 = branch7.execute(from: parentResult)

        let (r3, r5, r7) = try await (result3, result5, result7)

        // Verify results
        let count3: Int? = r3.metadata(for: "clusterCount")
        let count5: Int? = r5.metadata(for: "clusterCount")
        let count7: Int? = r7.metadata(for: "clusterCount")

        XCTAssertEqual(count3, 3)
        XCTAssertEqual(count5, 5)
        XCTAssertEqual(count7, 7)
    }

    func testBranchingWithDifferentSeeds() async throws {
        let testImage = createTestImage()

        // Parent pipeline
        let parentPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let parentResult = try await parentPipeline.execute(input: testImage)

        // Branch with seed 42
        let branch1 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5, seed: 42)

        // Branch with seed 99
        let branch2 = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5, seed: 99)

        let result1 = try await branch1.execute(from: parentResult)
        let result2 = try await branch2.execute(from: parentResult)

        // Both should have same cluster count
        let clusterCount1: Int? = result1.metadata(for: "clusterCount")
        let clusterCount2: Int? = result2.metadata(for: "clusterCount")

        XCTAssertEqual(clusterCount1, 5)
        XCTAssertEqual(clusterCount2, 5)

        // But different seeds
        let seed1: Int? = result1.metadata(for: "clusterSeed")
        let seed2: Int? = result2.metadata(for: "clusterSeed")

        XCTAssertEqual(seed1, 42)
        XCTAssertEqual(seed2, 99)
    }

    func testDeepBranching() async throws {
        let testImage = createTestImage()

        // Parent: up to segmentation
        let slicPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)

        let slicResult = try await slicPipeline.execute(input: testImage)

        // Middle branch: add clustering
        let clusterPipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 10)

        let clusterResult = try await clusterPipeline.execute(from: slicResult)

        // Deep branch: add merging
        let mergePipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 10)
            .autoMerge(threshold: 0.3)

        let mergeResult = try await mergePipeline.execute(from: clusterResult)

        // Verify all levels
        let slicSuperpixels: Int? = slicResult.metadata(for: "superpixelCount")
        let clusterCount: Int? = clusterResult.metadata(for: "clusterCount")
        let mergeThreshold: Float? = mergeResult.metadata(for: "mergeThreshold")

        XCTAssertEqual(slicSuperpixels, 100)
        XCTAssertEqual(clusterCount, 10)
        XCTAssertEqual(mergeThreshold, 0.3)
    }
}
