class IconDecomposer {
    constructor() {
        this.currentImage = null;
        this.processedData = null;
        this.initElements();
        this.initEventListeners();
    }

    initElements() {
        // Upload elements
        this.dropZone = document.getElementById('drop-zone');
        this.fileInput = document.getElementById('file-input');

        // Control elements
        this.controls = document.getElementById('controls');
        this.nLayersSlider = document.getElementById('n-layers');
        this.nLayersValue = document.getElementById('n-layers-value');
        this.compactnessSlider = document.getElementById('compactness');
        this.compactnessValue = document.getElementById('compactness-value');
        this.nSegmentsSlider = document.getElementById('n-segments');
        this.nSegmentsValue = document.getElementById('n-segments-value');
        this.distanceThreshold = document.getElementById('distance-threshold');
        this.maxRegionsSlider = document.getElementById('max-regions');
        this.maxRegionsValue = document.getElementById('max-regions-value');
        this.maxRegionsGroup = document.getElementById('max-regions-group');
        this.edgeMode = document.getElementById('edge-mode');
        this.processBtn = document.getElementById('process-btn');

        // Result elements
        this.visualizations = document.getElementById('visualizations');
        this.vizGrid = document.getElementById('viz-grid');
        this.results = document.getElementById('results');
        this.layersGrid = document.getElementById('layers-grid');
        this.statistics = document.getElementById('statistics');
        this.baseName = document.getElementById('base-name');
        this.folderExample = document.getElementById('folder-example');
        this.suffixExample = document.getElementById('suffix-example');
        this.iconBundleExample = document.getElementById('icon-bundle-example');
        this.selectedLayers = document.getElementById('selected-layers');
        this.exportPreview = document.getElementById('export-preview');
        this.exportBtn = document.getElementById('export-btn');
        this.previewBtn = document.getElementById('preview-btn');

        // Loading overlay
        this.loading = document.getElementById('loading');

        // Layer selection state
        this.selectedLayerIndices = new Set();
        this.currentLayers = [];
        this.layerStatistics = [];
    }

    initEventListeners() {
        // Drag and drop
        this.dropZone.addEventListener('click', () => this.fileInput.click());
        this.fileInput.addEventListener('change', (e) => this.handleFileSelect(e.target.files[0]));

        this.dropZone.addEventListener('dragover', (e) => {
            e.preventDefault();
            this.dropZone.classList.add('dragover');
        });

        this.dropZone.addEventListener('dragleave', () => {
            this.dropZone.classList.remove('dragover');
        });

        this.dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            this.dropZone.classList.remove('dragover');
            const files = e.dataTransfer.files;
            if (files.length > 0) {
                this.handleFileSelect(files[0]);
            }
        });

        // Slider updates - update display on input, process on change (mouse release)
        this.nLayersSlider.addEventListener('input', (e) => {
            this.nLayersValue.textContent = e.target.value;
        });
        this.nLayersSlider.addEventListener('change', () => this.scheduleReprocess());

        this.compactnessSlider.addEventListener('input', (e) => {
            this.compactnessValue.textContent = e.target.value;
        });
        this.compactnessSlider.addEventListener('change', () => this.scheduleReprocess());

        this.nSegmentsSlider.addEventListener('input', (e) => {
            this.nSegmentsValue.textContent = e.target.value;
        });
        this.nSegmentsSlider.addEventListener('change', () => this.scheduleReprocess());

        this.maxRegionsSlider.addEventListener('input', (e) => {
            this.maxRegionsValue.textContent = e.target.value;
        });
        this.maxRegionsSlider.addEventListener('change', () => this.scheduleReprocess());

        // Select changes
        this.distanceThreshold.addEventListener('change', () => {
            // Show/hide max regions slider based on selection
            this.maxRegionsGroup.style.display =
                this.distanceThreshold.value === 'off' ? 'none' : 'block';
            this.scheduleReprocess();
        });
        this.edgeMode.addEventListener('change', () => this.scheduleReprocess());

        // Process button
        this.processBtn.addEventListener('click', () => this.processImage());

        // Export buttons
        this.exportBtn.addEventListener('click', () => this.exportLayers());
        this.previewBtn.addEventListener('click', () => this.generatePreview());

        // Update export examples when base name changes
        this.baseName.addEventListener('input', () => this.updateExportExamples());
    }

    handleFileSelect(file) {
        if (!file) return;

        const validTypes = ['image/png', 'image/jpeg', 'image/jpg'];
        if (!validTypes.includes(file.type)) {
            alert('Please upload a PNG or JPG image');
            return;
        }

        // Extract filename without extension for base name
        const fileName = file.name;
        const baseName = fileName.substring(0, fileName.lastIndexOf('.')) || fileName;
        this.baseName.value = baseName;
        this.updateExportExamples();

        const reader = new FileReader();
        reader.onload = (e) => {
            const img = new Image();
            img.onload = () => {
                this.currentImage = file;
                this.dropZone.classList.add('has-image');
                this.dropZone.innerHTML = `
                    <img src="${e.target.result}" style="max-width: 200px; max-height: 200px; border-radius: 8px;">
                    <p style="margin-top: 1rem;">Image loaded: ${file.name}</p>
                    <p class="small">Click to change</p>
                `;
                this.controls.style.display = 'block';
                this.processImage();
            };
            img.src = e.target.result;
        };
        reader.readAsDataURL(file);
    }

    scheduleReprocess() {
        // Debounce reprocessing for real-time updates
        clearTimeout(this.reprocessTimeout);
        this.reprocessTimeout = setTimeout(() => {
            if (this.currentImage) {
                this.processImage();
            }
        }, 500);
    }

    async processImage() {
        if (!this.currentImage) return;

        this.showLoading(true);

        const formData = new FormData();
        formData.append('image', this.currentImage);
        formData.append('n_layers', this.nLayersSlider.value);
        formData.append('compactness', this.compactnessSlider.value);
        formData.append('n_segments', this.nSegmentsSlider.value);
        formData.append('distance_threshold', this.distanceThreshold.value);
        formData.append('max_regions_per_color', this.maxRegionsSlider.value);
        formData.append('edge_mode', this.edgeMode.value);
        formData.append('visualize_steps', 'true');

        try {
            const response = await fetch('/process', {
                method: 'POST',
                body: formData
            });

            if (!response.ok) {
                const error = await response.json();
                throw new Error(error.error || 'Processing failed');
            }

            const data = await response.json();
            this.processedData = data;
            this.displayResults(data);
        } catch (error) {
            console.error('Error processing image:', error);
            alert('Error processing image: ' + error.message);
        } finally {
            this.showLoading(false);
        }
    }

    displayResults(data) {
        // Store visualizations for use in layers section
        this.currentVisualizations = data.visualizations;

        // Display visualizations
        if (data.visualizations) {
            this.displayVisualizations(data.visualizations);
        }

        // Display layers
        if (data.layers && data.visualizations) {
            this.displayLayers(data.layers, data.statistics, data.visualizations);
        }

        // Display statistics
        if (data.statistics) {
            this.displayStatistics(data.statistics);
        }

        this.visualizations.style.display = 'block';
        this.results.style.display = 'block';
    }

    displayVisualizations(visualizations) {
        this.vizGrid.innerHTML = '';

        const vizOrder = [
            'original',
            'superpixels',
            'superpixel_colors',
            'clustered',
            'reconstruction'
        ];

        const vizLabels = {
            'original': 'Original Image',
            'superpixels': 'Superpixel Boundaries',
            'superpixel_colors': 'Superpixel Average Colors',
            'clustered': 'K-means Color Clusters',
            'reconstruction': 'Reconstruction Preview'
        };

        // Display in specified order
        for (const key of vizOrder) {
            if (visualizations[key]) {
                const vizItem = document.createElement('div');
                vizItem.className = 'viz-item';
                vizItem.innerHTML = `
                    <img src="data:image/png;base64,${visualizations[key]}" alt="${key}">
                    <p>${vizLabels[key]}</p>
                `;
                this.vizGrid.appendChild(vizItem);
            }
        }
    }

    displayLayers(layers, statistics, visualizations) {
        this.layersGrid.innerHTML = '';
        this.currentLayers = layers;
        this.currentVisualizations = visualizations;
        this.currentStatistics = statistics;
        this.layerStatistics = statistics.layer_sizes || [];

        // Clear previous selections and select all by default
        this.selectedLayerIndices.clear();

        // Display the layers with checkboxes
        layers.forEach((layerData, index) => {
            const layerItem = document.createElement('div');
            layerItem.className = 'layer-item';
            layerItem.dataset.index = index;

            const stats = statistics.layer_sizes[index] || {};
            const color = stats.average_color_rgb || [0, 0, 0];

            // Select all layers by default
            this.selectedLayerIndices.add(index);

            layerItem.innerHTML = `
                <input type="checkbox" class="layer-checkbox" data-index="${index}" checked>
                <div class="layer-preview">
                    <img src="data:image/png;base64,${layerData}" alt="Layer ${index}">
                </div>
                <div class="layer-info">
                    <span class="layer-name">Layer ${index}</span>
                    <span class="layer-stats">${stats.percentage}% • ${this.formatNumber(stats.pixel_count)} px</span>
                    <div style="width: 20px; height: 20px; background: rgb(${color.join(',')}); border-radius: 4px; margin: 0.25rem auto; border: 1px solid #ddd;"></div>
                </div>
            `;

            layerItem.classList.add('selected');

            // Add click handler for checkbox
            const checkbox = layerItem.querySelector('.layer-checkbox');
            checkbox.addEventListener('change', (e) => this.handleLayerSelection(e, index));

            // Add click handler for the whole item (except checkbox)
            layerItem.addEventListener('click', (e) => {
                if (e.target.type !== 'checkbox') {
                    checkbox.checked = !checkbox.checked;
                    this.handleLayerSelection({ target: checkbox }, index);
                }
            });

            this.layersGrid.appendChild(layerItem);
        });

        // Update export preview with all layers selected
        this.updateExportPreview();
    }

    displayStatistics(statistics) {
        this.statistics.innerHTML = `
            <h3>Statistics</h3>
            <div class="stat-grid">
                <div class="stat-item">
                    <div class="stat-label">Total Layers</div>
                    <div class="stat-value">${statistics.n_layers}</div>
                </div>
                <div class="stat-item">
                    <div class="stat-label">Image Size</div>
                    <div class="stat-value">1024×1024</div>
                </div>
                <div class="stat-item">
                    <div class="stat-label">Total Pixels</div>
                    <div class="stat-value">${this.formatNumber(1024 * 1024)}</div>
                </div>
            </div>
        `;
    }

    async exportLayers() {
        if (!this.currentLayers || this.currentLayers.length === 0) {
            alert('No layers to export');
            return;
        }

        if (this.selectedLayerIndices.size === 0) {
            alert('Please select at least one layer to export');
            return;
        }

        this.showLoading(true);

        const exportMode = document.querySelector('input[name="export-mode"]:checked').value;
        const baseName = this.baseName.value || 'icon';

        // Get only selected layers
        const selectedLayers = [];
        const selectedStats = [];
        const sortedIndices = Array.from(this.selectedLayerIndices).sort((a, b) => a - b);
        sortedIndices.forEach(index => {
            if (this.currentLayers[index]) {
                selectedLayers.push(this.currentLayers[index]);
                // Get pixel count for this layer
                const stats = this.layerStatistics[index];
                selectedStats.push(stats ? stats.pixel_count : 0);
            }
        });

        try {
            let response;

            if (exportMode === 'icon-bundle') {
                // Use new Icon Composer export endpoint
                response = await fetch('/export-icon-bundle', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        layers: selectedLayers,
                        base_name: baseName,
                        layer_stats: selectedStats
                    })
                });
            } else {
                // Use existing export endpoint for folder/suffix modes
                response = await fetch('/export', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        layers: selectedLayers,
                        mode: exportMode,
                        base_name: baseName
                    })
                });
            }

            if (!response.ok) {
                throw new Error('Export failed');
            }

            // Download the zip file
            const blob = await response.blob();
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = exportMode === 'icon-bundle'
                ? `${baseName}.icon.zip`
                : `${baseName}_layers.zip`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            window.URL.revokeObjectURL(url);

        } catch (error) {
            console.error('Error exporting layers:', error);
            alert('Error exporting layers: ' + error.message);
        } finally {
            this.showLoading(false);
        }
    }

    generatePreview() {
        if (!this.processedData || !this.processedData.visualizations) {
            alert('No preview available');
            return;
        }

        const reconstruction = this.processedData.visualizations.reconstruction;
        if (reconstruction) {
            const win = window.open('', '_blank');
            win.document.write(`
                <html>
                <head>
                    <title>Layer Stack Preview</title>
                    <style>
                        body {
                            margin: 0;
                            padding: 20px;
                            background: #f0f0f0;
                            display: flex;
                            justify-content: center;
                            align-items: center;
                            min-height: 100vh;
                        }
                        img {
                            max-width: 90vw;
                            max-height: 90vh;
                            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
                            border-radius: 8px;
                        }
                    </style>
                </head>
                <body>
                    <img src="data:image/png;base64,${reconstruction}" alt="Reconstruction Preview">
                </body>
                </html>
            `);
        }
    }

    showLoading(show) {
        this.loading.style.display = show ? 'flex' : 'none';
    }

    formatNumber(num) {
        return num.toLocaleString();
    }

    updateExportExamples() {
        const baseName = this.baseName.value || 'icon';
        this.folderExample.textContent = `${baseName}/layer_0.png`;
        this.suffixExample.textContent = `${baseName}_0.png`;
        this.iconBundleExample.textContent = `${baseName}.icon`;
    }

    handleLayerSelection(event, index) {
        const checkbox = event.target;
        const layerItem = this.layersGrid.querySelector(`[data-index="${index}"]`);

        if (checkbox.checked) {
            this.selectedLayerIndices.add(index);
            layerItem.classList.add('selected');
        } else {
            this.selectedLayerIndices.delete(index);
            layerItem.classList.remove('selected');
        }

        // Update export preview
        this.updateExportPreview();
    }

    async updateExportPreview() {
        if (!this.currentLayers || !this.currentVisualizations) return;

        // Show selected layers in export section
        this.displaySelectedLayers();

        // Request new reconstruction with only selected layers
        await this.updateReconstruction();
    }

    displaySelectedLayers() {
        if (!this.selectedLayers) return;

        this.selectedLayers.innerHTML = '';

        if (this.selectedLayerIndices.size === 0) {
            this.selectedLayers.innerHTML = '<p style="color: #718096; text-align: center;">No layers selected for export</p>';
            return;
        }

        const selectedContainer = document.createElement('div');
        selectedContainer.className = 'selected-layers-grid';

        // Sort indices to maintain order
        const sortedIndices = Array.from(this.selectedLayerIndices).sort((a, b) => a - b);

        sortedIndices.forEach(index => {
            const layerData = this.currentLayers[index];
            const stats = this.currentStatistics.layer_sizes[index] || {};

            const item = document.createElement('div');
            item.className = 'selected-layer-item';
            item.innerHTML = `
                <img src="data:image/png;base64,${layerData}" alt="Layer ${index}">
                <p>Layer ${index}</p>
            `;
            selectedContainer.appendChild(item);
        });

        this.selectedLayers.appendChild(selectedContainer);
    }

    async updateReconstruction() {
        if (!this.exportPreview) return;

        this.exportPreview.innerHTML = '';

        // Create container for the preview flow
        const previewContainer = document.createElement('div');
        previewContainer.className = 'preview-flow';

        // Add original image
        if (this.currentVisualizations.original) {
            const originalItem = document.createElement('div');
            originalItem.className = 'preview-item';
            originalItem.innerHTML = `
                <img src="data:image/png;base64,${this.currentVisualizations.original}" alt="Original">
                <p>Original</p>
            `;
            previewContainer.appendChild(originalItem);
        }

        // Add arrow
        const arrow = document.createElement('div');
        arrow.className = 'preview-arrow';
        arrow.innerHTML = '→';
        previewContainer.appendChild(arrow);

        // Create reconstruction from selected layers
        if (this.selectedLayerIndices.size > 0) {
            // Request reconstruction from backend
            try {
                const response = await fetch('/reconstruct', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        layers: this.currentLayers,
                        selected: Array.from(this.selectedLayerIndices)
                    })
                });

                if (response.ok) {
                    const data = await response.json();
                    if (data.reconstruction) {
                        const reconstructionItem = document.createElement('div');
                        reconstructionItem.className = 'preview-item';
                        reconstructionItem.innerHTML = `
                            <img src="data:image/png;base64,${data.reconstruction}" alt="Reconstruction">
                            <p>Reconstruction (${this.selectedLayerIndices.size} layers)</p>
                        `;
                        previewContainer.appendChild(reconstructionItem);
                    }
                } else {
                    // Fallback to original reconstruction
                    const reconstructionItem = document.createElement('div');
                    reconstructionItem.className = 'preview-item';
                    reconstructionItem.innerHTML = `
                        <img src="data:image/png;base64,${this.currentVisualizations.reconstruction}" alt="Reconstruction">
                        <p>Reconstruction (${this.selectedLayerIndices.size} layers)</p>
                    `;
                    previewContainer.appendChild(reconstructionItem);
                }
            } catch (error) {
                console.error('Error getting reconstruction:', error);
            }
        } else {
            const emptyItem = document.createElement('div');
            emptyItem.className = 'preview-item';
            emptyItem.innerHTML = `
                <div style="width: 150px; height: 150px; background: #f0f0f0; border-radius: 8px; display: flex; align-items: center; justify-content: center; color: #718096;">
                    No layers
                </div>
                <p>No Reconstruction</p>
            `;
            previewContainer.appendChild(emptyItem);
        }

        this.exportPreview.appendChild(previewContainer);
    }
}

// Initialize the app
document.addEventListener('DOMContentLoaded', () => {
    new IconDecomposer();
});