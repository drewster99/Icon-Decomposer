import Foundation
import Metal
import simd

// MARK: - Color Conversion Operation

class ColorConversionOperation: PipelineOperation {
    let inputType: DataType = .rgbaImage
    let outputType: DataType = .labImage

    private let colorSpace: ColorSpace
    private let adjustments: LABColorAdjustments

    init(colorSpace: ColorSpace, adjustments: LABColorAdjustments) {
        self.colorSpace = colorSpace
        self.adjustments = adjustments
    }

    func execute(context: inout ExecutionContext) async throws {
        // NOTE: RGB→LAB conversion is handled by SLIC processor
        // This operation just passes the metadata for later use
        context.metadata["colorSpace"] = colorSpace
        context.metadata["labColorAdjustments"] = adjustments
    }
}

// MARK: - Segmentation Operation

class SegmentationOperation: PipelineOperation {
    let inputType: DataType = .labImage
    let outputType: DataType = .superpixelFeatures

    private let superpixelCount: Int
    private let compactness: Float

    init(superpixelCount: Int, compactness: Float) {
        self.superpixelCount = superpixelCount
        self.compactness = compactness
    }

    func execute(context: inout ExecutionContext) async throws {
        guard let inputBuffer = context.buffers["rgbaImage"],
              let width = context.metadata["width"] as? Int,
              let height = context.metadata["height"] as? Int else {
            throw PipelineError.executionFailed("Missing input buffer or dimensions for segmentation")
        }

        // Get color adjustments from metadata (set by color conversion operation)
        let adjustments = context.metadata["labColorAdjustments"] as? LABColorAdjustments ?? .default
        let greenAxisScale = adjustments.greenAxisScale
        let lightnessWeight = adjustments.lightnessScale

        // Create texture from buffer
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let inputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw PipelineError.executionFailed("Failed to create input texture")
        }

        // Copy buffer data to texture
        let bytesPerRow = width * 4
        inputTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: inputBuffer.contents(),
            bytesPerRow: bytesPerRow
        )

        // Get Metal library from context (compiled once at initialization)
        let library = context.library

        // Create command queue for SLIC
        guard let commandQueue = context.device.makeCommandQueue() else {
            throw PipelineError.executionFailed("Failed to create command queue for SLIC")
        }

        // Create SLIC processor
        let slicProcessor = try SLICProcessor(device: context.device, library: library)

        // Process SLIC segmentation (creates its own command buffer internally)
        let slicResult = try slicProcessor.processSLIC(
            inputTexture: inputTexture,
            commandQueue: commandQueue,
            nSegments: superpixelCount,
            compactness: compactness,
            greenAxisScale: greenAxisScale,
            lightnessWeight: lightnessWeight,
            iterations: 10,
            enforceConnectivity: true
        )

        // Store results in context
        context.buffers["labImage"] = slicResult.labBuffer
        context.buffers["labelsBuffer"] = slicResult.labelsBuffer
        context.buffers["alphaBuffer"] = slicResult.alphaBuffer
        context.metadata["numSLICCenters"] = slicResult.numCenters
        context.metadata["superpixelCount"] = superpixelCount
        context.metadata["compactness"] = compactness
    }
}

// MARK: - Clustering Operation

class ClusteringOperation: PipelineOperation {
    let inputType: DataType = .superpixelFeatures
    let outputType: DataType = .clusterAssignments

    private let clusterCount: Int
    private let seed: Int?

    init(clusterCount: Int, seed: Int?) {
        self.clusterCount = clusterCount
        self.seed = seed
    }

    func execute(context: inout ExecutionContext) async throws {
        guard let labBuffer = context.buffers["labImage"],
              let labelsBuffer = context.buffers["labelsBuffer"],
              let width = context.metadata["width"] as? Int,
              let height = context.metadata["height"] as? Int else {
            throw PipelineError.executionFailed("Missing buffers for clustering")
        }

        // Get Metal library from context (compiled once at initialization)
        let library = context.library

        // Create command queue
        guard let commandQueue = context.device.makeCommandQueue() else {
            throw PipelineError.executionFailed("Failed to create command queue")
        }

        // Extract superpixel features using GPU
        let superpixelProcessor = try SuperpixelProcessor(
            device: context.device,
            library: library,
            commandQueue: commandQueue
        )

        let superpixelData = try superpixelProcessor.extractSuperpixelsMetal(
            from: labBuffer,
            labelsBuffer: labelsBuffer,
            width: width,
            height: height
        )

        // Extract color features for clustering
        let superpixelColors = SuperpixelProcessor.extractColorFeatures(from: superpixelData)

        // Get color adjustments from metadata
        let adjustments = context.metadata["labColorAdjustments"] as? LABColorAdjustments ?? .default

        // Perform K-means++ clustering
        let kmeansProcessor = try KMeansProcessor(
            device: context.device,
            library: library,
            commandQueue: commandQueue
        )

        let clusteringResult = try kmeansProcessor.cluster(
            superpixelColors: superpixelColors,
            numberOfClusters: clusterCount,
            lightnessWeight: adjustments.lightnessScale,
            greenAxisScale: adjustments.greenAxisScale,
            maxIterations: 300,
            convergenceDistance: 0.01,
            seed: seed
        )

        // Map cluster assignments to pixels
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        let labelMap = Array(UnsafeBufferPointer(start: labelsPointer, count: width * height))

        let pixelClusters = LayerExtractor.mapClustersToPixels(
            clusterAssignments: clusteringResult.clusterAssignments,
            superpixelData: superpixelData,
            labelMap: labelMap
        )

        // Create cluster assignments buffer
        guard let assignmentsBuffer = context.device.makeBuffer(
            bytes: pixelClusters,
            length: pixelClusters.count * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create assignments buffer")
        }

        // Create cluster centers buffer
        guard let centersBuffer = context.device.makeBuffer(
            bytes: clusteringResult.clusterCenters,
            length: clusteringResult.clusterCenters.count * MemoryLayout<SIMD3<Float>>.size,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create centers buffer")
        }

        // Store results
        context.buffers["clusterAssignments"] = assignmentsBuffer
        context.buffers["clusterCenters"] = centersBuffer
        context.buffers["pixelClusters"] = assignmentsBuffer  // Same data, different name
        context.metadata["clusterCount"] = clusteringResult.numberOfClusters
        context.metadata["clusterSeed"] = seed
        context.metadata["clusteringIterations"] = clusteringResult.iterations
        context.metadata["clusteringConverged"] = clusteringResult.converged
    }
}

// MARK: - Layer Extraction Operation

class LayerExtractionOperation: PipelineOperation {
    let inputType: DataType = .clusterAssignments
    let outputType: DataType = .layers

    func execute(context: inout ExecutionContext) async throws {
        guard let pixelClustersBuffer = context.buffers["pixelClusters"],
              let originalImageBuffer = context.buffers["rgbaImage"],
              let clusterCount = context.metadata["clusterCount"] as? Int,
              let width = context.metadata["width"] as? Int,
              let height = context.metadata["height"] as? Int else {
            throw PipelineError.executionFailed("Missing data for layer extraction")
        }

        // Get Metal library from context (compiled once at initialization)
        let library = context.library

        // Create command queue
        guard let commandQueue = context.device.makeCommandQueue() else {
            throw PipelineError.executionFailed("Failed to create command queue")
        }

        // Get pixel clusters array
        let pixelClustersPointer = pixelClustersBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        let pixelClusters = Array(UnsafeBufferPointer(start: pixelClustersPointer, count: width * height))

        // Extract layers using GPU
        let layerExtractor = try LayerExtractor(
            device: context.device,
            library: library,
            commandQueue: commandQueue
        )

        let layerBuffers = try layerExtractor.extractLayersGPU(
            originalImageBuffer: originalImageBuffer,
            pixelClusters: pixelClusters,
            numberOfClusters: clusterCount,
            width: width,
            height: height
        )

        // Store layer buffers
        for (i, layerBuffer) in layerBuffers.enumerated() {
            context.buffers["layer_\(i)"] = layerBuffer
        }

        context.metadata["layerCount"] = clusterCount
        context.metadata["layers"] = layerBuffers
    }
}

// MARK: - Merge Operation

class MergeOperation: PipelineOperation {
    let inputType: DataType = .clusterAssignments
    let outputType: DataType = .clusterAssignments

    private let threshold: Float
    private let strategy: MergeStrategy

    init(threshold: Float, strategy: MergeStrategy = .simple) {
        self.threshold = threshold
        self.strategy = strategy
    }

    func execute(context: inout ExecutionContext) async throws {
        switch strategy {
        case .simple:
            try executeSimpleMerge(context: &context)
        case .iterativeWeighted(let customAdjustments):
            try await executeIterativeWeightedMerge(
                context: &context,
                customAdjustments: customAdjustments
            )
        }
    }

    /// Simple merge: merge all pairs below threshold in one pass
    private func executeSimpleMerge(context: inout ExecutionContext) throws {
        guard let centersBuffer = context.buffers["clusterCenters"],
              let assignmentsBuffer = context.buffers["clusterAssignments"],
              let clusterCount = context.metadata["clusterCount"] as? Int,
              let width = context.metadata["width"] as? Int,
              let height = context.metadata["height"] as? Int else {
            throw PipelineError.executionFailed("Missing data for cluster merging")
        }

        // Read cluster centers
        let centersPointer = centersBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: clusterCount)
        let centers = Array(UnsafeBufferPointer(start: centersPointer, count: clusterCount))

        // Find clusters to merge based on LAB distance threshold
        var mergeMap = Array(0..<clusterCount)  // mergeMap[i] = target cluster for cluster i

        for i in 0..<clusterCount {
            for j in (i+1)..<clusterCount {
                let distance = simd_distance(centers[i], centers[j])
                if distance < threshold {
                    // Merge j into i
                    mergeMap[j] = i
                }
            }
        }

        // Apply transitive closure to merge map
        for i in 0..<clusterCount {
            var target = mergeMap[i]
            while target != mergeMap[target] {
                target = mergeMap[target]
            }
            mergeMap[i] = target
        }

        // Count unique clusters
        let uniqueClusters = Set(mergeMap)
        let newClusterCount = uniqueClusters.count

        // Remap assignments
        let assignmentsPointer = assignmentsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        for i in 0..<(width * height) {
            let oldCluster = Int(assignmentsPointer[i])
            if oldCluster < clusterCount {
                assignmentsPointer[i] = UInt32(mergeMap[oldCluster])
            }
        }

        // Recalculate merged centers
        var newCenters: [SIMD3<Float>] = []
        var clusterMapping: [Int: Int] = [:]  // old cluster ID -> new cluster ID
        var nextNewClusterId = 0

        for oldClusterId in uniqueClusters.sorted() {
            clusterMapping[oldClusterId] = nextNewClusterId
            newCenters.append(centers[oldClusterId])
            nextNewClusterId += 1
        }

        // Update assignments with new cluster IDs
        for i in 0..<(width * height) {
            let mergedCluster = Int(assignmentsPointer[i])
            if let newClusterId = clusterMapping[mergedCluster] {
                assignmentsPointer[i] = UInt32(newClusterId)
            }
        }

        // Update centers buffer
        guard let newCentersBuffer = context.device.makeBuffer(
            bytes: newCenters,
            length: newCenters.count * MemoryLayout<SIMD3<Float>>.size,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create new centers buffer")
        }

        context.buffers["clusterCenters"] = newCentersBuffer
        context.metadata["clusterCount"] = newClusterCount
        context.metadata["mergeThreshold"] = threshold
        context.metadata["originalClusterCount"] = clusterCount
    }

    /// Iterative weighted merge: uses weighted distances to find pairs, checks unweighted threshold to stop
    private func executeIterativeWeightedMerge(
        context: inout ExecutionContext,
        customAdjustments: LABColorAdjustments?
    ) async throws {
        // Use custom adjustments if provided, otherwise use pipeline default
        let adjustments = customAdjustments
            ?? context.metadata["labColorAdjustments"] as? LABColorAdjustments
            ?? .default

        let lightnessWeight = adjustments.lightnessScale
        let greenAxisScale = adjustments.greenAxisScale

        guard let centersBuffer = context.buffers["clusterCenters"],
              let assignmentsBuffer = context.buffers["clusterAssignments"],
              let labBuffer = context.buffers["labImage"],
              let labelsBuffer = context.buffers["labelsBuffer"],
              let clusterCount = context.metadata["clusterCount"] as? Int,
              let width = context.metadata["width"] as? Int,
              let height = context.metadata["height"] as? Int else {
            throw PipelineError.executionFailed("Missing data for iterative weighted merging")
        }

        // Get superpixel data for recalculating centers
        let library = context.library
        guard let commandQueue = context.device.makeCommandQueue() else {
            throw PipelineError.executionFailed("Failed to create command queue")
        }

        let superpixelProcessor = try SuperpixelProcessor(
            device: context.device,
            library: library,
            commandQueue: commandQueue
        )

        let superpixelData = try superpixelProcessor.extractSuperpixelsMetal(
            from: labBuffer,
            labelsBuffer: labelsBuffer,
            width: width,
            height: height
        )

        // Read initial cluster assignments
        let assignmentsPointer = assignmentsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        var clusterAssignments = Array(UnsafeBufferPointer(start: assignmentsPointer, count: width * height)).map { Int($0) }

        // Read initial centers
        let centersPointer = centersBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: clusterCount)
        var currentCenters = Array(UnsafeBufferPointer(start: centersPointer, count: clusterCount))

        var mergeCount = 0
        let maxMerges = clusterCount  // Safety limit

        while mergeCount < maxMerges {
            // Calculate weighted and unweighted distances
            let unweightedDists = calculateClusterDistances(currentCenters)
            let weightedCenters = applyWeighting(currentCenters, lightnessWeight: lightnessWeight, greenAxisScale: greenAxisScale)
            let weightedDists = calculateClusterDistances(weightedCenters)

            // Find closest pair using weighted distances
            guard let (clusterA, clusterB) = findClosestClusterPair(
                weightedDistances: weightedDists,
                unweightedDistances: unweightedDists,
                threshold: threshold
            ) else {
                // No more pairs below threshold
                break
            }

            // Merge the clusters
            (clusterAssignments, currentCenters) = mergeTwoClusters(
                clusterA: clusterA,
                clusterB: clusterB,
                clusterAssignments: clusterAssignments,
                superpixelData: superpixelData
            )

            mergeCount += 1
        }

        // Map cluster assignments back to pixel space
        let labelsPointer = labelsBuffer.contents().bindMemory(to: UInt32.self, capacity: width * height)
        let labelMap = Array(UnsafeBufferPointer(start: labelsPointer, count: width * height))

        let pixelClusters = LayerExtractor.mapClustersToPixels(
            clusterAssignments: clusterAssignments.map { Int32($0) },
            superpixelData: superpixelData,
            labelMap: labelMap
        )

        // Write back to assignments buffer
        for i in 0..<pixelClusters.count {
            assignmentsPointer[i] = pixelClusters[i]
        }

        // Update centers buffer
        guard let newCentersBuffer = context.device.makeBuffer(
            bytes: currentCenters,
            length: currentCenters.count * MemoryLayout<SIMD3<Float>>.size,
            options: .storageModeShared
        ) else {
            throw PipelineError.executionFailed("Failed to create new centers buffer")
        }

        context.buffers["clusterCenters"] = newCentersBuffer
        context.metadata["clusterCount"] = currentCenters.count
        context.metadata["mergeThreshold"] = threshold
        context.metadata["originalClusterCount"] = clusterCount
        context.metadata["mergeCount"] = mergeCount
    }

    // MARK: - Helper Functions for Weighted Merge

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

    /// Apply lightness weighting and green axis scaling to cluster centers
    private func applyWeighting(_ centers: [SIMD3<Float>], lightnessWeight: Float, greenAxisScale: Float) -> [SIMD3<Float>] {
        return centers.map { center in
            var a = center.y
            // Apply green axis scaling to negative 'a' values
            if a < 0 {
                a *= greenAxisScale
            }
            return SIMD3<Float>(center.x * lightnessWeight, a, center.z)
        }
    }

    /// Find closest cluster pair to merge
    /// Uses weighted distances to find the pair, but checks unweighted threshold to decide if merging should stop
    private func findClosestClusterPair(
        weightedDistances: [[Float]],
        unweightedDistances: [[Float]],
        threshold: Float
    ) -> (clusterA: Int, clusterB: Int)? {
        guard weightedDistances.count == unweightedDistances.count,
              !weightedDistances.isEmpty else {
            return nil
        }

        let n = weightedDistances.count
        var minWeightedDist = Float.infinity
        var minPair: (Int, Int)?

        // Find pair with minimum weighted distance
        for i in 0..<n {
            for j in (i+1)..<n {
                let dist = weightedDistances[i][j]
                if dist < minWeightedDist {
                    minWeightedDist = dist
                    minPair = (i, j)
                }
            }
        }

        guard let (i, j) = minPair else {
            return nil
        }

        // Check if minimum unweighted distance exceeds threshold
        var minUnweightedDist = Float.infinity
        for row in 0..<n {
            for col in (row+1)..<n {
                minUnweightedDist = min(minUnweightedDist, unweightedDistances[row][col])
            }
        }

        // Only return the pair if we should continue merging
        if minUnweightedDist > threshold {
            return nil
        }

        return (i, j)
    }

    /// Merge two clusters and return updated cluster assignments and centers
    private func mergeTwoClusters(
        clusterA: Int,
        clusterB: Int,
        clusterAssignments: [Int],
        superpixelData: SuperpixelProcessor.SuperpixelData
    ) -> (newAssignments: [Int], newCenters: [SIMD3<Float>]) {
        // Remap cluster B to cluster A
        let newAssignments = clusterAssignments.map { assignment in
            if assignment == clusterB {
                return clusterA
            } else if assignment > clusterB {
                // Shift down cluster IDs above clusterB
                return assignment - 1
            } else {
                return assignment
            }
        }

        // Calculate new cluster centers from superpixels
        let uniqueClusters = Set(newAssignments).sorted()
        var newCenters: [SIMD3<Float>] = []

        for clusterId in uniqueClusters {
            var colorSum = SIMD3<Float>(0, 0, 0)
            var count = 0

            for (spIndex, assignment) in newAssignments.enumerated() {
                if assignment == clusterId && spIndex < superpixelData.superpixels.count {
                    colorSum += superpixelData.superpixels[spIndex].labColor
                    count += 1
                }
            }

            if count > 0 {
                newCenters.append(colorSum / Float(count))
            } else {
                // Empty cluster - shouldn't happen but handle gracefully
                newCenters.append(SIMD3<Float>(50, 0, 0))
            }
        }

        return (newAssignments, newCenters)
    }
}
