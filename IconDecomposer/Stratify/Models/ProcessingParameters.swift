//
//  ProcessingParameters.swift
//  IconDecomposer
//
//  Processing parameters for icon decomposition
//

import Foundation

struct ProcessingParameters: Codable, Equatable {
    /// Number of initial clusters before auto-merge
    var numberOfClusters: Int = 8

    /// SLIC compactness parameter (higher = more compact superpixels)
    var compactness: Float = 25.0

    /// Number of superpixel segments
    var numberOfSegments: Int = 1000

    /// Auto-merge threshold for combining similar clusters
    var autoMergeThreshold: Float = 30.0

    /// Lightness weight for clustering (reduce L channel influence)
    var lightnessWeight: Float = 0.35

    /// Green axis scale factor (emphasize green separation)
    var greenAxisScale: Float = 2.0

    /// Random seed for K-means clustering (ensures reproducible results)
    var clusteringSeed: Int? = 8675309

    static let `default` = ProcessingParameters()
}
