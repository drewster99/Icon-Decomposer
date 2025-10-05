---

## Image Processing Pipeline (Production)

### Core Production Pipeline

```
1. Image Load + Color Conversion
   ├─ Load NSImage from file/asset
   ├─ Extract BGRA pixel data
   ├─ Metal: Gaussian blur (optional, for noise reduction)
   └─ Metal: RGB → LAB color conversion (with green axis scaling)

2. SLIC Superpixel Segmentation
   ├─ Metal: Initialize superpixel centers (grid)
   ├─ Metal: Iterative assignment + center updates
   ├─ Metal: Optional connectivity enforcement
   └─ Output: labelMap (which superpixel each pixel belongs to)

3. Superpixel Feature Extraction
   ├─ Metal: Parallel accumulation of LAB colors per superpixel
   ├─ Metal: Parallel accumulation of positions per superpixel
   └─ Output: SuperpixelData (avg color, position, pixel count per superpixel)

4. K-means Clustering
   ├─ Metal: K-means++ initialization (RANDOM - needs seed!)
   │   └─ Uses Int.random() and Float.random() - non-deterministic
   ├─ Metal: Iterative cluster assignment + center recalculation
   ├─ Map superpixel clusters → pixel clusters
   └─ Output: ClusteringResult (which cluster each superpixel belongs to)

5. Layer Extraction
   ├─ Metal: Extract pixels belonging to each cluster
   ├─ Create separate BGRA images (one per cluster)
   └─ Output: Array of layer images with transparency

6. Optional: Cluster Merging
   ├─ Calculate distance matrix between cluster centers
   ├─ Iteratively merge closest pairs below threshold
   ├─ Recalculate cluster assignments after each merge
   └─ Output: Reduced set of merged layers

7. Export (NOT YET IMPLEMENTED)
   └─ Export selected layers as PNG files or ZIP
```

### Current Randomness Points ⚠️

**KMeansProcessor.swift:378**
```swift
let firstIndex = Int.random(in: 0..<numPoints)  // First center selection
```

**KMeansProcessor.swift:449**
```swift
let random = Float.random(in: 0..<1)  // K-means++ distance-weighted sampling
```

**CRITICAL:** Need seeded random number generator for reproducible results in testing!

### Debug/Visualization Overhead

Current implementation generates extensive debug data:
- SLIC boundary visualization (segmentedImage)
- Superpixel average color visualization
- K-means cluster visualization (color by cluster center)
- Weighted k-means visualization (with lightness weighting)
- Iteration history snapshots (cluster centers at each k-means iteration)
- Merge history snapshots (state after each cluster merge)
- Distance matrices (unweighted & weighted)
- True cluster average colors (recalculated from original pixels)
- Layer recomposition (debugging to verify all layers = original)

**Production version should skip all of this and only generate final layers.**

---

## Swift Package Plan: ImageColorSegmentation

### Package Structure

```
ImageColorSegmentation/
├── Package.swift
├── README.md
├── LICENSE
└── Sources/
    ├── ImageColorSegmentation/          // Main public API
    │   ├── ImageSegmenter.swift         // High-level coordinator
    │   ├── SegmentationResult.swift     // Result type with layers
    │   ├── SegmentationParameters.swift // Configuration
    │   └── NSImage+Extensions.swift     // Convenience methods
    │
    ├── SLICSegmentation/                // SLIC algorithm (internal)
    │   ├── SLICProcessor.swift
    │   ├── Shaders/
    │   │   └── SLIC.metal
    │   └── Models/
    │       ├── Superpixel.swift
    │       └── SuperpixelData.swift
    │
    ├── KMeansClustering/                // K-means algorithm (internal)
    │   ├── KMeansProcessor.swift
    │   ├── MetalKMeansProcessor.swift
    │   ├── SeededRandom.swift          // NEW: For reproducibility
    │   ├── Shaders/
    │   │   └── KMeans.metal
    │   └── Models/
    │       └── ClusteringResult.swift
    │
    ├── ColorConversion/                 // LAB ↔ RGB utilities (internal)
    │   ├── ColorConverter.swift
    │   └── Shaders/
    │       └── ColorConversion.metal
    │
    ├── LayerExtraction/                 // Layer creation (internal)
    │   ├── LayerExtractor.swift
    │   ├── Layer.swift
    │   ├── Shaders/
    │   │   └── LayerExtraction.metal
    │   └── ClusterMerger.swift         // Optional merging
    │
    └── ImageIO/                         // Import/Export (internal)
        ├── ImageLoader.swift
        └── LayerExporter.swift
```

### Dream API (Simplest Possible)

```swift
import ImageColorSegmentation

// One-liner with defaults
let layers = try await NSImage(named: "icon")!.extractColorLayers()

// With configuration
let layers = try await NSImage(named: "icon")!.extractColorLayers(
    count: 5,
    detail: .high,
    seed: 12345
)

// Export
try await layers.export(to: URL(fileURLWithPath: "output/"))
```

### More Explicit API (More Control)

```swift
import ImageColorSegmentation

let processor = ImageSegmenter()

let result = try await processor.segment(
    image: nsImage,
    parameters: .init(
        layers: 5,
        segmentDetail: 1000,
        compactness: 25,
        seed: 12345
    )
)

// Access layers
for (index, layer) in result.layers.enumerated() {
    print("Layer \(index): \(layer.pixelCount) pixels, color: \(layer.averageColor)")
}

// Export individual or all
try result.exportLayer(0, to: URL(...))
try result.exportAll(to: URL(...))  // Creates ZIP or folder

// Optional: Merge similar layers
let merged = try await result.mergeSimilar(threshold: 30.0)
```

### Package.swift Template

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageColorSegmentation",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(
            name: "ImageColorSegmentation",
            targets: ["ImageColorSegmentation"]
        ),
    ],
    targets: [
        // Main public API (depends on all internal modules)
        .target(
            name: "ImageColorSegmentation",
            dependencies: [
                "SLICSegmentation",
                "KMeansClustering",
                "ColorConversion",
                "LayerExtraction",
                "ImageIO"
            ]
        ),

        // Internal modules (can be tested independently)
        .target(name: "SLICSegmentation", dependencies: ["ColorConversion"]),
        .target(name: "KMeansClustering", dependencies: ["ColorConversion"]),
        .target(name: "ColorConversion"),
        .target(name: "LayerExtraction"),
        .target(name: "ImageIO"),

        // Tests
        .testTarget(
            name: "ImageColorSegmentationTests",
            dependencies: ["ImageColorSegmentation"]
        ),
        .testTarget(
            name: "SLICSegmentationTests",
            dependencies: ["SLICSegmentation"]
        ),
        .testTarget(
            name: "KMeansClusteringTests",
            dependencies: ["KMeansClustering"]
        ),
    ]
)
```

### Minimal Test App Example

```swift
import ImageColorSegmentation

@main
struct TestApp {
    static func main() async throws {
        let image = NSImage(contentsOfFile: "test-icon.png")!

        let result = try await ImageSegmenter().segment(
            image: image,
            parameters: .init(
                layers: 5,
                seed: 42  // Reproducible!
            )
        )

        print("Extracted \(result.layers.count) layers")

        // Export all layers
        try result.exportAll(to: URL(fileURLWithPath: "output/"))

        // Or export individually
        for (index, layer) in result.layers.enumerated() {
            let url = URL(fileURLWithPath: "output/layer-\(index).png")
            try layer.export(to: url)
        }
    }
}
```

---

## Current Xcode Project State

### File Sizes (SLIC_POC_MetalKMeans)
- **ContentView.swift**: 2,223 lines (MASSIVE - needs refactoring)
- **KMeansProcessor.swift**: 966 lines
- **SLICProcessor.swift**: 586 lines
- **SuperpixelProcessor.swift**: 483 lines
- **LayerExtractor.swift**: 339 lines
- **TOTAL**: 4,614 lines Swift + Metal shaders

### Targets
- **SLIC_ProofOfConcept**: Original CPU-based version (IGNORE - left untouched)
- **SLIC_POC_MetalKMeans**: Active development, optimized Metal GPU version
- **IconDecomposer**: Empty placeholder ("Hello World")

---

## Immediate Next Steps

### Phase 1: Extract Reusable UI Components (2-3 files) - APPROVED
From ContentView.swift, extract:
- `CheckerboardBackground.swift` (lines 30-63)
- `ColorSwatchView.swift` (lines 1028-1125)
- `ColorConversion.swift` (LAB↔RGB utilities, ~200 lines)

### Phase 2: Create Swift Package
1. Create new Swift Package: `ImageColorSegmentation`
2. Set up module structure (see above)
3. Move processing code from SLIC_POC_MetalKMeans into appropriate modules
4. Design clean public API

### Phase 3: Add Missing Features
- **Seeded random number generator** for K-means++ reproducibility
- **Export functionality** (PNG layers, ZIP packaging)
- **Parameter presets** (optional)
- **Progress reporting** (optional, for UI)

### Phase 4: Build Production App
Option A: Rebuild IconDecomposer target using the package
Option B: Create new standalone app that depends on the package

---

## Key Design Principles

1. **Extremely simple API** - Should be trivial to use in a test app
2. **Reproducible results** - Seed support is CRITICAL for testing
3. **Internal modularity** - Each algorithm can be tested independently
4. **Metal-first** - All heavy processing on GPU
5. **Public vs Internal** - Only expose high-level API, keep implementation details internal
6. **Async/await** - Modern Swift concurrency for long-running operations
7. **Zero debug overhead** - Production mode skips all visualization/debug data

---

## Questions to Resolve

1. Should we support both sync and async APIs?
2. What's the minimum macOS/iOS version we want to support?
3. Export format: Individual PNGs? ZIP? Both?
4. Should merge functionality be part of the main flow or separate?
5. Do we want to expose any intermediate results (superpixels, clusters)?
6. License? (MIT, Apache, etc.)

---

## Performance Targets (Current MetalKMeans)

Current MetalKMeans performance (1024×1024, 1024 superpixels, 5 clusters):
- SLIC Processing: 37ms
- Extract Superpixels: 2.4ms (366x faster than CPU version!)
- K-means Clustering: 9ms
- Map to Pixels: 115ms
- Extract Layers: 725ms
- **TOTAL: ~1001ms** (~1 second)

Production version should be similar or faster by skipping debug overhead.

---

## Alternative Package Names to Consider

- `ImageColorSegmentation` (current choice)
- `SwiftImageSegmentation`
- `ColorLayerExtraction`
- `IconDecomposer` (too specific)
- `SLICKMeans` (too technical)
- `LayerKit`
- `ColorSeparation`

---

## Notes

- Python web app has content-based SHA-256 caching - could add similar to Swift package
- Green axis scaling (current: 2.0) is important for separating greens - should be configurable
- Lightness weighting (current: 0.35) affects clustering - needs testing to find good defaults
- Current implementation composites semi-transparent pixels over white in cluster averages
- Metal shaders use simple atomics (faster than complex threadgroup reductions)
- SwiftKMeansPlusPlus dependency in SLIC_ProofOfConcept target - Metal version has custom implementation
