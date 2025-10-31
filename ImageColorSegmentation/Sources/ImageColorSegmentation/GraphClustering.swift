//
//  GraphClustering.swift
//  ImageColorSegmentation
//
//  Region Adjacency Graph (RAG) based clustering for superpixels
//  Superior to K-means because it respects spatial adjacency relationships
//

import Foundation
import Metal
import simd

/// Edge in the region adjacency graph
struct GraphEdge {
    let region1: Int
    let region2: Int
    let similarity: Float  // Higher = more similar (inverse of distance)

    var distance: Float {
        return 1.0 / max(similarity, 0.0001)
    }
}

/// Node in the region adjacency graph
struct GraphNode {
    let id: Int
    var color: SIMD3<Float>  // OKLAB color
    var depth: Float
    var pixelCount: Int
    var adjacentRegions: Set<Int>
}

/// Region Adjacency Graph for hierarchical clustering
public class RegionAdjacencyGraph {
    private var nodes: [Int: GraphNode]
    private var edges: [GraphEdge]
    private let depthWeight: Float

    /// Initialize RAG from superpixel data
    public init(
        superpixels: [SuperpixelProcessor.Superpixel],
        labels: [UInt32],
        width: Int,
        height: Int,
        depthWeight: Float
    ) {
        self.depthWeight = depthWeight

        // Create nodes from superpixels
        var nodeDict: [Int: GraphNode] = [:]
        for superpixel in superpixels {
            nodeDict[superpixel.id] = GraphNode(
                id: superpixel.id,
                color: superpixel.labColor,
                depth: superpixel.averageDepth,
                pixelCount: superpixel.pixelCount,
                adjacentRegions: []
            )
        }

        // Find adjacencies by checking neighboring pixels
        var adjacencySet: Set<Edge> = []
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let label = Int(labels[idx])

                // Check right neighbor
                if x + 1 < width {
                    let rightIdx = y * width + (x + 1)
                    let rightLabel = Int(labels[rightIdx])
                    if label != rightLabel {
                        adjacencySet.insert(Edge(min(label, rightLabel), max(label, rightLabel)))
                    }
                }

                // Check bottom neighbor
                if y + 1 < height {
                    let bottomIdx = (y + 1) * width + x
                    let bottomLabel = Int(labels[bottomIdx])
                    if label != bottomLabel {
                        adjacencySet.insert(Edge(min(label, bottomLabel), max(label, bottomLabel)))
                    }
                }
            }
        }

        // Add adjacencies to nodes
        for edge in adjacencySet {
            nodeDict[edge.a]?.adjacentRegions.insert(edge.b)
            nodeDict[edge.b]?.adjacentRegions.insert(edge.a)
        }

        self.nodes = nodeDict
        self.edges = []  // Initialize before using self

        // Create weighted edges
        var graphEdges: [GraphEdge] = []
        for edge in adjacencySet {
            guard let node1 = self.nodes[edge.a],
                  let node2 = self.nodes[edge.b] else { continue }

            let similarity = self.computeSimilarity(node1: node1, node2: node2)
            graphEdges.append(GraphEdge(region1: edge.a, region2: edge.b, similarity: similarity))
        }

        // Sort edges by similarity (highest first = most similar)
        self.edges = graphEdges.sorted { $0.similarity > $1.similarity }
    }

    /// Compute similarity between two nodes (higher = more similar)
    private func computeSimilarity(node1: GraphNode, node2: GraphNode) -> Float {
        // OKLAB color distance
        let colorDiff = node1.color - node2.color
        let colorDist = sqrt(colorDiff.x * colorDiff.x + colorDiff.y * colorDiff.y + colorDiff.z * colorDiff.z)

        // Depth distance (already 0-1 range)
        let depthDist = abs(node1.depth - node2.depth) * depthWeight

        // Combined distance
        let totalDist = sqrt(colorDist * colorDist + depthDist * depthDist)

        // Convert to similarity (inverse distance with smooth falloff)
        return 1.0 / (1.0 + totalDist)
    }

    /// Perform hierarchical merging until we have K clusters
    public func cluster(into k: Int) -> [Int: Int] {
        // Union-Find data structure for tracking merges
        var parent: [Int: Int] = [:]
        for id in nodes.keys {
            parent[id] = id
        }

        func find(_ x: Int) -> Int {
            if parent[x] != x {
                parent[x] = find(parent[x]!)  // Path compression
            }
            return parent[x]!
        }

        func union(_ x: Int, _ y: Int) {
            let rootX = find(x)
            let rootY = find(y)
            if rootX != rootY {
                parent[rootY] = rootX
            }
        }

        // Count initial clusters
        var numClusters = nodes.count

        // Merge regions until we reach k clusters
        for edge in edges {
            if numClusters <= k {
                break
            }

            let root1 = find(edge.region1)
            let root2 = find(edge.region2)

            // Only merge if not already in same cluster
            if root1 != root2 {
                union(root1, root2)
                numClusters -= 1

                // Update node data (merge into root1)
                if var node1 = nodes[root1], let node2 = nodes[root2] {
                    let totalCount = Float(node1.pixelCount + node2.pixelCount)
                    let weight1 = Float(node1.pixelCount) / totalCount
                    let weight2 = Float(node2.pixelCount) / totalCount

                    // Weighted average color and depth
                    node1.color = node1.color * weight1 + node2.color * weight2
                    node1.depth = node1.depth * weight1 + node2.depth * weight2
                    node1.pixelCount += node2.pixelCount

                    // Merge adjacencies
                    node1.adjacentRegions.formUnion(node2.adjacentRegions)
                    node1.adjacentRegions.remove(root1)
                    node1.adjacentRegions.remove(root2)

                    nodes[root1] = node1
                }
            }
        }

        // Build final mapping from superpixel ID to cluster ID
        var clusterMapping: [Int: Int] = [:]
        var clusterIdMap: [Int: Int] = [:]
        var nextClusterId = 0

        for superpixelId in nodes.keys {
            let root = find(superpixelId)
            if clusterIdMap[root] == nil {
                clusterIdMap[root] = nextClusterId
                nextClusterId += 1
            }
            clusterMapping[superpixelId] = clusterIdMap[root]
        }

        return clusterMapping
    }

    /// Get cluster centers (colors) from current state
    public func getClusterCenters(mapping: [Int: Int]) -> [SIMD3<Float>] {
        // Find unique cluster IDs
        let uniqueClusters = Set(mapping.values).sorted()
        var centers: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0, 0, 0), count: uniqueClusters.count)
        var counts: [Int] = Array(repeating: 0, count: uniqueClusters.count)

        // Accumulate colors for each cluster
        for (superpixelId, clusterId) in mapping {
            if let node = nodes[superpixelId] {
                centers[clusterId] += node.color * Float(node.pixelCount)
                counts[clusterId] += node.pixelCount
            }
        }

        // Average
        for i in 0..<centers.count {
            if counts[i] > 0 {
                centers[i] /= Float(counts[i])
            }
        }

        return centers
    }

    // Helper struct for adjacency set
    private struct Edge: Hashable {
        let a: Int
        let b: Int

        init(_ a: Int, _ b: Int) {
            self.a = a
            self.b = b
        }
    }
}
