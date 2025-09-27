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