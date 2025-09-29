//
//  SLIC.metal
//  SLIC_ProofOfConcept
//
//  Metal kernels for SLIC superpixel segmentation
//

#include <metal_stdlib>
using namespace metal;

// Structure to hold SLIC parameters
struct SLICParams {
    uint imageWidth;
    uint imageHeight;
    uint gridSpacing;
    uint searchRegion;
    float compactness;
    float spatialWeight;
    uint numCenters;
    uint iteration;
};

// Structure for cluster centers
struct ClusterCenter {
    float x;
    float y;
    float L;
    float a;
    float b;
};

// Simple copy kernel to initialize textures
kernel void copyTexture(texture2d<float, access::read> inTexture [[texture(0)]],
                       texture2d<float, access::write> outTexture [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    float4 color = inTexture.read(gid);
    outTexture.write(color, gid);
}

// Clear distances buffer to infinity
kernel void clearDistances(device float* distances [[buffer(0)]],
                          constant SLICParams& params [[buffer(1)]],
                          uint gid [[thread_position_in_grid]]) {
    uint totalPixels = params.imageWidth * params.imageHeight;
    if (gid >= totalPixels) {
        return;
    }

    distances[gid] = INFINITY;
}

// Gaussian blur kernel (3x3 with sigma=0.5)
kernel void gaussianBlur(texture2d<float, access::read> inTexture [[texture(0)]],
                         texture2d<float, access::write> outTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }

    // Gaussian kernel weights for 3x3 with sigma=0.5
    // Pre-calculated: exp(-(x^2 + y^2)/(2*0.5^2))
    float kernel0 = 0.0113;
    float kernel1 = 0.0838;
    float kernel2 = 0.0113;
    float kernel3 = 0.0838;
    float kernel4 = 0.6193;
    float kernel5 = 0.0838;
    float kernel6 = 0.0113;
    float kernel7 = 0.0838;
    float kernel8 = 0.0113;

    float4 sum = float4(0.0);
    float totalWeight = 0.0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 coord = int2(gid) + int2(dx, dy);

            // Clamp to texture boundaries
            coord.x = clamp(coord.x, 0, int(inTexture.get_width() - 1));
            coord.y = clamp(coord.y, 0, int(inTexture.get_height() - 1));

            int kernelIdx = (dy + 1) * 3 + (dx + 1);
            float weight = 0.0;
            if (kernelIdx == 0) weight = kernel0;
            else if (kernelIdx == 1) weight = kernel1;
            else if (kernelIdx == 2) weight = kernel2;
            else if (kernelIdx == 3) weight = kernel3;
            else if (kernelIdx == 4) weight = kernel4;
            else if (kernelIdx == 5) weight = kernel5;
            else if (kernelIdx == 6) weight = kernel6;
            else if (kernelIdx == 7) weight = kernel7;
            else if (kernelIdx == 8) weight = kernel8;
            sum += inTexture.read(uint2(coord)) * weight;
            totalWeight += weight;
        }
    }

    outTexture.write(sum / totalWeight, gid);
}

// RGB to LAB color space conversion
kernel void rgbToLab(texture2d<float, access::read> rgbTexture [[texture(0)]],
                     device float3* labBuffer [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {

    uint width = rgbTexture.get_width();
    uint height = rgbTexture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float4 rgba = rgbTexture.read(gid);
    float3 rgb = rgba.rgb;

    // RGB to XYZ conversion (assuming sRGB)
    // First, linearize RGB values
    float3 linear;
    for (int i = 0; i < 3; i++) {
        if (rgb[i] <= 0.04045) {
            linear[i] = rgb[i] / 12.92;
        } else {
            linear[i] = pow((rgb[i] + 0.055) / 1.055, 2.4);
        }
    }

    // RGB to XYZ matrix (sRGB with D65 illuminant)
    float3x3 rgbToXyz = float3x3(
        0.4124564, 0.3575761, 0.1804375,
        0.2126729, 0.7151522, 0.0721750,
        0.0193339, 0.1191920, 0.9503041
    );

    float3 xyz = linear * rgbToXyz * 100.0;

    // Normalize by D65 illuminant
    xyz.x /= 95.047;
    xyz.y /= 100.000;
    xyz.z /= 108.883;

    // XYZ to LAB conversion
    float3 f;
    const float epsilon = 0.008856;
    const float kappa = 903.3;

    for (int i = 0; i < 3; i++) {
        if (xyz[i] > epsilon) {
            f[i] = pow(xyz[i], 1.0/3.0);
        } else {
            f[i] = (kappa * xyz[i] + 16.0) / 116.0;
        }
    }

    float L = 116.0 * f.y - 16.0;
    float a = 500.0 * (f.x - f.y);
    float b = 200.0 * (f.y - f.z);

    uint index = gid.y * width + gid.x;
    labBuffer[index] = float3(L, a, b);
}

// Initialize cluster centers on a regular grid
kernel void initializeCenters(device const float3* labBuffer [[buffer(0)]],
                              device ClusterCenter* centers [[buffer(1)]],
                              constant SLICParams& params [[buffer(2)]],
                              uint gid [[thread_position_in_grid]]) {

    if (gid >= params.numCenters) {
        return;
    }

    // Calculate grid dimensions
    uint gridWidth = (params.imageWidth + params.gridSpacing - 1) / params.gridSpacing;
    uint gridY = gid / gridWidth;
    uint gridX = gid % gridWidth;

    // Calculate initial center position
    uint centerX = min(gridX * params.gridSpacing + params.gridSpacing / 2, params.imageWidth - 1);
    uint centerY = min(gridY * params.gridSpacing + params.gridSpacing / 2, params.imageHeight - 1);

    // Perturb to lowest gradient position in 3x3 neighborhood
    float minGradient = INFINITY;
    uint bestX = centerX;
    uint bestY = centerY;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int x = int(centerX) + dx;
            int y = int(centerY) + dy;

            if (x > 0 && x < int(params.imageWidth) - 1 &&
                y > 0 && y < int(params.imageHeight) - 1) {

                uint idx = y * params.imageWidth + x;

                // Calculate gradient using Sobel-like differences
                float3 dx_lab = labBuffer[idx + 1] - labBuffer[idx - 1];
                float3 dy_lab = labBuffer[idx + params.imageWidth] - labBuffer[idx - params.imageWidth];

                float gradient = length(dx_lab) + length(dy_lab);

                if (gradient < minGradient) {
                    minGradient = gradient;
                    bestX = x;
                    bestY = y;
                }
            }
        }
    }

    // Set center at lowest gradient position
    uint index = bestY * params.imageWidth + bestX;
    float3 lab = labBuffer[index];

    centers[gid].x = float(bestX);
    centers[gid].y = float(bestY);
    centers[gid].L = lab.x;
    centers[gid].a = lab.y;
    centers[gid].b = lab.z;
}

// Assign pixels to nearest cluster center
kernel void assignPixels(device const float3* labBuffer [[buffer(0)]],
                         device const ClusterCenter* centers [[buffer(1)]],
                         device atomic_uint* labels [[buffer(2)]],
                         device atomic_float* distances [[buffer(3)]],
                         constant SLICParams& params [[buffer(4)]],
                         uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= params.imageWidth || gid.y >= params.imageHeight) {
        return;
    }

    uint pixelIndex = gid.y * params.imageWidth + gid.x;
    float3 pixelLab = labBuffer[pixelIndex];
    float2 pixelPos = float2(gid.x, gid.y);

    float minDistance = INFINITY;
    uint bestLabel = 0;

    // Determine which cluster centers to check based on position
    uint gridWidth = (params.imageWidth + params.gridSpacing - 1) / params.gridSpacing;
    uint gridHeight = (params.imageHeight + params.gridSpacing - 1) / params.gridSpacing;

    int centerGridX = int(gid.x / params.gridSpacing);
    int centerGridY = int(gid.y / params.gridSpacing);

    // Search in 2S x 2S region
    int searchRange = int(params.searchRegion / params.gridSpacing) + 1;

    for (int dy = -searchRange; dy <= searchRange; dy++) {
        for (int dx = -searchRange; dx <= searchRange; dx++) {
            int gridX = centerGridX + dx;
            int gridY = centerGridY + dy;

            if (gridX >= 0 && gridX < int(gridWidth) &&
                gridY >= 0 && gridY < int(gridHeight)) {

                uint centerIdx = gridY * gridWidth + gridX;
                if (centerIdx < params.numCenters) {
                    ClusterCenter center = centers[centerIdx];

                    // Only check if within 2S distance
                    float2 centerPos = float2(center.x, center.y);
                    float spatialDist = distance(pixelPos, centerPos);

                    if (spatialDist < float(params.searchRegion)) {
                        // Calculate color distance in LAB space
                        float3 colorDiff = float3(center.L, center.a, center.b) - pixelLab;
                        float colorDist = length(colorDiff);

                        // Combined distance with compactness weighting
                        float dist = sqrt(
                            (colorDist * colorDist) +
                            (spatialDist * spatialDist * params.spatialWeight * params.spatialWeight)
                        );

                        if (dist < minDistance) {
                            minDistance = dist;
                            bestLabel = centerIdx;
                        }
                    }
                }
            }
        }
    }

    // Atomic update only if better
    device atomic_uint* distanceAtomic = (device atomic_uint*)&distances[pixelIndex];
    float currentDist = as_type<float>(atomic_load_explicit(distanceAtomic, memory_order_relaxed));
    if (minDistance < currentDist) {
        atomic_store_explicit(&labels[pixelIndex], bestLabel, memory_order_relaxed);
        atomic_store_explicit(distanceAtomic, as_type<uint>(minDistance), memory_order_relaxed);
    }
}

// Structure for accumulating center updates
struct CenterAccumulator {
    atomic_float sumX;
    atomic_float sumY;
    atomic_float sumL;
    atomic_float sumA;
    atomic_float sumB;
    atomic_uint count;
};

// Update cluster centers based on pixel assignments
kernel void updateCenters(device const float3* labBuffer [[buffer(0)]],
                          device const uint* labels [[buffer(1)]],
                          device ClusterCenter* centers [[buffer(2)]],
                          device CenterAccumulator* accumulators [[buffer(3)]],
                          constant SLICParams& params [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= params.imageWidth || gid.y >= params.imageHeight) {
        return;
    }

    uint pixelIndex = gid.y * params.imageWidth + gid.x;
    uint label = labels[pixelIndex];

    if (label < params.numCenters) {
        float3 lab = labBuffer[pixelIndex];

        // Accumulate values for this center
        atomic_fetch_add_explicit(&accumulators[label].sumX, float(gid.x), memory_order_relaxed);
        atomic_fetch_add_explicit(&accumulators[label].sumY, float(gid.y), memory_order_relaxed);
        atomic_fetch_add_explicit(&accumulators[label].sumL, lab.x, memory_order_relaxed);
        atomic_fetch_add_explicit(&accumulators[label].sumA, lab.y, memory_order_relaxed);
        atomic_fetch_add_explicit(&accumulators[label].sumB, lab.z, memory_order_relaxed);
        atomic_fetch_add_explicit(&accumulators[label].count, 1u, memory_order_relaxed);
    }
}

// Finalize center updates by computing means
kernel void finalizeCenters(device const CenterAccumulator* accumulators [[buffer(0)]],
                            device ClusterCenter* centers [[buffer(1)]],
                            constant SLICParams& params [[buffer(2)]],
                            uint gid [[thread_position_in_grid]]) {

    if (gid >= params.numCenters) {
        return;
    }

    uint count = atomic_load_explicit(&accumulators[gid].count, memory_order_relaxed);

    if (count > 0) {
        float fcount = float(count);
        centers[gid].x = atomic_load_explicit(&accumulators[gid].sumX, memory_order_relaxed) / fcount;
        centers[gid].y = atomic_load_explicit(&accumulators[gid].sumY, memory_order_relaxed) / fcount;
        centers[gid].L = atomic_load_explicit(&accumulators[gid].sumL, memory_order_relaxed) / fcount;
        centers[gid].a = atomic_load_explicit(&accumulators[gid].sumA, memory_order_relaxed) / fcount;
        centers[gid].b = atomic_load_explicit(&accumulators[gid].sumB, memory_order_relaxed) / fcount;
    }
}

// Clear accumulator buffers
kernel void clearAccumulators(device CenterAccumulator* accumulators [[buffer(0)]],
                              constant SLICParams& params [[buffer(1)]],
                              uint gid [[thread_position_in_grid]]) {

    if (gid >= params.numCenters) {
        return;
    }

    atomic_store_explicit(&accumulators[gid].sumX, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&accumulators[gid].sumY, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&accumulators[gid].sumL, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&accumulators[gid].sumA, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&accumulators[gid].sumB, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&accumulators[gid].count, 0u, memory_order_relaxed);
}

// Enforce connectivity - reassign small orphaned regions
kernel void enforceConnectivity(device uint* labels [[buffer(0)]],
                                device const uint* labelsCopy [[buffer(1)]],
                                constant SLICParams& params [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {

    if (gid.x >= params.imageWidth || gid.y >= params.imageHeight) {
        return;
    }

    uint pixelIndex = gid.y * params.imageWidth + gid.x;
    uint currentLabel = labelsCopy[pixelIndex];

    // Check 4-connectivity
    uint connectedCount = 0;
    uint nearestLabel = currentLabel;

    // Check neighbors
    int2 offsets[4] = { int2(-1,0), int2(1,0), int2(0,-1), int2(0,1) };

    for (int i = 0; i < 4; i++) {
        int2 neighbor = int2(gid) + offsets[i];

        if (neighbor.x >= 0 && neighbor.x < int(params.imageWidth) &&
            neighbor.y >= 0 && neighbor.y < int(params.imageHeight)) {

            uint neighborIdx = neighbor.y * params.imageWidth + neighbor.x;
            uint neighborLabel = labelsCopy[neighborIdx];

            if (neighborLabel == currentLabel) {
                connectedCount++;
            } else if (connectedCount == 0) {
                nearestLabel = neighborLabel;
            }
        }
    }

    // If isolated, reassign to nearest neighbor's label
    if (connectedCount == 0) {
        labels[pixelIndex] = nearestLabel;
    }
}

// Draw superpixel boundaries for visualization
kernel void drawBoundaries(texture2d<float, access::read> originalTexture [[texture(0)]],
                           texture2d<float, access::write> outputTexture [[texture(1)]],
                           device const uint* labels [[buffer(0)]],
                           constant SLICParams& params [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {

    uint width = originalTexture.get_width();
    uint height = originalTexture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    uint pixelIndex = gid.y * width + gid.x;
    uint currentLabel = labels[pixelIndex];

    // Read original color
    float4 color = originalTexture.read(gid);

    // Ensure alpha is 1.0 (fully opaque)
    color.a = 1.0;

    // Check if this pixel is on a boundary
    bool isBoundary = false;

    // Check 4-neighbors with bounds checking
    if (gid.x > 0 && labels[pixelIndex - 1] != currentLabel) {
        isBoundary = true;
    }
    if (gid.x < width - 1 && labels[pixelIndex + 1] != currentLabel) {
        isBoundary = true;
    }
    if (gid.y > 0 && labels[pixelIndex - width] != currentLabel) {
        isBoundary = true;
    }
    if (gid.y < height - 1 && labels[pixelIndex + width] != currentLabel) {
        isBoundary = true;
    }

    if (isBoundary) {
        // Blend red boundary with original (50% mix)
        color = mix(color, float4(1.0, 0.0, 0.0, 1.0), 0.5);
    }

    outputTexture.write(color, gid);
}