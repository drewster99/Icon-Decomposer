# Running ImageColorSegmentation

This package provides multiple executables to demonstrate and test the pipeline functionality.

## Quick Reference

```bash
# 1. Metal check (fastest, no dependencies)
swift run Demo

# 2. Pipeline demo (synthetic image)
swift run ImageColorSegmentationDemo

# 3. Full pipeline (real image + export)
swift run BasicUsageExample

# 4. Run tests
swift test

# 5. Build everything
swift build
```

## 1. Demo - Metal Availability Check

**Command**: `swift run Demo`

**What it does**:
- ✅ Checks Metal device availability
- ✅ Creates command queue
- ✅ Simulates pipeline stages
- ✅ Shows example Metal usage

**Output**:
```
=== ImageColorSegmentation End-to-End Demo ===

✅ Metal device: Apple M4 Pro
✅ Metal command queue created
✅ Created test image buffer (100x100)
✅ Filled buffer with gradient test pattern
✅ Created command buffer

📊 Simulating Pipeline Stages:
  1. RGB → LAB conversion
  2. SLIC segmentation (1000 superpixels)
  3. K-means++ clustering (5 clusters)
  4. Layer extraction

✅ Command buffer completed successfully
```

**Use case**: Quick Metal verification, no package dependencies

---

## 2. ImageColorSegmentationDemo - Package Demo

**Command**: `swift run ImageColorSegmentationDemo`

**What it does**:
- Creates synthetic test image (200×200)
- Runs 3 example scenarios:
  1. Basic pipeline
  2. Pipeline branching
  3. Concurrent branching

**Output**:
```
=== ImageColorSegmentation Package Demo ===

✅ Created test image (200x200)

📊 Example 1: Basic Pipeline
  ✅ Image: 200x200
  ✅ Superpixels: 100
  ✅ Clusters: 5
  ✅ Final type: layers

🌿 Example 2: Pipeline Branching
  ✅ SLIC completed (shared across branches)
  ✅ Branch 1: 3 clusters
  ✅ Branch 2: 5 clusters
  💡 SLIC computed only once, reused for both branches!

⚡️ Example 3: Concurrent Branching
  ✅ SLIC completed
  ✅ Branch 1: 3 clusters
  ✅ Branch 2: 5 clusters
  ✅ Branch 3: 7 clusters
  💡 All three branches executed concurrently!
```

**Use case**: Test pipeline API with synthetic image

---

## 3. BasicUsageExample - Full Pipeline with Export

**Command**: `swift run BasicUsageExample`

**What it does**:
- ✅ Loads real test-icon.png (1024×1024) from package resources
- ✅ Runs complete SLIC + K-means++ pipeline
- ✅ Extracts 5 color layers
- ✅ Saves layers as PNG files to `output_layers/`
- ✅ Creates README.txt with configuration

**Output**:
```
=== ImageColorSegmentation Examples ===

📸 Loaded image: 1024x1024
✅ Final type: layers
✅ Found 5 clusters

💾 Saving layers to: .../output_layers/
  ✅ Saved: layer_0.png (4096KB buffer → 379KB PNG)
  ✅ Saved: layer_1.png (4096KB buffer → 310KB PNG)
  ✅ Saved: layer_2.png (4096KB buffer → 313KB PNG)
  ✅ Saved: layer_3.png (4096KB buffer → 327KB PNG)
  ✅ Saved: layer_4.png (4096KB buffer → 310KB PNG)

✨ Layers exported successfully!
   📁 Output: .../output_layers
   📄 README: .../output_layers/README.txt
   🔍 View: open .../output_layers
```

**Files created**:
```
output_layers/
├── layer_0.png    (380KB)
├── layer_1.png    (310KB)
├── layer_2.png    (313KB)
├── layer_3.png    (327KB)
├── layer_4.png    (311KB)
└── README.txt     (configuration details)
```

**Use case**: Full pipeline demonstration with real image export

---

## 4. Tests - Comprehensive Test Suite

**Command**: `swift test`

**What it does**:
- Runs 14 comprehensive tests
- Tests pipeline configuration
- Tests execution flow
- Tests branching scenarios

**Output**:
```
Test Suite 'All tests' passed
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.040 (0.042) seconds
```

**Tests include**:
- PipelineConfigurationTests (6 tests)
  - Pipeline creation
  - Valid/invalid operation sequences
  - Multiple merge operations
  - LAB scaling
  - Data type validation

- PipelineExecutionTests (4 tests)
  - Basic pipeline execution
  - Batch execution
  - Metadata preservation
  - Pipeline with input in init

- PipelineBranchingTests (4 tests)
  - Basic branching
  - Concurrent branching
  - Branching with different seeds
  - Deep branching (multi-level)

---

## 5. Build - Compile Everything

**Command**: `swift build`

**What it does**:
- Builds all targets and products
- Verifies compilation
- Prepares executables

**Targets built**:
1. `ImageColorSegmentation` (library)
2. `Demo` (executable)
3. `ImageColorSegmentationDemo` (executable)
4. `BasicUsageExample` (executable)
5. `ImageColorSegmentationTests` (test target)

---

## Available Products

| Product | Type | Command | Purpose |
|---------|------|---------|---------|
| ImageColorSegmentation | Library | - | Main package API |
| Demo | Executable | `swift run Demo` | Metal check |
| ImageColorSegmentationDemo | Executable | `swift run ImageColorSegmentationDemo` | Package demo |
| BasicUsageExample | Executable | `swift run BasicUsageExample` | Full pipeline + export |

---

## Xcode Integration

All executables are available as schemes in Xcode:

1. Open package in Xcode: `xed .`
2. Select scheme from dropdown:
   - Demo
   - ImageColorSegmentationDemo
   - BasicUsageExample
3. Press ⌘R to run

---

## Notes

### Current Status
- ✅ All executables build and run successfully
- ✅ All 14 tests pass
- ⚠️  Operations are stubs (Metal shaders need implementation)

### Placeholder Layers
The exported layers from `BasicUsageExample` are **placeholder colored images** until Metal shaders are implemented. Once real SLIC and K-means++ shaders are added, the layers will contain actual color-separated regions from the source image.

### Next Steps
1. Port Metal shaders from `SLIC_POC_MetalKMeans`
2. Replace stub operations with real implementations
3. Layers will automatically export actual segmented data
