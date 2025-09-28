# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Icon Decomposer is a web application for decomposing 1024×1024 app icons into separate color layers using advanced image processing algorithms. The tool is designed for Apple's layered app icon system.

## Development Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Start the development server
python server.py

# The application runs on http://localhost:5000
```

## Architecture

### Backend Architecture
- **server.py**: Flask web server handling HTTP routes, file uploads, and API endpoints
  - Processes images through `/process` endpoint
  - Manages file I/O for uploads and exports
  - Converts numpy arrays to base64 for client transmission

- **processor.py**: Core image processing engine implementing the decomposition algorithm
  - **IconProcessor** class handles the full processing pipeline:
    1. SLIC superpixel segmentation (divides image into ~500-1000 regions)
    2. Feature extraction from superpixels
    3. K-means clustering in LAB color space
    4. Connected component analysis for region separation
    5. Layer generation with transparency

### Frontend Architecture
- **static/index.html**: UI structure with drag-drop upload area and controls
- **static/app.js**: JavaScript handling user interactions, canvas rendering, and API calls
- **static/style.css**: Styling with responsive two-column layout for wide screens

### Processing Flow
1. User uploads image via drag-and-drop → Frontend validates and sends to `/process`
2. Backend processes with configurable parameters (layers, compactness, detail level)
3. Returns base64-encoded layer images and visualizations
4. Frontend renders layers with checkboxes for selective export
5. Export creates ZIP file with only selected layers

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

## Performance Optimizations Completed

### Original Performance (before optimizations)
- Total request time: **7.3 seconds**
- Feature extraction: 2.6s (looping through 1,465 superpixels)
- Visualization generation: 2.7s (full 1024×1024 resolution)
- Response encoding: 1.0-1.2s (base64 encoding all images)
- SLIC segmentation: 0.45s
- Reconstruction: 450ms (full resolution)

### Current Performance (after optimizations)
- **Initial request**: **1.3-1.6 seconds** (4.5-5.6x faster)
- **Changing only layers**: **0.87 seconds** (8.4x faster)

#### Specific Improvements:
1. **Feature extraction**: 2.6s → 0.06s (42x faster using scipy.ndimage.mean)
2. **Visualization generation**: 2.7s → 0.22s (12x faster at 256px resolution)
3. **Response encoding**: 1.0s → 0.4-0.6s (2x faster with preview/full split)
4. **Reconstruction**: 450ms → 25-70ms (7x faster at 256px)
5. **Caching**: Skips SLIC (0.45s) and features (0.06s) when only n_layers changes

### Optimization Techniques Applied:
- Vectorized operations replacing Python loops
- 256×256 preview generation for display (full-res kept for export)
- Content-based caching using SHA-256 hash
- Selective visualization regeneration
- Smart layer group management in UI

## Testing Approach

No formal test suite currently exists. Testing is done manually by:
1. Running the server locally
2. Uploading various icon types (calculators, chat apps, etc.)
3. Adjusting parameters and verifying layer separation
4. Checking export functionality with different selections