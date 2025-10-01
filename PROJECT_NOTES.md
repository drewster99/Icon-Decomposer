# Icon Decomposer Project

## Project Overview
A web-based tool for decomposing app icons (1024x1024 PNG/JPG) into separate color layers for Apple's new layered app icon system. The tool uses advanced image processing to automatically identify and separate different color regions while preserving gradients.

## Core Algorithm
1. **SLIC Superpixel Segmentation**: Divides image into ~500-1000 regions of similar color
2. **K-means Clustering in LAB Color Space**: Groups superpixels into 2-10 color clusters
3. **Connected Component Analysis**: Optionally separates disconnected regions of same color
4. **Layer Generation**: Creates PNG files with transparency for each color cluster

## Key Features Implemented
- Drag & drop image upload
- Real-time parameter adjustment (processes on slider release, not during drag)
- Visual feedback showing each processing step
- Layer selection with checkboxes
- Dynamic reconstruction preview based on selected layers
- Export only selected layers as ZIP
- Two export modes: folder structure or suffix naming
- Automatic filename extraction from uploaded image
- Sorted layers by pixel count (largest first)

## Recent UI Improvements
- Fixed horizontal scrolling issues
- Consistent drag/drop area height (350px)
- Two-column layout for controls on wide screens
- Region separation defaulted to "Off"
- Process button has proper spacing
- Processing steps images match decomposed layer sizes
- Original → Reconstruction preview in export section

## Technical Stack
- **Backend**: Python Flask with scikit-image, scikit-learn, OpenCV
- **Frontend**: Vanilla JavaScript, HTML5, CSS3
- **Processing**: SLIC superpixels + K-means in LAB color space
- **Export**: ZIP generation with selected layers only
- **macOS Targets**: Swift/Metal implementations for native performance

## macOS Metal Implementation

### Architecture
Two Xcode targets demonstrating different K-means implementations:
1. **SLIC_ProofOfConcept**: Uses SwiftKMeansPlusPlus package (CPU-based SIMD)
2. **SLIC_POC_MetalKMeans**: Custom Metal GPU implementation

Both targets share:
- Metal-accelerated SLIC superpixel segmentation
- SuperpixelProcessor for feature extraction
- LayerExtractor for separating clustered regions into individual layers

### Performance Comparison (1024×1024 image, 1024 superpixels, 5 clusters)

#### Total Pipeline Breakdown
| Stage | SwiftKMeansPlusPlus | Metal K-means | Improvement |
|-------|---------------------|---------------|-------------|
| SLIC Processing | 43ms | 43ms | Same |
| Extract Superpixels | 880ms (50%) | 921ms (53%) | -41ms |
| **K-means Clustering** | **56ms (3%)** | **18ms (1%)** | **3.1x faster** |
| Map to Pixels | 108ms (6%) | 108ms (6%) | Same |
| Create Visualization | 155ms (9%) | 151ms (9%) | -4ms |
| Extract Layers | 557ms (32%) | 552ms (32%) | -5ms |
| **TOTAL PIPELINE** | **1757ms** | **1750ms** | **-7ms** |

#### Key Insights
- **Metal K-means is 3.1x faster** than SwiftKMeansPlusPlus (56ms → 18ms)
  - Metal: 2.7ms initialization + 13ms iteration loop
  - Swift: 31.9ms initialization + 24.1ms assignment mapping
- **CPU-bound operations dominate** overall time (82%):
  - Extract superpixels: 50-53% (CPU-bound buffer operations)
  - Extract layers: 31-32% (CPU-bound pixel manipulation)
- K-means clustering is only 1-3% of total pipeline time
- 38ms saved by Metal K-means represents just 2% of total time

#### Metal K-means Implementation Details
- **Algorithm**: K-means++ initialization with D² sampling
- **Convergence**: 4-9 iterations typical (vs SwiftKMeansPlusPlus's fixed iteration count)
- **GPU Kernels**:
  - `calculateMinDistances`: Find nearest center for K-means++ sampling
  - `calculateDistanceSquaredProbabilities`: Compute D² probabilities
  - `assignPointsToClusters`: Assign each point to nearest cluster
  - `accumulateClusterData`: Simple atomic accumulation (direct `atomic_fetch_add`)
  - `updateClusterCenters`: Calculate new centers as mean of assigned points
  - `checkConvergence`: Sum center movement deltas
- **Debug vs Release**:
  - Debug: `waitUntilCompleted()` after each kernel for timing breakdowns
  - Release: Single sync at end for GPU pipelining
- **Memory**: Shared buffers for CPU/GPU interop, flat float arrays for atomic operations

#### Lessons Learned
1. **Simple atomics work best**: Direct `atomic_fetch_add` outperformed complex threadgroup reductions with CAS loops
2. **Over-optimization backfires**: Initial 100x slowdown from complex atomic patterns
3. **Bottlenecks are elsewhere**: Despite 3x speedup in K-means, overall pipeline unchanged due to CPU-bound stages
4. **GPU parallelism needs proper sync**: Release builds will benefit from removing intermediate waits

#### Future Optimizations
To improve overall pipeline performance:
1. Move superpixel extraction to GPU (50% of time)
2. GPU-accelerate layer extraction (32% of time)
3. Combined Metal compute passes to reduce CPU/GPU sync points

## Default Settings
- Number of Layers: 4
- Gradient Grouping (Compactness): 25
- Superpixel Detail: 1500
- Region Separation: Off
- Max Regions per Color: 2
- Edge Mode: Soft (anti-aliased)

## Remaining TODO Items / Future Enhancements

### High Priority
1. **Performance Optimization**: Processing takes a few seconds - could be optimized with caching or WebAssembly
2. **Better Reconstruction**: Currently reconstruction from selected layers works but could be smoother
3. **Color Naming**: Auto-detect and name layers (e.g., "Blue Background", "Red Icon")

### Medium Priority
1. **Undo/Redo**: Add history for parameter changes
2. **Save/Load Settings**: Remember user's preferred parameters
3. **Batch Processing**: Handle multiple icons at once
4. **Manual Region Selection**: Click on image to select/deselect specific regions
5. **Preview Zoom**: Allow zooming in on layer previews

### Low Priority
1. **Export Formats**: Support for PSD, Sketch, or Figma formats
2. **Color Statistics**: Show RGB/HEX values, histograms
3. **Mobile Support**: Responsive design for tablets/phones
4. **Preset Themes**: Quick settings for common icon types
5. **API Mode**: REST API for programmatic access

## Known Issues
1. **Soft Edge Reconstruction**: Fixed but could use further refinement
2. **Large Images**: Performance degrades with images larger than 1024x1024
3. **Complex Gradients**: Sometimes splits gradients unnecessarily

## Usage Instructions
1. Install dependencies: `pip install -r requirements.txt`
2. Run server: `python server.py`
3. Open browser: `http://localhost:5000`
4. Drag & drop icon, adjust settings, export layers

## File Structure
```
decompositer/
├── server.py           # Flask backend
├── processor.py        # Image processing logic
├── static/
│   ├── index.html     # UI structure
│   ├── style.css      # Styling
│   └── app.js         # Frontend logic
├── uploads/           # Temporary upload storage
├── exports/           # Temporary export storage
├── requirements.txt   # Python dependencies
├── README.md          # User documentation
└── PROJECT_NOTES.md   # This file - developer notes
```

## Testing Notes
- Tested with various app icons including calculators, home control apps, chat apps
- Works best with icons that have 2-10 distinct color regions
- Handles gradients well with compactness setting of 25
- Calculator button issue solved with max regions per color limit

## Contact/Credits
Developed as a tool to help developers adapt to Apple's new layered icon requirements.
Uses SLIC algorithm from scikit-image and K-means clustering for color segmentation.