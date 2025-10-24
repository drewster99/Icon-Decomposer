# ImageColorSegmentation

A Swift package for advanced image color segmentation using SLIC superpixels and K-means++ clustering, optimized for Metal GPU acceleration.

## Quick Demo

```bash
# 1. Metal availability check (fastest)
swift run Demo

# 2. Package demo with synthetic image
swift run ImageColorSegmentationDemo

# 3. Full pipeline with real image + layer export
swift run BasicUsageExample
# Creates: output_layers/layer_0.png ... layer_4.png

# 4. Run all tests
swift test
```

**See [RUNNING.md](RUNNING.md) for detailed information on all executables.**

## Overview

ImageColorSegmentation provides a flexible, pipeline-based API for decomposing images into color layers. It uses:
- **SLIC** (Simple Linear Iterative Clustering) for superpixel segmentation
- **K-means++** clustering in LAB color space for color grouping
- **Metal** acceleration for high-performance GPU processing

## Features

- 🚀 **Metal-accelerated** processing pipeline
- 🔄 **Flexible API** - configure once, execute on multiple images
- 📊 **Type-safe** operation chaining with validation
- 🎨 **LAB color space** support with configurable scaling
- 🧪 **Fully tested** with comprehensive unit and integration tests
- 📦 **Reusable** operations - branch pipelines for different parameters
- 🌿 **Pipeline branching** - share expensive operations (SLIC) across multiple variants
- ⚡️ **Concurrent execution** - run multiple branches in parallel with async/await

## Requirements

- macOS 13.0+ or iOS 16.0+
- Swift 5.9+
- Metal-capable device

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/ImageColorSegmentation.git", from: "1.0.0")
]
```

Or add via Xcode: File → Add Package Dependencies

## Usage

### Basic Pipeline

```swift
import ImageColorSegmentation

// Create and execute a simple pipeline
let pipeline = try ImagePipeline()
    .convertColorSpace(to: .lab, scale: .emphasizeGreens)
    .segment(superpixels: 1000, compactness: 25)
    .cluster(into: 5, seed: 42)
    .extractLayers()

let result = try await pipeline.execute(input: myImage)

// Access results
let layers = result.buffer(named: "layers")
let clusterCount: Int? = result.metadata(for: "clusterCount")
```

### Reusable Pipeline Template

```swift
// Configure once
let template = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 5, seed: 42)
    .extractLayers()

// Execute on multiple images
let result1 = try await template.execute(input: image1)
let result2 = try await template.execute(input: image2)
let result3 = try await template.execute(input: image3)
```

### Batch Processing

```swift
let images = [image1, image2, image3]

let results = try await pipeline.execute(inputs: images)

for result in results {
    // Process each result
    print("Final type: \(result.finalType)")
}
```

### LAB Color Space Scaling

```swift
// Default scaling
.convertColorSpace(to: .lab, scale: .default)  // L:1.0, a:1.0, b:1.0

// Emphasize greens
.convertColorSpace(to: .lab, scale: .emphasizeGreens)  // L:1.0, a:1.0, b:2.0

// Custom scaling
.convertColorSpace(to: .lab, scale: LABScale(l: 1.0, a: 1.5, b: 2.5))
```

### Multiple Merge Operations

```swift
let pipeline = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 20)
    .autoMerge(threshold: 0.20)  // First merge pass
    .autoMerge(threshold: 0.35)  // Second merge pass
    .extractLayers()
```

### Accessing Intermediate Results

```swift
let result = try await pipeline.execute(input: image)

// Access specific buffers
let labBuffer = result.buffer(named: "labImage")
let labelMap = result.buffer(named: "labelMap")
let features = result.buffer(named: "superpixelFeatures")

// Access metadata
let width: Int? = result.metadata(for: "width")
let height: Int? = result.metadata(for: "height")
let superpixelCount: Int? = result.metadata(for: "superpixelCount")
```

### Pipeline Branching (Share Expensive Operations)

Branching allows you to reuse results from expensive operations (like SLIC) and only run new operations:

```swift
// Create parent pipeline up to SLIC
let slicPipeline = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)

let slicResult = try await slicPipeline.execute(input: image)

// Branch 1: Cluster into 3 layers
let branch3 = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 3, seed: 42)
    .extractLayers()

let result3 = try await branch3.execute(from: slicResult)

// Branch 2: Cluster into 5 layers
let branch5 = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 5, seed: 42)
    .extractLayers()

let result5 = try await branch5.execute(from: slicResult)

// Both branches share the SLIC results - no redundant computation!
```

### Concurrent Branch Execution

Execute multiple branches in parallel:

```swift
let slicResult = try await slicPipeline.execute(input: image)

// Create branches
let branch3 = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 3)
    .extractLayers()

let branch5 = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 5)
    .extractLayers()

let branch7 = try ImagePipeline()
    .convertColorSpace(to: .lab)
    .segment(superpixels: 1000)
    .cluster(into: 7)
    .extractLayers()

// Execute all branches concurrently
async let r3 = branch3.execute(from: slicResult)
async let r5 = branch5.execute(from: slicResult)
async let r7 = branch7.execute(from: slicResult)

let (result3, result5, result7) = try await (r3, r5, r7)

// All three variants computed in parallel!
```

## Pipeline Operations

### Available Operations

- **`convertColorSpace(to:scale:)`** - Convert RGB to LAB color space with optional scaling
- **`segment(superpixels:compactness:)`** - SLIC superpixel segmentation
- **`cluster(into:seed:)`** - K-means++ clustering with optional seed for reproducibility
- **`extractLayers()`** - Extract individual layers from clusters
- **`autoMerge(threshold:)`** - Merge similar clusters based on distance threshold

### Data Flow

Operations must follow a valid data flow:

```
RGBA Image → LAB Image → Superpixel Features → Cluster Assignments → Layers
```

The pipeline validates type compatibility automatically and throws `PipelineError.incompatibleDataTypes` for invalid sequences.

## Current Status

### Implemented
- ✅ Pipeline architecture with operation queue
- ✅ Type validation system
- ✅ Metal command buffer management
- ✅ Basic operation stubs (color conversion, segmentation, clustering, layer extraction, merging)
- ✅ Batch processing support
- ✅ Pipeline branching with `execute(from:)` for sharing results
- ✅ Concurrent branch execution with async/await
- ✅ Comprehensive test suite (14 tests, all passing)

### TODO (Stub Operations Need Implementation)
- ⏳ Metal shaders for RGB → LAB conversion
- ⏳ SLIC superpixel segmentation shader
- ⏳ K-means++ clustering shader with smart initialization
- ⏳ Layer extraction shader
- ⏳ Cluster merging algorithm
- ⏳ MTLSharedEvent-based step completion (currently waits for full pipeline)

## Quick Start / Demo

### 1. Run the Metal check demo:

```bash
swift run Demo
```

This runs a simple Metal availability check and shows example usage.

### 2. Run the package demo with synthetic image:

```bash
swift run ImageColorSegmentationDemo
```

This demonstrates:
- Basic pipeline execution
- Pipeline branching (sharing SLIC results)
- Concurrent branch execution

### 3. Run the basic usage examples:

```bash
swift run BasicUsageExample
```

This runs the basic pipeline with a real 1024×1024 test image:
- ✅ Loads test-icon.png from package resources
- ✅ Runs complete SLIC + K-means++ pipeline
- ✅ Extracts 5 color layers
- ✅ **Saves layers as PNG files** to `output_layers/`
- ✅ Creates README.txt with configuration details

**Output**: `output_layers/layer_0.png` through `layer_4.png` + `README.txt`

**Note**: Current operations are stubs - layers are placeholder colored images. Once Metal shaders are implemented, these will be actual color-separated layers from the source image.

### 4. Run tests:

```bash
swift test
```

All 14 tests currently pass:
- Pipeline configuration tests (6 tests)
- Pipeline execution tests (4 tests)
- Pipeline branching tests (4 tests)
  - Basic branching
  - Concurrent branching
  - Branching with different seeds
  - Deep branching (multi-level)

## Architecture

### Core Components

- **`ImagePipeline`** - Main pipeline class that manages operations and execution
- **`PipelineOperation`** - Protocol for pipeline operations
- **`ExecutionContext`** - Shared context passed through operations
- **`DataType`** - Enum representing data types flowing through pipeline
- **`PipelineExecution`** - Result object containing buffers and metadata

### Design Principles

1. **Type Safety** - Operations validate input/output types at build time
2. **Metal First** - All heavy processing on GPU
3. **Flexible API** - Support both simple and advanced use cases
4. **Reproducibility** - Seed support for deterministic results
5. **Resource Efficiency** - Metal buffers managed throughout pipeline

## License

[Your license here]

## Contributing

[Contributing guidelines here]
