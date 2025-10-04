//
//  KMeans.metal
//  SLIC_POC_MetalKMeans
//
//  Metal compute kernels for KMeans++ clustering of superpixels
//

#include <metal_stdlib>
using namespace metal;

// Structure for KMeans parameters
struct KMeansParams {
    uint numPoints;        // Number of superpixels
    uint numClusters;      // K value
    uint iteration;        // Current iteration
    float convergenceThreshold;
};

// Calculate minimum distance from each point to any existing center
kernel void calculateMinDistances(
    device const float3* points [[buffer(0)]],           // Superpixel LAB colors
    device const float3* centers [[buffer(1)]],          // Current cluster centers
    device float* minDistances [[buffer(2)]],            // Output: min distance to any center
    constant KMeansParams& params [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float3 point = points[gid];
    float minDist = INFINITY;

    // Find distance to nearest center - numClusters, in this case, is really the number
    // of centers we have so far
    for (uint i = 0; i < params.numClusters; i++) {
        float3 center = centers[i];
        float3 diff = point - center;
        float dist = length(diff);
        minDist = min(minDist, dist);
    }

    minDistances[gid] = minDist;
}

// Calculate D² (distance squared) probabilities for KMeans++ sampling
kernel void calculateDistanceSquaredProbabilities(
    device const float* minDistances [[buffer(0)]],      // Min distances from previous kernel
    device float* probabilities [[buffer(1)]],           // Output: D² probabilities
    device float* totalSum [[buffer(2)]],                // Output: sum of all D² (for normalization)
    constant KMeansParams& params [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float dist = minDistances[gid];
    float distSquared = dist * dist;
    probabilities[gid] = distSquared;

    // Atomic add to total sum (will be used for normalization)
    // Note: This is a simple approach; for better performance, use parallel reduction
    atomic_fetch_add_explicit((device atomic_float*)totalSum, distSquared, memory_order_relaxed);
}

// Assign each point to its nearest cluster center
kernel void assignPointsToClusters(
    device const float3* points [[buffer(0)]],           // Superpixel LAB colors
    device const float3* centers [[buffer(1)]],          // Current cluster centers
    device int* assignments [[buffer(2)]],               // Output: cluster assignment for each point
    device float* distances [[buffer(3)]],               // Output: distance to assigned cluster
    constant KMeansParams& params [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float3 point = points[gid];
    float minDist = INFINITY;
    int nearestCluster = 0;

    // Find nearest cluster center
    for (uint i = 0; i < params.numClusters; i++) {
        float3 center = centers[i];
        float3 diff = point - center;
        float dist = length(diff);

        if (dist < minDist) {
            minDist = dist;
            nearestCluster = i;
        }
    }

    assignments[gid] = nearestCluster;
    distances[gid] = minDist;
}

// Clear accumulator buffers for cluster update
kernel void clearClusterAccumulators(
    device float* clusterSums [[buffer(0)]],             // Sum of points in each cluster (flat array)
    device int* clusterCounts [[buffer(1)]],             // Count of points in each cluster
    constant KMeansParams& params [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numClusters) return;

    uint baseOffset = gid * 3;
    clusterSums[baseOffset + 0] = 0.0;
    clusterSums[baseOffset + 1] = 0.0;
    clusterSums[baseOffset + 2] = 0.0;
    clusterCounts[gid] = 0;
}

// Simple direct atomic accumulation (basic approach)
kernel void accumulateClusterData(
    device const float3* points [[buffer(0)]],           // Superpixel LAB colors
    device const int* assignments [[buffer(1)]],         // Cluster assignments
    device atomic_float* clusterSums [[buffer(2)]],      // Output: sum of points per cluster (as flat array)
    device atomic_int* clusterCounts [[buffer(3)]],      // Output: count of points per cluster
    constant KMeansParams& params [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    int clusterId = assignments[gid];
    float3 point = points[gid];

    // Direct atomic operations - simple but potentially slower
    // Each float3 is stored as 3 consecutive floats
    uint baseOffset = clusterId * 3;
    atomic_fetch_add_explicit(&clusterSums[baseOffset + 0], point.x, memory_order_relaxed);
    atomic_fetch_add_explicit(&clusterSums[baseOffset + 1], point.y, memory_order_relaxed);
    atomic_fetch_add_explicit(&clusterSums[baseOffset + 2], point.z, memory_order_relaxed);

    atomic_fetch_add_explicit(&clusterCounts[clusterId], 1, memory_order_relaxed);
}

// Update cluster centers as mean of assigned points
kernel void updateClusterCenters(
    device const float* clusterSums [[buffer(0)]],       // Sum of points per cluster (flat array)
    device const int* clusterCounts [[buffer(1)]],       // Count of points per cluster
    device float3* newCenters [[buffer(2)]],             // Output: new cluster centers
    device const float3* oldCenters [[buffer(3)]],       // Previous centers (for convergence check)
    device float* centerDeltas [[buffer(4)]],            // Output: movement of each center
    constant KMeansParams& params [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numClusters) return;

    int count = clusterCounts[gid];
    uint baseOffset = gid * 3;

    if (count > 0) {
        // Calculate new center as mean of assigned points
        float3 sum = float3(clusterSums[baseOffset + 0],
                           clusterSums[baseOffset + 1],
                           clusterSums[baseOffset + 2]);
        newCenters[gid] = sum / float(count);

        // Calculate movement from old center
        float3 delta = newCenters[gid] - oldCenters[gid];
        centerDeltas[gid] = length(delta);
    } else {
        // Empty cluster - keep old center
        newCenters[gid] = oldCenters[gid];
        centerDeltas[gid] = 0.0;
    }
}

// Check for convergence by summing center movements
kernel void checkConvergence(
    device const float* centerDeltas [[buffer(0)]],      // Movement of each center
    device float* totalDelta [[buffer(1)]],              // Output: total movement
    constant KMeansParams& params [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numClusters) return;

    // Simple atomic add for total delta
    // For better performance, use parallel reduction
    atomic_fetch_add_explicit((device atomic_float*)totalDelta, centerDeltas[gid], memory_order_relaxed);
}

// Find the point with maximum distance to its assigned center
kernel void findFarthestPoint(
    device const float3* points [[buffer(0)]],           // All points
    device const float3* centers [[buffer(1)]],          // Current centers
    device const int* assignments [[buffer(2)]],         // Point assignments
    device float* pointDistances [[buffer(3)]],          // Output: distance to assigned center
    constant KMeansParams& params [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float3 point = points[gid];
    int assignedCluster = assignments[gid];
    float3 center = centers[assignedCluster];

    float3 diff = point - center;
    float dist = length(diff);

    pointDistances[gid] = dist;
}

// Kernel for weighted color features (reducing L channel influence and enhancing green separation)
kernel void applyColorWeighting(
    device const float3* originalColors [[buffer(0)]],   // Original LAB colors
    device float3* weightedColors [[buffer(1)]],         // Output: weighted colors
    constant float& lightnessWeight [[buffer(2)]],       // Weight for L channel (e.g., 0.35)
    constant float& greenAxisScale [[buffer(3)]],        // Scale for negative a values (e.g., 2.0)
    constant KMeansParams& params [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float3 color = originalColors[gid];
    float a = color.y;

    // Apply green axis scaling to negative 'a' values
    if (a < 0.0) {
        a *= greenAxisScale;
    }

    weightedColors[gid] = float3(
        color.x * lightnessWeight,  // L channel weighted
        a,                           // a channel with green scaling applied
        color.z                      // b channel unchanged
    );
}

// Calculate inertia (sum of squared distances from points to their assigned centers)
kernel void calculateInertia(
    device const float3* points [[buffer(0)]],           // All points
    device const float3* centers [[buffer(1)]],          // Current centers
    device const int* assignments [[buffer(2)]],         // Point assignments
    device float* inertia [[buffer(3)]],                 // Output: total inertia
    constant KMeansParams& params [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= params.numPoints) return;

    float3 point = points[gid];
    int assignedCluster = assignments[gid];
    float3 center = centers[assignedCluster];

    float3 diff = point - center;
    float distSquared = dot(diff, diff);  // Squared distance

    // Atomic add to total inertia
    atomic_fetch_add_explicit((device atomic_float*)inertia, distSquared, memory_order_relaxed);
}

// Parallel reduction kernel for summing values (helper for better performance)
kernel void parallelSum(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& numElements [[buffer(2)]],
    threadgroup float* shared [[threadgroup(0)]],
    uint tid [[thread_index_in_threadgroup]],
    uint gid [[thread_position_in_grid]],
    uint tgSize [[threads_per_threadgroup]])
{
    // Load data into shared memory
    shared[tid] = (gid < numElements) ? input[gid] : 0.0;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Parallel reduction in shared memory
    for (uint stride = tgSize / 2; stride > 0; stride /= 2) {
        if (tid < stride) {
            shared[tid] += shared[tid + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Write result
    if (tid == 0) {
        output[gid / tgSize] = shared[0];
    }
}
