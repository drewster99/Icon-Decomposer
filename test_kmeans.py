#!/usr/bin/env python3
"""Test script to see K-means diagnostics"""

from processor import IconProcessor
import sys

# Create processor instance
processor = IconProcessor()

# Test with a sample image - you'll need to provide a path
if len(sys.argv) > 1:
    image_path = sys.argv[1]
else:
    print("Please provide an image path as argument")
    print("Usage: python3 test_kmeans.py /path/to/image.png")
    sys.exit(1)

# Process with different layer counts to see convergence behavior
for n_layers in [2, 4, 6, 8]:
    print(f"\n\nTesting with {n_layers} layers:")
    print("-" * 40)

    params = {
        'n_layers': n_layers,
        'compactness': 25,
        'n_segments': 800,
        'distance_threshold': 'off',
        'max_regions_per_color': 2,
        'edge_mode': 'soft',
        'visualize_steps': False  # Don't need visualizations for this test
    }

    result = processor.process_image(image_path, params)
    print(f"Result: {result['statistics']['n_layers']} layers generated")