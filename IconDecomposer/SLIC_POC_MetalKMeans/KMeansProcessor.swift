//
//  KMeansProcessor.swift
//  SLIC_POC_MetalKMeans
//
//  Metal-based KMeans++ clustering implementation for superpixels.
//  This replaces SwiftKMeansPlusPlus with a GPU-accelerated version.
//

import Foundation
import Metal
import MetalKit
import simd

/// Handles K-means clustering of superpixel features using Metal
class KMeansProcessor {

    /// Snapshot of K-means state at a particular iteration
    struct IterationSnapshot {
        let iterationNumber: Int
        let clusterAssignments: [Int]
        let clusterCenters: [SIMD3<Float>]
        let visualizationImage: NSImage
        let layerImages: [NSImage]
    }

    /// Result of K-means clustering
    struct ClusteringResult {
        let clusterAssignments: [Int]  // Cluster ID for each superpixel
        let clusterCenters: [SIMD3<Float>]  // Center of each cluster in LAB space (recalculated to unweighted if weighted clustering was used)
        let weightedCentersBeforeRecalc: [SIMD3<Float>]?  // Weighted centers before recalculation (only set when useWeightedColors is true)
        let numberOfClusters: Int
        let iterations: Int
        let converged: Bool
        let iterationSnapshots: [IterationSnapshot]  // Captured iteration history
    }

    /// Parameters for K-means clustering
    struct Parameters {
        let numberOfClusters: Int
        let maxIterations: Int
        let convergenceDistance: Float
        let useWeightedColors: Bool
        let lightnessWeight: Float

        init(
            numberOfClusters: Int = 5,
            maxIterations: Int = 300,
            convergenceDistance: Float = 0.01,
            useWeightedColors: Bool = true,
            lightnessWeight: Float = 0.35
        ) {
            self.numberOfClusters = numberOfClusters
            self.maxIterations = maxIterations
            self.convergenceDistance = convergenceDistance
            self.useWeightedColors = useWeightedColors
            self.lightnessWeight = lightnessWeight
        }
    }

    // Metal objects
    private static let device = MTLCreateSystemDefaultDevice()!
    private static let commandQueue = device.makeCommandQueue()!
    private static let library = device.makeDefaultLibrary()!

    // Metal compute pipelines
    private static let calculateMinDistancesPipeline = createPipeline(functionName: "calculateMinDistances")
    private static let calculateDistanceSquaredProbabilitiesPipeline = createPipeline(functionName: "calculateDistanceSquaredProbabilities")
    private static let assignPointsToClustersPipeline = createPipeline(functionName: "assignPointsToClusters")
    private static let clearClusterAccumulatorsPipeline = createPipeline(functionName: "clearClusterAccumulators")
    private static let accumulateClusterDataPipeline = createPipeline(functionName: "accumulateClusterData")
    private static let updateClusterCentersPipeline = createPipeline(functionName: "updateClusterCenters")
    private static let checkConvergencePipeline = createPipeline(functionName: "checkConvergence")
    private static let applyColorWeightingPipeline = createPipeline(functionName: "applyColorWeighting")

    private static func createPipeline(functionName: String) -> MTLComputePipelineState {
        let function = library.makeFunction(name: functionName)!
        return try! device.makeComputePipelineState(function: function)
    }

    /// Perform K-means++ clustering on superpixel colors
    /// - Parameters:
    ///   - superpixelData: Extracted superpixel features
    ///   - parameters: Clustering parameters
    ///   - originalImage: Original image for layer extraction in snapshots
    ///   - imageWidth: Image width
    ///   - imageHeight: Image height
    /// - Returns: Clustering results
    static func cluster(
        superpixelData: SuperpixelProcessor.SuperpixelData,
        parameters: Parameters,
        originalImage: NSImage,
        imageWidth: Int,
        imageHeight: Int
    ) -> ClusteringResult {

        // Extract color features (weighted or unweighted)
        let originalColors = SuperpixelProcessor.extractColorFeatures(from: superpixelData)
        let numPoints = originalColors.count
        let numClusters = parameters.numberOfClusters

        print("=" * 60)
        print("METAL K-MEANS CLUSTERING (BASIC)")
        print("=" * 60)
        print("Number of superpixels: \(numPoints)")
        print("Number of clusters: \(numClusters)")
        print("Using weighted colors: \(parameters.useWeightedColors)")
        if parameters.useWeightedColors {
            print("Lightness weight: \(parameters.lightnessWeight)")
        }

        let totalStartTime = CFAbsoluteTimeGetCurrent()

        // Create Metal buffers
        let originalColorsBuffer = device.makeBuffer(
            bytes: originalColors,
            length: MemoryLayout<SIMD3<Float>>.size * numPoints,
            options: .storageModeShared
        )!

        // Buffer for colors (either weighted or original)
        let colorsBuffer: MTLBuffer
        if parameters.useWeightedColors {
            colorsBuffer = applyWeighting(
                originalColors: originalColorsBuffer,
                lightnessWeight: parameters.lightnessWeight,
                numPoints: numPoints
            )
        } else {
            colorsBuffer = originalColorsBuffer
        }

        // Initialize centers using KMeans++
        let kmeansppStartTime = CFAbsoluteTimeGetCurrent()
        let initialCenters = initializeKMeansPlusPlus(
            colors: colorsBuffer,
            numPoints: numPoints,
            numClusters: numClusters
        )
        let kmeansppTime = CFAbsoluteTimeGetCurrent() - kmeansppStartTime
        #if DEBUG
        print(String(format: "K-means++ initialization: %.2f ms", kmeansppTime * 1000))
        #endif

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

        // Buffer for cluster sums - store as flat array of floats (3 per cluster) for atomic operations
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
        var iterationSnapshots: [IterationSnapshot] = []
        let iterationLoopStartTime = CFAbsoluteTimeGetCurrent()

        while iterations < parameters.maxIterations && !converged {

            // Assign points to clusters
            assignPointsToClusters(
                points: colorsBuffer,
                centers: centersBuffer,
                assignments: assignmentsBuffer,
                distances: distancesBuffer,
                numPoints: numPoints,
                numClusters: numClusters
            )

            // Update cluster centers
            clearClusterAccumulators(
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                numClusters: numClusters
            )

            accumulateClusterData(
                points: colorsBuffer,
                assignments: assignmentsBuffer,
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                numPoints: numPoints,
                numClusters: numClusters
            )

            updateClusterCenters(
                clusterSums: clusterSumsBuffer,
                clusterCounts: clusterCountsBuffer,
                newCenters: newCentersBuffer,
                oldCenters: centersBuffer,
                centerDeltas: centerDeltasBuffer,
                numClusters: numClusters
            )

            // Check convergence
            totalDeltaBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee = 0
            checkConvergence(
                centerDeltas: centerDeltasBuffer,
                totalDelta: totalDeltaBuffer,
                numClusters: numClusters
            )

            let totalDelta = totalDeltaBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee

            // Check convergence - use normal threshold regardless of empty clusters
            converged = totalDelta < parameters.convergenceDistance

            // Force convergence at max iterations
            if iterations >= parameters.maxIterations - 1 {
                converged = true
                if iterations == parameters.maxIterations - 1 {
                    print("    Warning: Forcing convergence at max iterations")
                }
            }

            // Swap buffers
            let temp = centersBuffer
            centersBuffer = newCentersBuffer
            newCentersBuffer = temp

            iterations += 1

            // Capture snapshot every iteration (or every N iterations to save memory)
            // For now, capture every iteration
            let currentAssignments = extractAssignments(buffer: assignmentsBuffer, count: numPoints)
            let currentCenters = extractCenters(buffer: centersBuffer, count: numClusters)

            // Map to pixels for visualization
            let pixelClusters = SuperpixelProcessor.mapClustersToPixels(
                clusterAssignments: currentAssignments,
                superpixelData: superpixelData
            )

            // Create visualization
            let pixelData = visualizeClusters(
                pixelClusters: pixelClusters,
                clusterCenters: currentCenters,
                width: imageWidth,
                height: imageHeight
            )

            // Extract layers for this iteration
            let extractedLayers = LayerExtractor.extractLayers(
                from: originalImage,
                pixelClusters: pixelClusters,
                clusterCenters: currentCenters,
                width: imageWidth,
                height: imageHeight
            )
            let iterationLayerImages = extractedLayers.map { $0.image }

            // Convert to NSImage
            if let cgImage = createCGImageFromData(pixelData, width: imageWidth, height: imageHeight) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: imageWidth, height: imageHeight))
                let snapshot = IterationSnapshot(
                    iterationNumber: iterations,
                    clusterAssignments: currentAssignments,
                    clusterCenters: currentCenters,
                    visualizationImage: nsImage,
                    layerImages: iterationLayerImages
                )
                iterationSnapshots.append(snapshot)
            }
        }

        let iterationLoopTime = CFAbsoluteTimeGetCurrent() - iterationLoopStartTime
        #if DEBUG
        print(String(format: "Main iteration loop (%d iterations): %.2f ms", iterations, iterationLoopTime * 1000))
        #endif

        // In Release builds, ensure all GPU work is complete before reading results
        // In Debug builds, each kernel already waited, so this is redundant but harmless
        #if !DEBUG
        // Need to create and wait on a dummy command buffer to ensure previous work is done
        let finalSyncBuffer = commandQueue.makeCommandBuffer()!
        finalSyncBuffer.commit()
        finalSyncBuffer.waitUntilCompleted()
        #endif

        // Extract final results
        let finalAssignments = extractAssignments(buffer: assignmentsBuffer, count: numPoints)
        var finalCenters: [SIMD3<Float>]
        var weightedCentersBeforeRecalc: [SIMD3<Float>]? = nil

        // If using weighted colors, recalculate centers from original colors
        if parameters.useWeightedColors {
            let recalcStartTime = CFAbsoluteTimeGetCurrent()
            let weightedCenters = extractCenters(buffer: centersBuffer, count: numClusters)
            weightedCentersBeforeRecalc = weightedCenters  // Store for later use
            finalCenters = recalculateUnweightedCenters(
                clusterAssignments: finalAssignments,
                originalColors: originalColors,
                weightedCenters: weightedCenters
            )
            let recalcTime = CFAbsoluteTimeGetCurrent() - recalcStartTime
            #if DEBUG
            print(String(format: "Center recalculation: %.2f ms", recalcTime * 1000))
            #endif
        } else {
            finalCenters = extractCenters(buffer: centersBuffer, count: numClusters)
        }

        // Check unique clusters in final assignments
        let uniqueClusters = Set(finalAssignments)
        if uniqueClusters.count < numClusters {
            print("  Warning: \(numClusters - uniqueClusters.count) empty clusters")
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - totalStartTime
        print(String(format: "Converged: %@ after %d iterations", converged ? "YES" : "NO", iterations))
        print(String(format: "Total time: %.2f ms", totalTime * 1000))
        print("=" * 60)

        return ClusteringResult(
            clusterAssignments: finalAssignments,
            clusterCenters: finalCenters,
            weightedCentersBeforeRecalc: weightedCentersBeforeRecalc,
            numberOfClusters: numClusters,
            iterations: iterations,
            converged: converged,
            iterationSnapshots: iterationSnapshots
        )
    }

    // MARK: - KMeans++ Initialization

    private static func initializeKMeansPlusPlus(
        colors: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) -> [SIMD3<Float>] {

        var centers: [SIMD3<Float>] = []
        let colorsPointer = colors.contents().bindMemory(to: SIMD3<Float>.self, capacity: numPoints)

        // Choose first center randomly
        let firstIndex = Int.random(in: 0..<numPoints)
        centers.append(colorsPointer[firstIndex])

        // Initialization (reduced logging for multiple runs)
        // print("  Center 0: random selection (index \(firstIndex))")

        // Choose remaining centers
        for _ in 1..<numClusters {

            // Create buffer for current centers
            let currentCentersBuffer = device.makeBuffer(
                bytes: centers,
                length: MemoryLayout<SIMD3<Float>>.size * centers.count,
                options: .storageModeShared
            )!

            // Calculate min distances to existing centers
            let minDistancesBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size * numPoints,
                options: .storageModeShared
            )!

            calculateMinDistancesToCenters(
                points: colors,
                centers: currentCentersBuffer,
                minDistances: minDistancesBuffer,
                numPoints: numPoints,
                numCenters: centers.count
            )

            // Calculate D² probabilities
            let probabilitiesBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size * numPoints,
                options: .storageModeShared
            )!

            let totalSumBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.size,
                options: .storageModeShared
            )!

            totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee = 0
            let totalSumBeforeCall = totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee
            calculateDistanceSquaredProbabilities(
                minDistances: minDistancesBuffer,
                probabilities: probabilitiesBuffer,
                totalSum: totalSumBuffer,
                numPoints: numPoints
            )
            print(">>> 'totalSum' AFTER call to calculateDistanceSquaredProbabilities: \(totalSumBeforeCall)")

            // Sample next center based on D² probabilities
            let probabilities = probabilitiesBuffer.contents().bindMemory(to: Float.self, capacity: numPoints)
            let totalSum = totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee
            // Before sampling, check if probabilities are uniform
            let avgProb = 1.0 / Float(numPoints)
            let maxProb = (0..<numPoints).map { probabilities[$0] }.max() ?? 0
            let minProb = (0..<numPoints).map { probabilities[$0] }.min() ?? 0
            print(">>> Probability range: min=\(minProb/totalSum), max=\(maxProb/totalSum), avg=\(avgProb)")
            
            // Build cumulative distribution
            var cumulative: [Float] = []
            var sum: Float = 0
            for i in 0..<numPoints {
                sum += probabilities[i]
                cumulative.append(sum / totalSum)
            }
            let gpuTotalSum = totalSumBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee
            print("GPU totalSum: \(gpuTotalSum), CPU sum: \(sum), diff: \(abs(gpuTotalSum - sum))")
            
            // Sample
            let random = Float.random(in: 0..<1)
            var selectedIndex = numPoints - 1
            for i in 0..<numPoints {
                if cumulative[i] >= random {
                    print(">>> SAMPLED point i=\(i) from \(numPoints) points: random=\(random), cumulative[i]=\(cumulative[i])")
                    selectedIndex = i
                    break
                }
            }

            centers.append(colorsPointer[selectedIndex])
            // Reduced logging for multiple runs
        }

        for center in centers {
            print("*** center: \(center)")
        }
        return centers
    }

    // MARK: - Metal Kernel Dispatch Functions

    private static func applyWeighting(
        originalColors: MTLBuffer,
        lightnessWeight: Float,
        numPoints: Int
    ) -> MTLBuffer {

        let weightedColorsBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.size * numPoints,
            options: .storageModeShared
        )!

        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: 0,
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(applyColorWeightingPipeline)
        encoder.setBuffer(originalColors, offset: 0, index: 0)
        encoder.setBuffer(weightedColorsBuffer, offset: 0, index: 1)
        var weight = lightnessWeight
        encoder.setBytes(&weight, length: MemoryLayout<Float>.size, index: 2)
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
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif

        return weightedColorsBuffer
    }

    private static func calculateMinDistancesToCenters(
        points: MTLBuffer,
        centers: MTLBuffer,
        minDistances: MTLBuffer,
        numPoints: Int,
        numCenters: Int
    ) {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numCenters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

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
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func calculateDistanceSquaredProbabilities(
        minDistances: MTLBuffer,
        probabilities: MTLBuffer,
        totalSum: MTLBuffer,
        numPoints: Int
    ) {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: 0,
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

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
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func assignPointsToClusters(
        points: MTLBuffer,
        centers: MTLBuffer,
        assignments: MTLBuffer,
        distances: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

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
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func clearClusterAccumulators(
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        numClusters: Int
    ) {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(clearClusterAccumulatorsPipeline)
        encoder.setBuffer(clusterSums, offset: 0, index: 0)
        encoder.setBuffer(clusterCounts, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 2)

        let threadsPerThreadgroup = MTLSize(width: 32, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 31) / 32,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func accumulateClusterData(
        points: MTLBuffer,
        assignments: MTLBuffer,
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        numPoints: Int,
        numClusters: Int
    ) {
        var params = KMeansParams(
            numPoints: UInt32(numPoints),
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

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
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func updateClusterCenters(
        clusterSums: MTLBuffer,
        clusterCounts: MTLBuffer,
        newCenters: MTLBuffer,
        oldCenters: MTLBuffer,
        centerDeltas: MTLBuffer,
        numClusters: Int
    ) {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(updateClusterCentersPipeline)
        encoder.setBuffer(clusterSums, offset: 0, index: 0)
        encoder.setBuffer(clusterCounts, offset: 0, index: 1)
        encoder.setBuffer(newCenters, offset: 0, index: 2)
        encoder.setBuffer(oldCenters, offset: 0, index: 3)
        encoder.setBuffer(centerDeltas, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 5)

        let threadsPerThreadgroup = MTLSize(width: 32, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 31) / 32,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    private static func checkConvergence(
        centerDeltas: MTLBuffer,
        totalDelta: MTLBuffer,
        numClusters: Int
    ) {
        var params = KMeansParams(
            numPoints: 0,
            numClusters: UInt32(numClusters),
            iteration: 0,
            convergenceThreshold: 0
        )

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeComputeCommandEncoder()!

        encoder.setComputePipelineState(checkConvergencePipeline)
        encoder.setBuffer(centerDeltas, offset: 0, index: 0)
        encoder.setBuffer(totalDelta, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<KMeansParams>.size, index: 2)

        let threadsPerThreadgroup = MTLSize(width: 32, height: 1, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (numClusters + 31) / 32,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        #if DEBUG
        commandBuffer.waitUntilCompleted()
        #endif
    }

    // MARK: - Helper Functions

    private static func extractAssignments(buffer: MTLBuffer, count: Int) -> [Int] {
        let pointer = buffer.contents().bindMemory(to: Int32.self, capacity: count)
        var assignments: [Int] = []
        for i in 0..<count {
            assignments.append(Int(pointer[i]))
        }
        return assignments
    }

    private static func extractCenters(buffer: MTLBuffer, count: Int) -> [SIMD3<Float>] {
        let pointer = buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        var centers: [SIMD3<Float>] = []
        for i in 0..<count {
            centers.append(pointer[i])
        }
        return centers
    }

    /// Recalculate cluster centers from original (unweighted) colors
    private static func recalculateUnweightedCenters(
        clusterAssignments: [Int],
        originalColors: [SIMD3<Float>],
        weightedCenters: [SIMD3<Float>]
    ) -> [SIMD3<Float>] {

        let numClusters = weightedCenters.count

        // Accumulate colors for each cluster
        var colorSums = Array(repeating: SIMD3<Float>(0, 0, 0), count: numClusters)
        var counts = Array(repeating: 0, count: numClusters)

        for (index, clusterId) in clusterAssignments.enumerated() {
            if clusterId >= 0 && clusterId < numClusters {
                colorSums[clusterId] += originalColors[index]
                counts[clusterId] += 1
            }
        }

        // Calculate averages (keep weighted center if empty)
        var centers: [SIMD3<Float>] = []
        for i in 0..<numClusters {
            if counts[i] > 0 {
                centers.append(colorSums[i] / Float(counts[i]))
            } else {
                // Keep weighted center for empty clusters
                centers.append(weightedCenters[i])
            }
        }

        return centers
    }

    /// Create visualization of clusters
    /// - Parameters:
    ///   - pixelClusters: Cluster assignment for each pixel
    ///   - clusterCenters: LAB color centers for each cluster
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: BGRA pixel data for visualization
    static func visualizeClusters(
        pixelClusters: [UInt32],
        clusterCenters: [SIMD3<Float>],
        width: Int,
        height: Int,
        greenAxisScale: Float = 2.0
    ) -> Data {

        // Debug: print cluster centers
        print("\nCluster Centers (LAB):")
        for (i, center) in clusterCenters.enumerated() {
            let rgb = labToRGB(center, greenAxisScale: greenAxisScale)
            print(String(format: "  Cluster %d: LAB(%.1f, %.1f, %.1f) -> RGB(%.3f, %.3f, %.3f)",
                        i, center.x, center.y, center.z, rgb.x, rgb.y, rgb.z))
        }

        var pixelData = Data(count: width * height * 4)

        pixelData.withUnsafeMutableBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let clusterId = Int(pixelClusters[idx])

                    // Get LAB color for this cluster
                    let labColor = clusterCenters[min(clusterId, clusterCenters.count - 1)]

                    // Convert LAB to RGB
                    let rgb = labToRGB(labColor, greenAxisScale: greenAxisScale)

                    // Write BGRA pixels with byteOrder32Little (matching SLIC processor)
                    let pixelOffset = idx * 4
                    pixels[pixelOffset + 0] = UInt8(rgb.z * 255)  // B
                    pixels[pixelOffset + 1] = UInt8(rgb.y * 255)  // G
                    pixels[pixelOffset + 2] = UInt8(rgb.x * 255)  // R
                    pixels[pixelOffset + 3] = 255                  // A
                }
            }
        }

        return pixelData
    }

    /// Convert LAB color to RGB
    private static func labToRGB(_ lab: SIMD3<Float>, greenAxisScale: Float = 2.0) -> SIMD3<Float> {
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
        let gammaCorrect: (Float) -> Float = { value in
            let clamped = max(0, min(1, value))
            return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0/2.4) - 0.055
        }

        return SIMD3<Float>(
            gammaCorrect(r),
            gammaCorrect(g),
            gammaCorrect(b)
        )
    }

    /// Create CGImage from pixel data
    private static func createCGImageFromData(_ pixelData: Data, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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

// Extension for string repetition (used for logging)
extension String {
    static func *(left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}

// Structure matching Metal shader's params
struct KMeansParams {
    let numPoints: UInt32
    let numClusters: UInt32
    let iteration: UInt32
    let convergenceThreshold: Float
}
