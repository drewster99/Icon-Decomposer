import numpy as np
from PIL import Image
from skimage import segmentation, color, measure
from sklearn.cluster import KMeans
import cv2
from scipy import ndimage
from collections import defaultdict
import warnings
warnings.filterwarnings('ignore')

class IconProcessor:
    def __init__(self):
        self.original_image = None
        self.superpixels = None
        self.clusters = None
        self.layers = None

    def process_image(self, image_path, params):
        """Main processing pipeline"""
        # Load image
        img = Image.open(image_path)
        if img.mode == 'RGBA':
            # Convert RGBA to RGB by compositing on white background
            background = Image.new('RGB', img.size, (255, 255, 255))
            background.paste(img, mask=img.split()[3] if img.mode == 'RGBA' else None)
            img = background
        elif img.mode != 'RGB':
            img = img.convert('RGB')

        # Ensure image is 1024x1024
        if img.size != (1024, 1024):
            img = img.resize((1024, 1024), Image.Resampling.LANCZOS)

        self.original_image = np.array(img)

        result = {
            'status': 'success',
            'layers': [],
            'statistics': {},
            'visualizations': {}
        }

        # Step 1: SLIC Superpixel Segmentation
        self.superpixels = self._perform_slic(
            self.original_image,
            n_segments=params['n_segments'],
            compactness=params['compactness']
        )

        # Step 2: Extract superpixel features
        superpixel_colors = self._extract_superpixel_colors(
            self.original_image,
            self.superpixels
        )

        # Step 3: K-means clustering in LAB space
        cluster_labels = self._perform_kmeans(
            superpixel_colors,
            n_clusters=params['n_layers']
        )

        # Step 4: Map clusters back to pixels
        pixel_clusters = cluster_labels[self.superpixels]

        # Step 5: Connected component analysis with distance threshold
        if params['distance_threshold'] != 'off':
            pixel_clusters = self._apply_distance_threshold(
                pixel_clusters,
                params['distance_threshold'],
                params['n_layers'],
                params.get('max_regions_per_color', 3)
            )

        # Step 6: Generate layer masks
        self.layers = self._generate_layers(
            self.original_image,
            pixel_clusters,
            params['edge_mode']
        )

        result['layers'] = self.layers

        # Generate visualizations if requested
        if params['visualize_steps']:
            result['visualizations'] = self._generate_visualizations(
                self.original_image,
                self.superpixels,
                superpixel_colors,
                cluster_labels,
                pixel_clusters
            )

        # Calculate statistics
        result['statistics'] = self._calculate_statistics(
            pixel_clusters,
            self.layers
        )

        return result

    def _perform_slic(self, image, n_segments, compactness):
        """Perform SLIC superpixel segmentation"""
        # Apply slight Gaussian blur to help with gradients
        smoothed = cv2.GaussianBlur(image, (3, 3), 0.5)

        # Perform SLIC
        segments = segmentation.slic(
            smoothed,
            n_segments=n_segments,
            compactness=compactness,
            sigma=1,
            enforce_connectivity=True,
            convert2lab=True
        )

        return segments

    def _extract_superpixel_colors(self, image, segments):
        """Extract average color for each superpixel in LAB space"""
        # Convert to LAB color space
        lab_image = color.rgb2lab(image)

        n_segments = segments.max() + 1
        colors = np.zeros((n_segments, 3))

        for i in range(n_segments):
            mask = segments == i
            if mask.any():
                colors[i] = lab_image[mask].mean(axis=0)

        return colors

    def _perform_kmeans(self, colors, n_clusters):
        """Perform K-means clustering on superpixel colors"""
        kmeans = KMeans(
            n_clusters=n_clusters,
            random_state=42,
            n_init=10,
            max_iter=300
        )

        cluster_labels = kmeans.fit_predict(colors)
        self.clusters = kmeans.cluster_centers_

        return cluster_labels

    def _apply_distance_threshold(self, pixel_clusters, threshold, n_layers, max_regions_per_color):
        """Apply distance threshold to separate disconnected regions of same color"""
        result = np.copy(pixel_clusters)
        next_label = n_layers

        for cluster_id in range(n_layers):
            mask = (pixel_clusters == cluster_id)

            # Find connected components
            labeled, num_features = ndimage.label(mask)

            if num_features > 1:
                # Calculate component sizes
                component_sizes = []
                for i in range(1, num_features + 1):
                    size = np.sum(labeled == i)
                    component_sizes.append((i, size))

                # Sort by size (largest first)
                component_sizes.sort(key=lambda x: x[1], reverse=True)

                # Limit the number of regions per color
                regions_to_create = min(num_features, max_regions_per_color)

                # Only split if we have more components than max_regions_per_color
                if num_features > max_regions_per_color:
                    # Keep the largest N-1 components separate
                    for idx in range(1, regions_to_create):
                        comp_id, size = component_sizes[idx]
                        result[labeled == comp_id] = next_label
                        next_label += 1

                    # Merge all remaining smaller components with the last allowed region
                    if regions_to_create < num_features:
                        # The last region gets all the remaining small components
                        last_label = next_label - 1
                        for idx in range(regions_to_create, num_features):
                            comp_id, size = component_sizes[idx]
                            result[labeled == comp_id] = last_label

                elif num_features > 1 and threshold == 'auto':
                    # If within limit but auto mode, only split if significant
                    significant_components = [
                        c for c in component_sizes
                        if c[1] > (mask.sum() * 0.05)  # At least 5% of total cluster size
                    ]

                    if len(significant_components) > 1:
                        # Split significant components (up to max_regions_per_color)
                        for idx in range(1, min(len(significant_components), max_regions_per_color)):
                            comp_id = significant_components[idx][0]
                            result[labeled == comp_id] = next_label
                            next_label += 1

        return result

    def _generate_layers(self, image, pixel_clusters, edge_mode):
        """Generate individual layer images with transparency"""
        unique_clusters = np.unique(pixel_clusters)
        layers = []

        for cluster_id in unique_clusters:
            # Create mask for this cluster
            mask = (pixel_clusters == cluster_id).astype(np.float32)

            # Create RGBA layer
            layer = np.zeros((image.shape[0], image.shape[1], 4), dtype=np.float32)

            # Handle edge mode
            if edge_mode == 'hard':
                # Hard edges: binary mask
                alpha_mask = mask
                # Apply mask to extract only this cluster's pixels
                for c in range(3):
                    layer[:, :, c] = (image[:, :, c] / 255.0) * mask
                layer[:, :, 3] = alpha_mask
            else:
                # Soft edges: blur the mask for anti-aliasing
                # Create a slightly dilated mask for color extraction
                kernel = np.ones((3, 3), np.uint8)
                dilated_mask = cv2.dilate(mask, kernel, iterations=1)

                # Extract colors from dilated region (to ensure edge colors are captured)
                for c in range(3):
                    layer[:, :, c] = (image[:, :, c] / 255.0) * dilated_mask

                # Apply Gaussian blur to alpha channel for soft edges
                alpha_mask = cv2.GaussianBlur(mask, (3, 3), 0.8)
                layer[:, :, 3] = alpha_mask

                # DON'T multiply RGB by alpha - keep full color values at edges

            layers.append(layer)

        return layers

    def _generate_visualizations(self, image, superpixels, superpixel_colors,
                                 cluster_labels, pixel_clusters):
        """Generate visualization images for each processing step"""
        visualizations = {}

        # 1. Original image
        visualizations['original'] = image

        # 2. Superpixel boundaries
        boundaries = segmentation.mark_boundaries(image, superpixels, color=(1, 0, 0))
        visualizations['superpixels'] = (boundaries * 255).astype(np.uint8)

        # 3. Superpixel average colors
        avg_image = np.zeros_like(image, dtype=np.float64)
        lab_to_rgb_colors = color.lab2rgb(superpixel_colors.reshape(1, -1, 3)).reshape(-1, 3)
        for i in range(superpixels.max() + 1):
            mask = superpixels == i
            avg_image[mask] = lab_to_rgb_colors[i] * 255
        visualizations['superpixel_colors'] = avg_image.astype(np.uint8)

        # 4. Clustered result
        clustered_image = np.zeros_like(image, dtype=np.float64)
        if self.clusters is not None:
            cluster_colors_rgb = color.lab2rgb(self.clusters.reshape(1, -1, 3)).reshape(-1, 3)
            for i in np.unique(pixel_clusters):
                mask = pixel_clusters == i
                if i < len(cluster_colors_rgb):
                    clustered_image[mask] = cluster_colors_rgb[i] * 255
        visualizations['clustered'] = clustered_image.astype(np.uint8)

        # 5. Reconstruction preview (stack all layers)
        reconstruction = np.zeros((image.shape[0], image.shape[1], 3), dtype=np.float32)
        for layer in self.layers:
            alpha = layer[:, :, 3:4]
            reconstruction += layer[:, :, :3] * alpha
        reconstruction = np.clip(reconstruction * 255, 0, 255).astype(np.uint8)
        visualizations['reconstruction'] = reconstruction

        return visualizations

    def _calculate_statistics(self, pixel_clusters, layers):
        """Calculate statistics about the decomposition"""
        stats = {
            'n_layers': len(layers),
            'layer_sizes': []
        }

        for i, layer in enumerate(layers):
            mask = layer[:, :, 3] > 0.01
            pixel_count = np.sum(mask)
            percentage = (pixel_count / (1024 * 1024)) * 100

            # Get dominant color
            visible_pixels = layer[mask]
            if len(visible_pixels) > 0:
                avg_color = visible_pixels[:, :3].mean(axis=0) * 255
                avg_color = avg_color.astype(int).tolist()
            else:
                avg_color = [0, 0, 0]

            stats['layer_sizes'].append({
                'layer_id': i,
                'pixel_count': int(pixel_count),
                'percentage': round(percentage, 2),
                'average_color_rgb': avg_color
            })

        return stats