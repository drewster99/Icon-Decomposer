# TODO

## High Priority Issues

### Horizontal Scrolling Bug
- **Issue**: Persistent horizontal scrolling caused by the layout of purple background borders and white cards
- **Attempted Solutions**:
  1. Changed container padding from `2rem` to `2rem 0` and moved horizontal spacing to individual card margins
  2. Moved padding to body element with `overflow-x: hidden`
  3. Used `overflow-x: clip` on body
  4. Restructured margins to use only bottom margins on cards
- **Current State**: Body has `padding: 2rem`, container has no padding, cards have only bottom margins
- **Root Cause**: The interaction between the purple background border (which needs to be visible) and the white cards (which need to be 100% width minus borders) creates a CSS box model challenge
- **Potential Solutions to Explore**:
  - Use CSS Grid or Flexbox with gap properties instead of margins
  - Add an inner wrapper div with proper box-sizing
  - Use calc() to precisely control widths
  - Consider using CSS container queries

## Performance Optimizations

### Completed
1. **Feature Extraction Optimization**: ✅ Vectorized using scipy.ndimage.mean - reduced from 2.6s to 0.06s (42x speedup)
2. **Generate 256px Previews**: ✅ All visualizations and layer previews now rendered at 256px with full-res maintained for exports
3. **Visualization Generation at 256px**: ✅ Generate visualizations directly at 256px - reduced from 2.7s to 0.22s (12x speedup)
4. **Smart Caching for Superpixels**: ✅ Cache superpixels when only n_layers changes - 5x faster processing (1.2s → 0.25s)

### Pending
1. **Replace Base64 Encoding with File-Based Serving**:
   - Eliminate 0.4-0.6s encoding overhead by serving PNG files directly
   - Use content-based filenames for browser caching
   - Implement cleanup strategy for old files

2. **Remove Hardcoded 1024x1024 Assumptions**:
   - Support arbitrary image dimensions without distortion
   - Fix statistics calculation to use actual dimensions
   - Make reconstruction buffer dynamic

3. **Implement Full Dependency-Aware Caching**:
   - Cache at each pipeline stage (superpixels, clustering, layers)
   - Track parameter dependencies (e.g., edge_mode only affects layers)
   - Add memory management for cached data

4. **Add Client-Side Intelligence**:
   - Track last parameters to send only changes
   - Implement "regenerate_from" hints
   - Cache preview images in browser

### Performance Summary
- **Very Original** (before any optimizations): 7.3 seconds total
  - Feature extraction: 2.6s
  - Visualization generation: 2.7s
  - Response encoding: 1.0-1.2s
  - SLIC segmentation: 0.45s
  - Reconstruction: 450ms

- **Current** (after all optimizations):
  - Initial processing: 1.3-1.6 seconds
  - Changing only layers: 0.87 seconds
  - Feature extraction: 0.06s (42x faster)
  - Visualization generation: 0.22s (12x faster)
  - Response encoding: 0.4-0.6s (2x faster)
  - SLIC segmentation: 0.45s (unchanged, but cached when reusable)
  - Reconstruction: 25-70ms (7x faster)

- **Overall improvement**: 4.5-5.6x faster initial, 8.4x faster for iterations

## Feature Enhancements (from PROJECT_NOTES.md)

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