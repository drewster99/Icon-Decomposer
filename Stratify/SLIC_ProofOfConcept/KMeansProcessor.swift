//
//  KMeansProcessor.swift
//  SLIC_ProofOfConcept
//
//  Wrapper around SwiftKMeansPlusPlus for clustering superpixels.
//  This isolates the K-means implementation for easy replacement later.
//

import Foundation
import simd
import SwiftKMeansPlusPlus

/// Helper function to calculate Euclidean distance between two SIMD3<Float> vectors
private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let diff = a - b
    return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)
}

/// Handles K-means clustering of superpixel features
class KMeansProcessor {

    /// Result of K-means clustering
    struct ClusteringResult {
        let clusterAssignments: [Int]  // Cluster ID for each superpixel
        let clusterCenters: [SIMD3<Float>]  // Center of each cluster in LAB space
        let numberOfClusters: Int
        let iterations: Int
        let converged: Bool
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
            lightnessWeight: Float = 0.65
        ) {
            self.numberOfClusters = numberOfClusters
            self.maxIterations = maxIterations
            self.convergenceDistance = convergenceDistance
            self.useWeightedColors = useWeightedColors
            self.lightnessWeight = lightnessWeight
        }
    }

    /// Perform K-means++ clustering on superpixel colors
    /// - Parameters:
    ///   - superpixelData: Extracted superpixel features
    ///   - parameters: Clustering parameters
    /// - Returns: Clustering results
    static func cluster(
        superpixelData: SuperpixelProcessor.SuperpixelData,
        parameters: Parameters
    ) -> ClusteringResult {

        // Extract color features (weighted or unweighted)
        let colors: [SIMD3<Float>]
        if parameters.useWeightedColors {
            colors = SuperpixelProcessor.extractWeightedColorFeatures(
                from: superpixelData,
                lightnessWeight: parameters.lightnessWeight
            )
        } else {
            colors = SuperpixelProcessor.extractColorFeatures(from: superpixelData)
        }

        print("=" * 60)
        print("K-MEANS CLUSTERING")
        print("=" * 60)
        print("Number of superpixels: \(colors.count)")
        print("Number of clusters: \(parameters.numberOfClusters)")
        print("Using weighted colors: \(parameters.useWeightedColors)")
        if parameters.useWeightedColors {
            print("Lightness weight: \(parameters.lightnessWeight)")
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Perform K-means++ clustering
        let clusters = colors.kMeansClusters(
            upTo: parameters.numberOfClusters,
            convergeDistance: parameters.convergenceDistance
        )

        let clusteringTime = CFAbsoluteTimeGetCurrent() - startTime
        print(String(format: "K-means++ time: %.2f ms", clusteringTime * 1000))

        let assignmentStartTime = CFAbsoluteTimeGetCurrent()

        // Extract cluster centers
        var clusterCenters: [SIMD3<Float>] = []
        for cluster in clusters {
            clusterCenters.append(cluster.center)
        }

        // Simple approach: assign each point to its nearest cluster center
        // This ensures ALL points get assigned (matching Python's behavior)
        var clusterAssignments = Array<Int>(repeating: 0, count: colors.count)

        for (index, color) in colors.enumerated() {
            var minDistance = Float.infinity
            var nearestCluster = 0

            for (clusterIndex, center) in clusterCenters.enumerated() {
                let dist = distance(color, center)
                if dist < minDistance {
                    minDistance = dist
                    nearestCluster = clusterIndex
                }
            }
            clusterAssignments[index] = nearestCluster
        }

        // Verify the assignments match what K-means returned (for debugging)
        var matchCount = 0
        var mismatchCount = 0
        for (clusterIndex, cluster) in clusters.enumerated() {
            for point in cluster.points {
                if let index = colors.firstIndex(where: { distance($0, point) < 0.001 }) {
                    if clusterAssignments[index] == clusterIndex {
                        matchCount += 1
                    } else {
                        mismatchCount += 1
                    }
                }
            }
        }

        if mismatchCount > 0 {
            print("Note: \(mismatchCount) points reassigned to different clusters than K-means++ suggested")
        }

        let assignmentTime = CFAbsoluteTimeGetCurrent() - assignmentStartTime
        print(String(format: "Assignment mapping time: %.2f ms", assignmentTime * 1000))

        // If using weighted colors, recalculate centers from original colors
        if parameters.useWeightedColors {
            let recalcStartTime = CFAbsoluteTimeGetCurrent()
            clusterCenters = recalculateUnweightedCenters(
                clusterAssignments: clusterAssignments,
                originalColors: SuperpixelProcessor.extractColorFeatures(from: superpixelData)
            )
            let recalcTime = CFAbsoluteTimeGetCurrent() - recalcStartTime
            print(String(format: "Center recalculation time: %.2f ms", recalcTime * 1000))
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        print(String(format: "Total K-means time: %.2f ms", totalTime * 1000))
        print("Clustering complete with \(clusters.count) clusters")
        print("=" * 60)

        return ClusteringResult(
            clusterAssignments: clusterAssignments,
            clusterCenters: clusterCenters,
            numberOfClusters: clusters.count,
            iterations: -1,  // SwiftKMeansPlusPlus doesn't expose this
            converged: true
        )
    }

    /// Recalculate cluster centers from original (unweighted) colors
    private static func recalculateUnweightedCenters(
        clusterAssignments: [Int],
        originalColors: [SIMD3<Float>]
    ) -> [SIMD3<Float>] {

        // Find number of clusters
        let maxCluster = clusterAssignments.max() ?? 0
        let numClusters = maxCluster + 1

        // Accumulate colors for each cluster
        var colorSums = Array(repeating: SIMD3<Float>(0, 0, 0), count: numClusters)
        var counts = Array(repeating: 0, count: numClusters)

        for (index, clusterId) in clusterAssignments.enumerated() {
            if clusterId >= 0 {
                colorSums[clusterId] += originalColors[index]
                counts[clusterId] += 1
            }
        }

        // Calculate averages
        var centers: [SIMD3<Float>] = []
        for i in 0..<numClusters {
            if counts[i] > 0 {
                centers.append(colorSums[i] / Float(counts[i]))
            } else {
                centers.append(SIMD3<Float>(0, 0, 0))
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
        height: Int
    ) -> Data {

        // Debug: print cluster centers
        print("\nCluster Centers (LAB):")
        for (i, center) in clusterCenters.enumerated() {
            let rgb = labToRGB(center)
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
                    let rgb = labToRGB(labColor)

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
    private static func labToRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        // LAB to XYZ
        let fy = (lab.x + 16.0) / 116.0
        let fx = lab.y / 500.0 + fy
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
}

// Extension for string repetition (used for logging)
extension String {
    static func *(left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}