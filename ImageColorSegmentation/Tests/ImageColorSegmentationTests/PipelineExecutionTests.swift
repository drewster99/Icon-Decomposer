import XCTest
@testable import ImageColorSegmentation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class PipelineExecutionTests: XCTestCase {

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

    func testBasicPipelineExecution() async throws {
        let testImage = createTestImage()

        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5)
            .extractLayers()

        let result = try await pipeline.execute(input: testImage)

        XCTAssertNotNil(result)
        XCTAssertEqual(result.finalType, .layers)
        XCTAssertNotNil(result.buffer(named: "input"))
    }

    func testPipelineWithInputInInit() async throws {
        let testImage = createTestImage()

        let pipeline = try ImagePipeline(input: testImage)
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5)
            .extractLayers()

        let result = try await pipeline.execute(input: testImage)

        XCTAssertNotNil(result)
        XCTAssertEqual(result.finalType, .layers)
    }

    func testBatchExecution() async throws {
        let images = [
            createTestImage(width: 50, height: 50),
            createTestImage(width: 100, height: 100),
            createTestImage(width: 150, height: 150)
        ]

        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 100)
            .cluster(into: 5)
            .extractLayers()

        let results = try await pipeline.execute(inputs: images)

        XCTAssertEqual(results.count, 3)
        for result in results {
            XCTAssertEqual(result.finalType, .layers)
        }
    }

    func testMetadataPreservation() async throws {
        let testImage = createTestImage(width: 200, height: 150)

        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: .emphasizeGreens)
            .segment(superpixels: 500, compactness: 30)
            .cluster(into: 7, seed: 42)

        let result = try await pipeline.execute(input: testImage)

        let width: Int? = result.metadata(for: "width")
        let height: Int? = result.metadata(for: "height")
        let superpixelCount: Int? = result.metadata(for: "superpixelCount")
        let clusterCount: Int? = result.metadata(for: "clusterCount")
        let seed: Int? = result.metadata(for: "clusterSeed")

        XCTAssertEqual(width, 200)
        XCTAssertEqual(height, 150)
        XCTAssertEqual(superpixelCount, 500)
        XCTAssertEqual(clusterCount, 7)
        XCTAssertEqual(seed, 42)
    }
}
