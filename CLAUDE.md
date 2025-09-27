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

## Testing Approach

No formal test suite currently exists. Testing is done manually by:
1. Running the server locally
2. Uploading various icon types (calculators, chat apps, etc.)
3. Adjusting parameters and verifying layer separation
4. Checking export functionality with different selections