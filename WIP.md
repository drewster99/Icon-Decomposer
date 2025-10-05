# Work In Progress: SLIC Metal Implementation

## Project Goal
Build a standalone macOS app in Swift that performs icon decomposition similar to the existing Python web app, but optimized for Apple Silicon using Metal. The first step is implementing SLIC (Simple Linear Iterative Clustering) superpixel segmentation as a proof of concept.

## Current Status
Created a working Metal-based SLIC implementation in the `SLIC_ProofOfConcept` target with:
- Full Metal shader implementation of SLIC algorithm
- Swift wrapper class (`SLICProcessor`)
- SwiftUI test interface with side-by-side comparison
- Performance measurement built-in

## Architecture Decisions

### Why Metal over Alternatives
- **Considered options**:
  - vImage + vDSP (Accelerate framework): Good for CPU optimization
  - OpenCV: Not optimized for Apple Silicon, just C++ CPU code
  - Metal: GPU acceleration, unified memory on Apple Silicon

- **Chose all-Metal for SLIC** because:
  - Pixel assignment phase is 80-85% of compute time and perfectly parallel
  - Unified memory architecture on Apple Silicon avoids CPU-GPU transfers
  - Expected 15-30x speedup over Python (targeting <50ms vs Python's 450ms)

### Implementation Details

#### Metal Shaders (SLIC.metal)
1. **gaussianBlur**: 3×3 kernel with σ=0.5 preprocessing
2. **rgbToLab**: Color space conversion for perceptual distance
3. **initializeCenters**: Dynamic grid initialization with gradient-based perturbation
4. **assignPixels**: Main compute kernel - assigns each pixel to nearest cluster
5. **updateCenters**: Parallel reduction to compute new cluster centers
6. **enforceConnectivity**: Post-processing to handle orphaned regions
7. **drawBoundaries**: Visualization overlay

#### Key Parameters (matching Python)
- **n_segments**: 1000 default (range 200-2000)
- **compactness**: 25 default (range 5-50)
- **iterations**: 10 default
- **Grid spacing**: S = √(N²/K) where N=image_size, K=n_segments

## Recent Issues and Fixes

### Black Artifacts Problem
**Issue**: Screenshot showed black speckled artifacts in lower-right portion of segmented image

**Root causes identified**:
1. Uninitialized label buffer - pixels starting with garbage values
2. Boundary drawing reading incorrect/uninitialized labels
3. Alpha channel handling issues

**Fixes applied**:
1. Initialize labels buffer to 0 before processing
2. Ensure alpha = 1.0 in boundary drawing
3. Changed boundary visualization from solid red to 50% blend
4. Fixed neighbor checking with proper bounds validation

### Parameter Mismatches
- Had compactness at 10, should be 25 (matching Python)
- Had n_segments range 500-3000, should be 200-2000
- Fixed both to match Python implementation

## Performance Results
- Current: ~1.026 seconds for 1024×1024 image
- Target: <50ms (15-30x faster than Python's 450ms)
- **Issue**: Much slower than expected, needs optimization

## Next Steps

### Immediate TODOs
1. **Performance investigation**: Current 1s is way too slow, should be <50ms
   - Check if Metal kernels are actually running on GPU
   - Profile to find bottleneck
   - Verify atomic operations aren't serializing execution

2. **Add real test images**: Need 3 actual 1024×1024 app icons in Assets.xcassets
   - TestIcon1, TestIcon2, TestIcon3
   - Should be real app icons to properly test segmentation quality

3. **Verify algorithm correctness**:
   - Compare superpixel output with Python version
   - Ensure connectivity enforcement is working
   - Validate LAB conversion matches scikit-image

### Future Work (after SLIC is optimized)
1. Integrate K-means clustering (possibly using SwiftKMeansPlusPlus)
2. Implement full icon decomposition pipeline
3. Add layer extraction and export functionality
4. Build main IconDecomposer app with full UI

## File Structure
```
IconDecomposer/
├── IconDecomposer.xcodeproj
├── IconDecomposer/           # Main app target (future)
└── SLIC_ProofOfConcept/      # Current work
    ├── SLIC.metal            # Metal compute shaders
    ├── SLICProcessor.swift   # Swift wrapper class
    └── ContentView.swift     # Test UI
```

## Known Issues to Address
1. Performance is ~20x slower than target
2. Need to verify segmentation quality matches Python
3. Test with real images instead of generated patterns
4. Possible atomic operation bottlenecks in Metal kernels

## Technical Notes
- Using atomic operations for distance/label updates might be causing serialization
- Consider double-buffering approach instead of atomics
- May need to optimize threadgroup sizes for M-series chips
- Gaussian blur could use Metal Performance Shaders instead of custom kernel

---

# Refactoring Planning Session - 2025-10-04

## Current State Analysis

### Compactness Parameter ✅
**CONFIRMED:** Compactness IS being used correctly in Swift/Metal implementation.

- **SLICProcessor.swift:171**
  ```swift
  let spatialWeight = parameters.compactness / Float(gridSpacing)
  ```

- **SLIC.metal:294-297**
  ```swift
  float dist = sqrt(
      (colorDist * colorDist) +
      (spatialDist * spatialDist * params.spatialWeight * params.spatialWeight)
  );
  ```

**ACTION ITEM:** Verify Python version is using compactness correctly.

