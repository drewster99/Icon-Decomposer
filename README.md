# Icon Decomposer

A powerful tool for decomposing app icons into separate color layers, perfect for creating layered effects in Apple's new app icon system.

## Features

- **Smart Color Segmentation**: Uses SLIC superpixels + K-means clustering in LAB color space
- **Gradient Preservation**: Automatically groups color gradients together
- **Spatial Separation**: Intelligently separates same colors in different regions
- **Real-time Preview**: See changes instantly as you adjust parameters
- **Multiple Export Options**: Folder or suffix naming conventions
- **Visual Feedback**: Shows each processing step for full transparency

## Installation

1. Clone or download this repository
2. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Usage

1. Start the server:
   ```bash
   python server.py
   ```

2. Open your browser and navigate to:
   ```
   http://localhost:5000
   ```

3. Drag & drop your 1024×1024 icon (PNG or JPG)

4. Adjust parameters:
   - **Number of Layers** (2-10): How many color layers to create
   - **Gradient Grouping**: Controls how gradients are grouped (higher = tighter grouping)
   - **Superpixel Detail**: Fine-tune segmentation detail
   - **Region Separation**: Auto-separate disconnected regions of same color
   - **Edge Handling**: Choose between soft (anti-aliased) or hard edges

5. Export your layers:
   - Choose base name for files
   - Select folder mode (`basename/layer_0.png`) or suffix mode (`basename_0.png`)
   - Click "Export All Layers" to download a ZIP file

## How It Works

### 1. SLIC Superpixel Segmentation
The algorithm first divides your icon into ~500-1000 superpixels - small regions of similar color that respect image boundaries.

### 2. K-means Clustering in LAB Space
Superpixels are then clustered by color similarity in the perceptually-uniform LAB color space, ensuring visually similar colors group together.

### 3. Connected Component Analysis
Optionally separates spatially disconnected regions of the same color into different layers.

### 4. Layer Generation
Each cluster becomes a separate PNG with transparency, preserving the original colors and positions.

## Algorithm Parameters

### Number of Layers
- **Range**: 2-10
- **Default**: 4
- **Effect**: Determines how many separate color layers to create

### Gradient Grouping (Compactness)
- **Range**: 5-50
- **Default**: 20
- **Effect**: Lower values prioritize color similarity, higher values prioritize spatial proximity

### Superpixel Detail
- **Range**: 200-2000
- **Default**: 1500
- **Effect**: More superpixels = finer detail but slower processing

### Region Separation
- **Auto**: Intelligently limits same-color regions to 2-3 per layer
- **Off**: Keeps all instances of a color together

### Edge Handling
- **Soft**: Preserves anti-aliasing for smooth edges
- **Hard**: Creates sharp edges (threshold at 50% opacity)

## Tips for Best Results

1. **Start with default settings** - They work well for most icons

2. **For icons with gradients**: Use higher compactness (30-40) to keep gradients together

3. **For icons with distinct regions**: Enable region separation to split disconnected areas

4. **For minimal/flat icons**: Reduce number of layers to 2-4

5. **For complex icons**: Increase superpixel detail for better boundaries

## Output Format

All exported layers are:
- 1024×1024 PNG files
- Include alpha channel (transparency)
- Preserve original colors
- Stack perfectly to recreate original image

## Troubleshooting

### Server won't start
- Ensure all dependencies are installed: `pip install -r requirements.txt`
- Check that port 5000 is available
- Try Python 3.8 or newer

### Processing is slow
- Reduce superpixel detail (try 400-600)
- Process smaller test images first
- Close other browser tabs

### Colors look wrong
- Ensure your source image is RGB (not CMYK)
- Check that gradient grouping isn't too high
- Try adjusting the number of layers

## Technical Details

- **Backend**: Python with Flask, scikit-image, scikit-learn
- **Frontend**: Vanilla JavaScript with HTML5 Canvas
- **Color Space**: LAB for perceptually uniform clustering
- **Segmentation**: SLIC (Simple Linear Iterative Clustering)
- **Clustering**: K-means with multiple initializations

## License

MIT License - Feel free to use and modify as needed!