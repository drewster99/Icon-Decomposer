import XCTest
@testable import ImageColorSegmentation

final class PipelineConfigurationTests: XCTestCase {

    func testPipelineCreation() throws {
        // Should be able to create a pipeline without an image
        let pipeline = ImagePipeline()
        XCTAssertNotNil(pipeline)
    }

    func testValidOperationSequence() throws {
        // Valid sequence: RGBA -> LAB -> Superpixels -> Clusters -> Layers
        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 1000)
            .cluster(into: 5)
            .extractLayers()

        XCTAssertNotNil(pipeline)
    }

    func testInvalidOperationSequence() throws {
        // Should fail: can't segment after extracting layers (backwards flow)
        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 1000)
            .cluster(into: 5)
            .extractLayers()

        XCTAssertThrowsError(try pipeline.segment(superpixels: 500)) { error in
            guard case PipelineError.incompatibleDataTypes = error else {
                XCTFail("Expected incompatibleDataTypes error")
                return
            }
        }
    }

    func testMultipleMergeOperations() throws {
        // Should allow multiple merge operations in sequence
        let pipeline = try ImagePipeline()
            .convertColorSpace(to: .lab)
            .segment(superpixels: 1000)
            .cluster(into: 20)
            .autoMerge(threshold: 0.20)
            .autoMerge(threshold: 0.35)
            .extractLayers()

        XCTAssertNotNil(pipeline)
    }

    func testLABScaling() throws {
        // Test different LAB scale configurations
        let defaultScale = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: .default)

        let greenScale = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: .emphasizeGreens)

        let customScale = try ImagePipeline()
            .convertColorSpace(to: .lab, scale: LABScale(l: 1.0, a: 1.5, b: 2.5))

        XCTAssertNotNil(defaultScale)
        XCTAssertNotNil(greenScale)
        XCTAssertNotNil(customScale)
    }

    func testDataTypeValidation() {
        // Test DataType validation logic
        XCTAssertTrue(DataType.rgbaImage.canFeedInto(.labImage))
        XCTAssertTrue(DataType.labImage.canFeedInto(.superpixelFeatures))
        XCTAssertTrue(DataType.superpixelFeatures.canFeedInto(.clusterAssignments))
        XCTAssertTrue(DataType.clusterAssignments.canFeedInto(.layers))

        XCTAssertFalse(DataType.rgbaImage.canFeedInto(.clusterAssignments))
        XCTAssertFalse(DataType.layers.canFeedInto(.rgbaImage))
    }
}
