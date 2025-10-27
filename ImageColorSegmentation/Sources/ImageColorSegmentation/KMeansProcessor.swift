//
//  KMeansProcessor.swift
//  ImageColorSegmentation
//
//  Metal-based K-means++ clustering implementation for superpixels
//

import Foundation
import Metal
import simd

/// Parameters for K-means (matches Metal struct)
struct KMeansParams {
    let numPoints: UInt32
    let numClusters: UInt32
    let iteration: UInt32
    let convergenceThreshold: Float
}

/// Handles K-means clustering of superpixel features using Metal
public class KMeansProcessor {

    private let device: MTLDevice
    private let library: MTLLibrary
    private let commandQueue: MTLCommandQueue

    // Metal compute pipelines
    private var calculateMinDistancesPipeline: MTLComputePipelineState
    private var calculateDistanceSquaredProbabilitiesPipeline: MTLComputePipelineState
    private var assignPointsToClustersPipeline: MTLComputePipelineState
    private var clearClusterAccumulatorsPipeline: MTLComputePipelineState
    private var accumulateClusterDataPipeline: MTLComputePipelineState
    private var updateClusterCentersPipeline: MTLComputePipelineState
    private var checkConvergencePipeline: MTLComputePipelineState
    private var applyColorWeightingPipeline: MTLComputePipelineState

    public init(device: MTLDevice, library: MTLLibrary, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.library = library
        self.commandQueue = commandQueue

        // Create all pipelines
        self.calculateMinDistancesPipeline = try Self.createPipeline(library: library, device: device, name: "calculateMinDistances")
        self.calculateDistanceSquaredProbabilitiesPipeline = try Self.createPipeline(library: library, device: device, name: "calculateDistanceSquaredProbabilities")
        self.assignPointsToClustersPipeline = try Self.createPipeline(library: library, device: device, name: "assignPointsToClusters")
        self.clearClusterAccumulatorsPipeline = try Self.createPipeline(library: library, device: device, name: "clearClusterAccumulators")
        self.accumulateClusterDataPipeline = try Self.createPipeline(library: library, device: device, name: "accumulateClusterData")
        self.updateClusterCentersPipeline = try Self.createPipeline(library: library, device: device, name: "updateClusterCenters")
        self.checkConvergencePipeline = try Self.createPipeline(library: library, device: device, name: "checkConvergence")
        self.applyColorWeightingPipeline = try Self.createPipeline(library: library, device: device, name: "applyColorWeighting")
    }

    private static func createPipeline(library: MTLLibrary, device: MTLDevice, name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw PipelineError.executionFailed("Failed to find Metal function: \(name)")
        }
        return try device.makeComputePipelineState(function: function)
    }

    /// Result of K-means clustering
    public struct ClusteringResult {
        public let clusterAssignments: [Int32]
        public let clusterCenters: [SIMD3<Float>]
        public let numberOfClusters: Int
        public let iterations: Int
        public let converged: Bool
    }

    /// Perform K-means++ clustering on superpixel colors
    public func cluster(
        superpixelColors: [SIMD3<Float>],
        numberOfClusters: Int,
        lightnessWeight: Float,
        maxIterations: Int = 300,
        convergenceDistance: Float = 0.01,
        seed: Int? = nil
    ) throws -> ClusteringResult {

        let numPoints = superpixelColors.count
        let numClusters = numberOfClusters

        // Set random seed if provided
        if let seed = seed {
            srand48(seed)
        }

        // Create Metal buffers
        guard let originalColorsBuffer = device.makeBuffer(
            bytes: superpixelColors,
            length: MemoryLayout<SIMD3<Float>>.size * numPoints,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create colors buffer")
        }

        // Apply color weighting (reduce L channel influence, enhance green separation)
        let colorsBuffer = try applyWeighting(
            originalColors: originalColorsBuffer,
            lightnessWeight: lightnessWeight,
            greenAxisScale: 2.0,
            numPoints: numPoints
        )

        // Initialize centers using K-means++
        let initialCenters = try initializeKMeansPlusPlus(
            colors: colorsBuffer,
            numPoints: numPoints,
            numClusters: numClusters
        )

        // Create buffers for main iteration
        var centersBuffer = device.makeBuffer(
            bytes: initialCenters,
            length: MemoryLayout<SIMD3<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        var newCentersBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        let assignmentsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numPoints,
            options: .storageModeShared
        )!

        let distancesBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numPoints,
            options: .storageModeShared
        )!

        let clusterSumsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numClusters * 3,
            options: .storageModeShared
        )!

        let clusterCountsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numClusters,
            options: .storageModeShared
        )!

        let centerDeltasBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numClusters,
            options: .storageModeShared
        )!

        let totalDeltaBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size,
            options: .storageModeShared
        )!

        // Main K-means iteration
        var converged = false
        var iterations = 0

        while iterations < maxIterations && !converged {
            // Assign points to clusters
            try assignPointsToClusters(
                points: colorsBuffer,
                centers: centersBuffer,
                assignments: assignmentsBuffer,
                distances: distancesBuffer,
                numPoints: numPoints,
                numClusters: numClusters
            )

            // Update cluster centers
            try clearClusterAccumulators(
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                numClusters: numClusters
            )

            try accumulateClusterData(
                points: colorsBuffer,
                assignments: assignmentsBuffer,
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                numPoints: numPoints,
                numClusters: numClusters
            )

            try updateClusterCenters(
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                newCenters: newCentersBuffer,
                oldCenters: centersBuffer,
                centerDeltas: centerDeltasBuffer,
                numClusters: numClusters
            )

            // Check convergence
            totalDeltaBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee = 0
            try checkConvergence(
                centerDeltas: centerDeltasBuffer,
                totalDelta: totalDeltaBuffer,
                numClusters: numClusters
            )

            let totalDelta = totalDeltaBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee
            converged = totalDelta < convergenceDistance

            // Swap buffers
            let temp = centersBuffer
            centersBuffer = newCentersBuffer
            newCentersBuffer = temp

            iterations += 1
        }

        // Extract final results
        let finalAssignments = extractAssignments(buffer: assignmentsBuffer, count: numPoints)

        // Recalculate centers from original (unweighted) colors
        let finalCenters = try recalculateUnweightedCenters(
            clusterAssignments: finalAssignments,
            originalColors: superpixelColors,
            numClusters: numClusters
        )

        return ClusteringResult(
            clusterAssignments: finalAssignments,
            clusterCenters: finalCenters,
            numberOfClusters: numClusters,
            iterations: iterations,
            converged: converged
        )
    }

    // MARK: - KMeans++ Initialization

    private func initializeKMeansPlusPlus(
        colors: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) throws -> [SIMD3<Float>] {

        var centers: [SIMD3<Float>] = []
        let colorsPointer = colors.contents().bindMemory(to: SIMD3<Float>.self, capacity: numPoints)

        // Choose first center randomly
        let firstIndex = Int(drand48() * Double(numPoints))
        centers.append(colorsPointer[firstIndex])

        // Choose remaining centers
        for _ in 1..<numClusters {
            // Create buffer for current centers
            guard let currentCentersBuffer = device.makeBuffer(
                bytes: centers,
                length: MemoryLayout<SIMD3<Float>>.size * centers.count,
                options: .storageModeShared
            ) else {
                throw PipelineError.executionFailed("Failed to create current centers buffer")
            }

            // Calculate min distances
            guard let minDistancesBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size * numPoints,
                options: .storageModeShared
            ) else {
                throw PipelineError.executionFailed("Failed to create min distances buffer")
            }

            try calculateMinDistancesToCenters(
                points: colors,
                centers: currentCentersBuffer,
                minDistances: minDistancesBuffer,
                numPoints: numPoints,
                numCenters: centers.count
            )

            // Calculate D² probabilities
            guard let probabilitiesBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size * numPoints,
                options: .storageModeShared
            ),
            let totalSumBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size,
                options: .storageModeShared
            ) else {
                throw PipelineError.executionFailed("Failed to create probability buffers")
            }

            totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee = 0

            try calculateDistanceSquaredProbabilities(
                minDistances: minDistancesBuffer,
                probabilities: probabilitiesBuffer,
                totalSum: totalSumBuffer,
                numPoints: numPoints
            )

            // Sample next center
            let probabilities = probabilitiesBuffer.contents().bindMemory(to: Float.self, capacity: numPoints)
            let totalSum = totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee

            var cumulative: [Float] = []
            var sum: Float = 0
            for i in 0..<numPoints {
                sum += probabilities[i]
                cumulative.append(sum / totalSum)
            }

            let random = Float(drand48())
            var selectedIndex = numPoints - 1
            for i in 0..<numPoints {
                if cumulative[i] >= random {
                    selectedIndex = i
                    break
                }
            }

            centers.append(colorsPointer[selectedIndex])
        }

        return centers
    }

    // MARK: - Helper Functions

    private func extractAssignments(buffer: MTLBuffer, count: Int) -> [Int32] {
        let pointer = buffer.contents().bindMemory(to: Int32.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func recalculateUnweightedCenters(
        clusterAssignments: [Int32],
        originalColors: [SIMD3<Float>],
        numClusters: Int
    ) throws -> [SIMD3<Float>] {

        var clusterSums = Array(repeating: SIMD3<Float>(0, 0, 0), count: numClusters)
        var clusterCounts = Array(repeating: 0, count: numClusters)

        for (i, assignment) in clusterAssignments.enumerated() {
            let clusterId = Int(assignment)
            guard clusterId >= 0 && clusterId < numClusters else { continue }
            clusterSums[clusterId] += originalColors[i]
            clusterCounts[clusterId] += 1
        }

        var centers: [SIMD3<Float>] = []
        for i in 0..<numClusters {
            if clusterCounts[i] > 0 {
                centers.append(clusterSums[i] / Float(clusterCounts[i]))
            } else {
                centers.append(SIMD3<Float>(0, 0, 0))
            }
        }

        return centers
    }

    // MARK: - Metal Kernel Dispatch Functions

    private func applyWeighting(
        originalColors: MTLBuffer,
        lightnessWeight: Float,
        greenAxisScale: Float,
        numPoints: Int
    ) throws -> MTLBuffer {

        guard let weightedColorsBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.size * numPoints,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create weighted colors buffer")
        }

        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: 0,
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(applyColorWeightingPipeline)
        encoder.setBuffer(originalColors, offset: 0, index: 0)
        encoder.setBuffer(weightedColorsBuffer, offset: 0, index: 1)
        var weight = lightnessWeight
        encoder.setBytes(&weight, length: MemoryLayout<Float>.size, index: 2)
        var greenScale = greenAxisScale
        encoder.setBytes(&greenScale, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 4)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return weightedColorsBuffer
    }

    private func calculateMinDistancesToCenters(
        points: MTLBuffer,
        centers: MTLBuffer,
        minDistances: MTLBuffer,
        numPoints: Int,
        numCenters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numCenters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(calculateMinDistancesPipeline)
        encoder.setBuffer(points, offset: 0, index: 0)
        encoder.setBuffer(centers, offset: 0, index: 1)
        encoder.setBuffer(minDistances, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 3)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func calculateDistanceSquaredProbabilities(
        minDistances: MTLBuffer,
        probabilities: MTLBuffer,
        totalSum: MTLBuffer,
        numPoints: Int
    ) throws {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: 0,
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(calculateDistanceSquaredProbabilitiesPipeline)
        encoder.setBuffer(minDistances, offset: 0, index: 0)
        encoder.setBuffer(probabilities, offset: 0, index: 1)
        encoder.setBuffer(totalSum, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 3)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func assignPointsToClusters(
        points: MTLBuffer,
        centers: MTLBuffer,
        assignments: MTLBuffer,
        distances: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(assignPointsToClustersPipeline)
        encoder.setBuffer(points, offset: 0, index: 0)
        encoder.setBuffer(centers, offset: 0, index: 1)
        encoder.setBuffer(assignments, offset: 0, index: 2)
        encoder.setBuffer(distances, offset: 0, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 4)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func clearClusterAccumulators(
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        numClusters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(clearClusterAccumulatorsPipeline)
        encoder.setBuffer(clusterSums, offset: 0, index: 0)
        encoder.setBuffer(clusterCounts, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 2)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulateClusterData(
        points: MTLBuffer,
        assignments: MTLBuffer,
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(accumulateClusterDataPipeline)
        encoder.setBuffer(points, offset: 0, index: 0)
        encoder.setBuffer(assignments, offset: 0, index: 1)
        encoder.setBuffer(clusterSums, offset: 0, index: 2)
        encoder.setBuffer(clusterCounts, offset: 0, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 4)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func updateClusterCenters(
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        newCenters: MTLBuffer,
        oldCenters: MTLBuffer,
        centerDeltas: MTLBuffer,
        numClusters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(updateClusterCentersPipeline)
        encoder.setBuffer(clusterSums, offset: 0, index: 0)
        encoder.setBuffer(clusterCounts, offset: 0, index: 1)
        encoder.setBuffer(newCenters, offset: 0, index: 2)
        encoder.setBuffer(oldCenters, offset: 0, index: 3)
        encoder.setBuffer(centerDeltas, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 5)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func checkConvergence(
        centerDeltas: MTLBuffer,
        totalDelta: MTLBuffer,
        numClusters: Int
    ) throws {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(checkConvergencePipeline)
        encoder.setBuffer(centerDeltas, offset: 0, index: 0)
        encoder.setBuffer(totalDelta, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 2)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - 5D Clustering (Color + Spatial) for Split Layer

    /// Perform K-means++ clustering on superpixel colors AND spatial positions
    /// This is a NEW method for split layer functionality - does not modify existing cluster() method
    /// - Parameters:
    ///   - superpixelColors: LAB color values
    ///   - superpixelPositions: Normalized XY positions (0-100 scale)
    ///   - numberOfClusters: K value
    ///   - colorWeight: Weight for color distance (0-1)
    ///   - spatialWeight: Weight for spatial distance (0-1)
    ///   - maxIterations: Maximum iterations
    ///   - convergenceDistance: Convergence threshold
    ///   - seed: Random seed
    /// - Returns: Clustering result with assignments
    public func clusterWithSpatial(
        superpixelColors: [SIMD3<Float>],
        superpixelPositions: [SIMD2<Float>],
        numberOfClusters: Int,
        colorWeight: Float,
        spatialWeight: Float,
        maxIterations: Int = 300,
        convergenceDistance: Float = 0.01,
        seed: Int? = nil
    ) throws -> ClusteringResult {

        let numPoints = superpixelColors.count
        let numClusters = numberOfClusters

        guard superpixelColors.count == superpixelPositions.count else {
            throw PipelineError.executionFailed("Color and position arrays must have same length")
        }

        // Set random seed if provided
        if let seed = seed {
            srand48(seed)
        }

        // Create Metal buffers for colors and positions
        guard let colorsBuffer = device.makeBuffer(
            bytes: superpixelColors,
            length: MemoryLayout<SIMD3<Float>>.size * numPoints,
            options: .storageModeShared
        ),
        let positionsBuffer = device.makeBuffer(
            bytes: superpixelPositions,
            length: MemoryLayout<SIMD2<Float>>.size * numPoints,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create input buffers")
        }

        // Initialize centers using K-means++ (using just colors for initialization)
        let initialColorCenters = try initializeKMeansPlusPlus(
            colors: colorsBuffer,
            numPoints: numPoints,
            numClusters: numClusters
        )

        // Initialize spatial centers by finding superpixels closest to color centers
        var initialSpatialCenters: [SIMD2<Float>] = []
        for colorCenter in initialColorCenters {
            // Find superpixel with closest color
            var minDist: Float = .infinity
            var closestIdx = 0
            for (idx, color) in superpixelColors.enumerated() {
                let dist = simd_distance(color, colorCenter)
                if dist < minDist {
                    minDist = dist
                    closestIdx = idx
                }
            }
            initialSpatialCenters.append(superpixelPositions[closestIdx])
        }

        // Create buffers for centers
        var colorCentersBuffer = device.makeBuffer(
            bytes: initialColorCenters,
            length: MemoryLayout<SIMD3<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        var spatialCentersBuffer = device.makeBuffer(
            bytes: initialSpatialCenters,
            length: MemoryLayout<SIMD2<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        var newColorCentersBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        var newSpatialCentersBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD2<Float>>.size * numClusters,
            options: .storageModeShared
        )!

        let assignmentsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numPoints,
            options: .storageModeShared
        )!

        let distancesBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numPoints,
            options: .storageModeShared
        )!

        let colorSumsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numClusters * 3,
            options: .storageModeShared
        )!

        let spatialSumsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numClusters * 2,
            options: .storageModeShared
        )!

        let clusterCountsBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size * numClusters,
            options: .storageModeShared
        )!

        let centerDeltasBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size * numClusters,
            options: .storageModeShared
        )!

        let totalDeltaBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.size,
            options: .storageModeShared
        )!

        // Create pipeline states for 5D kernels
        let assignPointsPipeline = try Self.createPipeline(library: library, device: device, name: "assignPointsToClusters5D")
        let accumulatePipeline = try Self.createPipeline(library: library, device: device, name: "accumulateClusterData5D")
        let updateCentersPipeline = try Self.createPipeline(library: library, device: device, name: "updateClusterCenters5D")

        // Main iteration loop
        var iteration = 0
        var converged = false

        for i in 0..<maxIterations {
            iteration = i

            // Assignment step
            try assignPointsToCluster5D(
                colorsBuffer: colorsBuffer,
                positionsBuffer: positionsBuffer,
                colorCentersBuffer: colorCentersBuffer,
                spatialCentersBuffer: spatialCentersBuffer,
                assignmentsBuffer: assignmentsBuffer,
                distancesBuffer: distancesBuffer,
                pipeline: assignPointsPipeline,
                numPoints: numPoints,
                numClusters: numClusters,
                colorWeight: colorWeight,
                spatialWeight: spatialWeight
            )

            // Clear accumulators
            memset(colorSumsBuffer.contents(), 0, colorSumsBuffer.length)
            memset(spatialSumsBuffer.contents(), 0, spatialSumsBuffer.length)
            memset(clusterCountsBuffer.contents(), 0, clusterCountsBuffer.length)

            // Accumulate cluster data
            try accumulateClusterData5D(
                colorsBuffer: colorsBuffer,
                positionsBuffer: positionsBuffer,
                assignmentsBuffer: assignmentsBuffer,
                colorSumsBuffer: colorSumsBuffer,
                spatialSumsBuffer: spatialSumsBuffer,
                clusterCountsBuffer: clusterCountsBuffer,
                pipeline: accumulatePipeline,
                numPoints: numPoints,
                numClusters: numClusters,
                colorWeight: colorWeight,
                spatialWeight: spatialWeight
            )

            // Update centers
            try updateClusterCenters5D(
                colorSumsBuffer: colorSumsBuffer,
                spatialSumsBuffer: spatialSumsBuffer,
                clusterCountsBuffer: clusterCountsBuffer,
                newColorCentersBuffer: newColorCentersBuffer,
                newSpatialCentersBuffer: newSpatialCentersBuffer,
                oldColorCentersBuffer: colorCentersBuffer,
                oldSpatialCentersBuffer: spatialCentersBuffer,
                centerDeltasBuffer: centerDeltasBuffer,
                pipeline: updateCentersPipeline,
                numClusters: numClusters,
                colorWeight: colorWeight,
                spatialWeight: spatialWeight
            )

            // Check convergence
            memset(totalDeltaBuffer.contents(), 0, totalDeltaBuffer.length)
            try checkConvergence(
                centerDeltas: centerDeltasBuffer,
                totalDelta: totalDeltaBuffer,
                numClusters: numClusters
            )

            let totalDelta = totalDeltaBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee
            if totalDelta < convergenceDistance {
                converged = true
                break
            }

            // Swap buffers
            swap(&colorCentersBuffer, &newColorCentersBuffer)
            swap(&spatialCentersBuffer, &newSpatialCentersBuffer)
        }

        // Extract final results
        let assignmentsPointer = assignmentsBuffer.contents().bindMemory(to: Int32.self, capacity: numPoints)
        let clusterAssignments = Array(UnsafeBufferPointer(start: assignmentsPointer, count: numPoints))

        let colorCentersPointer = colorCentersBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: numClusters)
        let clusterCenters = Array(UnsafeBufferPointer(start: colorCentersPointer, count: numClusters))

        return ClusteringResult(
            clusterAssignments: clusterAssignments,
            clusterCenters: clusterCenters,
            numberOfClusters: numClusters,
            iterations: iteration + 1,
            converged: converged
        )
    }

    // MARK: - 5D Clustering Helper Methods

    private func assignPointsToCluster5D(
        colorsBuffer: MTLBuffer,
        positionsBuffer: MTLBuffer,
        colorCentersBuffer: MTLBuffer,
        spatialCentersBuffer: MTLBuffer,
        assignmentsBuffer: MTLBuffer,
        distancesBuffer: MTLBuffer,
        pipeline: MTLComputePipelineState,
        numPoints: Int,
        numClusters: Int,
        colorWeight: Float,
        spatialWeight: Float
    ) throws {
        var params = KMeansParams5D(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0,
            colorWeight: colorWeight,
            spatialWeight: spatialWeight
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(colorsBuffer, offset: 0, index: 0)
        encoder.setBuffer(positionsBuffer, offset: 0, index: 1)
        encoder.setBuffer(colorCentersBuffer, offset: 0, index: 2)
        encoder.setBuffer(spatialCentersBuffer, offset: 0, index: 3)
        encoder.setBuffer(assignmentsBuffer, offset: 0, index: 4)
        encoder.setBuffer(distancesBuffer, offset: 0, index: 5)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams5D>.size, index: 6)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulateClusterData5D(
        colorsBuffer: MTLBuffer,
        positionsBuffer: MTLBuffer,
        assignmentsBuffer: MTLBuffer,
        colorSumsBuffer: MTLBuffer,
        spatialSumsBuffer: MTLBuffer,
        clusterCountsBuffer: MTLBuffer,
        pipeline: MTLComputePipelineState,
        numPoints: Int,
        numClusters: Int,
        colorWeight: Float,
        spatialWeight: Float
    ) throws {
        var params = KMeansParams5D(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0,
            colorWeight: colorWeight,
            spatialWeight: spatialWeight
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(colorsBuffer, offset: 0, index: 0)
        encoder.setBuffer(positionsBuffer, offset: 0, index: 1)
        encoder.setBuffer(assignmentsBuffer, offset: 0, index: 2)
        encoder.setBuffer(colorSumsBuffer, offset: 0, index: 3)
        encoder.setBuffer(spatialSumsBuffer, offset: 0, index: 4)
        encoder.setBuffer(clusterCountsBuffer, offset: 0, index: 5)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams5D>.size, index: 6)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numPoints + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func updateClusterCenters5D(
        colorSumsBuffer: MTLBuffer,
        spatialSumsBuffer: MTLBuffer,
        clusterCountsBuffer: MTLBuffer,
        newColorCentersBuffer: MTLBuffer,
        newSpatialCentersBuffer: MTLBuffer,
        oldColorCentersBuffer: MTLBuffer,
        oldSpatialCentersBuffer: MTLBuffer,
        centerDeltasBuffer: MTLBuffer,
        pipeline: MTLComputePipelineState,
        numClusters: Int,
        colorWeight: Float,
        spatialWeight: Float
    ) throws {
        var params = KMeansParams5D(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0,
            colorWeight: colorWeight,
            spatialWeight: spatialWeight
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.executionFailed("Failed to create command buffer/encoder")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(colorSumsBuffer, offset: 0, index: 0)
        encoder.setBuffer(spatialSumsBuffer, offset: 0, index: 1)
        encoder.setBuffer(clusterCountsBuffer, offset: 0, index: 2)
        encoder.setBuffer(newColorCentersBuffer, offset: 0, index: 3)
        encoder.setBuffer(newSpatialCentersBuffer, offset: 0, index: 4)
        encoder.setBuffer(oldColorCentersBuffer, offset: 0, index: 5)
        encoder.setBuffer(oldSpatialCentersBuffer, offset: 0, index: 6)
        encoder.setBuffer(centerDeltasBuffer, offset: 0, index: 7)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams5D>.size, index: 8)

        let threadsPerThreadgroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 255) / 256,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // Params struct for 5D clustering (matches Metal struct)
    private struct KMeansParams5D {
        let numPoints: UInt32
        let numClusters: UInt32
        let iteration: UInt32
        let convergenceThreshold: Float
        let colorWeight: Float
        let spatialWeight: Float
    }
}
