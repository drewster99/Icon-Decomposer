# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Icon Decomposer is a dual-implementation tool for decomposing 1024×1024 app icons into separate color layers:
1. **Python/Flask web application** (production-ready)
2. **macOS Swift/Metal native implementation** (in development, optimizing for Apple Silicon)

Both use SLIC superpixel segmentation + K-means clustering in LAB color space to intelligently separate colors while preserving gradients.

## Development Commands

### Python Web Application
```bash
# Install dependencies
pip install -r requirements.txt

# Start the development server
python server.py

# The application runs on http://localhost:5000
```

### macOS Native Application
```bash
# Build and run the active scheme (SLIC_ProofOfConcept)
# Use xcode-mcp-server tools, NOT xcodebuild

# Available schemes:
# - SLIC_ProofOfConcept: SwiftKMeansPlusPlus (CPU-based SIMD)
# - SLIC_POC_MetalKMeans: Custom Metal GPU K-means (optimized)
# - IconDecomposer: Main app (future)
```

**IMPORTANT**: Always use xcode-mcp-server tools (e.g., `build_project`, `run_project`) instead of `xcodebuild` when working with the Xcode project. This ensures builds use the same settings as the user sees in Xcode.

## Architecture

### Python Web Application Architecture

**Backend** (server.py, processor.py):
- **server.py**: Flask web server
  - `/process` endpoint for image processing
  - File I/O for uploads and exports
  - Content-based SHA-256 caching to skip redundant work
  - Returns 256px previews + full-res layers for export

- **processor.py**: Core algorithm (IconProcessor class)
  1. SLIC superpixel segmentation (~500-1000 regions)
  2. Vectorized feature extraction using scipy.ndimage.mean
  3. K-means clustering in LAB color space
  4. Connected component analysis for region separation
  5. Layer generation with soft/hard edge modes

**Frontend** (static/):
- **index.html**: Drag-drop upload, parameter controls
- **app.js**: Canvas rendering, API calls, smart layer grouping
- **layer-grouping.js**: Algorithm for combining similar layers
- **style.css**: Two-column responsive layout

**Processing Flow**:
1. User uploads → `/process` endpoint
2. Backend checks cache (SHA-256 hash + parameters)
3. Returns 256px previews for display, full-res kept for export
4. User selects layers → Export creates ZIP with selections only

### macOS Native Application Architecture

**Project Structure**:
- **IconDecomposer.xcodeproj** contains three targets:
  1. **SLIC_ProofOfConcept**: Uses SwiftKMeansPlusPlus package (CPU SIMD)
  2. **SLIC_POC_MetalKMeans**: Custom Metal GPU K-means (optimized)
  3. **IconDecomposer**: Main app (future)

**Shared Components** (used by both POC targets):
- **SLICProcessor.swift**: Metal-accelerated SLIC superpixel segmentation
  - SLIC.metal: Compute shaders for Gaussian blur, RGB→LAB, pixel assignment, center updates
- **SuperpixelProcessor.swift**: Feature extraction from superpixel regions
  - Uses GPU parallel accumulation (366x faster than CPU loops)
- **LayerExtractor.swift**: Separates clustered regions into individual layers

**K-means Implementations**:
1. **SLIC_ProofOfConcept/KMeansProcessor.swift**: Wrapper for SwiftKMeansPlusPlus
   - CPU-based SIMD operations
   - ~56ms for typical workload

2. **SLIC_POC_MetalKMeans/KMeansProcessor.swift**: Custom Metal implementation
   - KMeans.metal: GPU kernels for K-means++ initialization and clustering
   - ~9ms for typical workload (6.2x faster)
   - Uses simple atomic operations for cluster accumulation

**Metal Shaders**:
- **SLIC.metal**: All SLIC operations (blur, color conversion, assignment, updates)
- **KMeans.metal**: K-means++ initialization, distance calculation, cluster assignment/updates

## Key Implementation Details

### Image Processing Parameters
- **n_layers** (2-10): Number of color clusters to create
- **compactness** (5-50): Controls gradient grouping (higher = tighter spatial grouping)
- **n_segments** (200-2000): Superpixel detail level
- **distance_threshold**: 'auto' or 'off' for region separation
- **max_regions_per_color**: Limits disconnected regions per color (default: 2)
- **edge_mode**: 'soft' (anti-aliased) or 'hard' edges

### File Organization
- **uploads/**: Temporary storage for uploaded images (cleaned after processing)
- **exports/**: Temporary storage for generated ZIP files
- **static/**: Frontend assets served directly

### Dependencies
- Flask for web server
- scikit-image for SLIC superpixel segmentation
- scikit-learn for K-means clustering
- OpenCV for additional image operations
- Pillow for image I/O
- NumPy for array operations

## Performance Metrics

### Python Web Application
**Original** (before optimizations): 7.3 seconds total
- Feature extraction: 2.6s (looping through superpixels)
- Visualization generation: 2.7s (full 1024×1024)
- Response encoding: 1.0-1.2s (base64 encoding)
- SLIC segmentation: 0.45s
- Reconstruction: 450ms

**Current** (after optimizations):
- **Initial request**: 1.3-1.6 seconds (4.5-5.6x faster)
- **Changing only layers**: 0.87 seconds (8.4x faster)

**Key optimizations**:
- Feature extraction: 2.6s → 0.06s (42x, using scipy.ndimage.mean)
- Visualization: 2.7s → 0.22s (12x, at 256px resolution)
- Caching: SHA-256 hash skips SLIC/features when reusable
- Previews: 256px display, full-res only for export

### macOS Metal Implementation
**Full pipeline** (1024×1024, 1024 superpixels, 5 clusters):

| Component | SwiftKMeansPlusPlus | Metal K-means (Optimized) | Speedup |
|-----------|---------------------|---------------------------|---------|
| SLIC Processing | 43ms | 37ms | 1.16x |
| Extract Superpixels | 880ms (50%) | 2.4ms (0.2%) | **366x** |
| K-means Clustering | 56ms (3%) | 9ms (0.9%) | **6.2x** |
| Map to Pixels | 108ms | 115ms | Similar |
| Create Visualization | 155ms | 150ms | Similar |
| Extract Layers | 557ms | 725ms | Slower* |
| **TOTAL** | **1757ms** | **1001ms** | **1.75x** |

\*Extract Layers is slower in optimized version because it produces more clusters for testing.

**Extract Superpixels optimization** (880ms → 2.4ms, 366x speedup):
- Eliminated Set creation from full labelMap (65ms saved)
- Optimized labelMap creation using UnsafeBufferPointer (31ms saved)
- GPU parallel accumulation for pixel statistics (1.2ms)

**Next bottleneck**: Extract Layers (72% of pipeline time) is the primary optimization target.

## Critical Implementation Notes

### Metal GPU Development
- **Simple atomics work best**: Direct `atomic_fetch_add` outperforms complex threadgroup reductions
- **Identify CPU overhead**: Profiling revealed Set creation and array copying dominated GPU kernel time
- **Eliminate unnecessary work**: Scanning pixelCounts array is 1000x faster than hashing labels into Set
- **Use optimized constructors**: `Array(UnsafeBufferPointer)` is vastly faster than element-by-element copy
- **Release vs Debug sync**: Remove intermediate `waitUntilCompleted()` calls in Release builds for GPU pipelining

### Force Unwrapping in Swift
Per user's global rules: NEVER use force unwrapping (`!`) or `try?` without explicit approval. These are safety-critical violations.

### SwiftUI State Management
- Prefer @Observable over singletons and NotificationCenter
- Never use `@ObservedObject` for new objects—use `@StateObject`
- Never put `.sheet`/`.alert` before `.onAppear`/`.onChange` unless intentional
- Never use didSet/willSet on @State or @Binding properties

## Testing Approach

No formal test suite exists. Testing is manual:
1. Python app: Run server, upload various icons, adjust parameters
2. macOS app: Build and run schemes in Xcode, compare timing breakdowns
3. Verify layer separation quality matches expectations