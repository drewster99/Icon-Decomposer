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
        this.exportBtn = document.getElementById('export-btn');
        this.previewBtn = document.getElementById('preview-btn');

        // Loading overlay
        this.loading = document.getElementById('loading');
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

        // Slider updates
        this.nLayersSlider.addEventListener('input', (e) => {
            this.nLayersValue.textContent = e.target.value;
            this.scheduleReprocess();
        });

        this.compactnessSlider.addEventListener('input', (e) => {
            this.compactnessValue.textContent = e.target.value;
            this.scheduleReprocess();
        });

        this.nSegmentsSlider.addEventListener('input', (e) => {
            this.nSegmentsValue.textContent = e.target.value;
            this.scheduleReprocess();
        });

        this.maxRegionsSlider.addEventListener('input', (e) => {
            this.maxRegionsValue.textContent = e.target.value;
            this.scheduleReprocess();
        });

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
    }

    handleFileSelect(file) {
        if (!file) return;

        const validTypes = ['image/png', 'image/jpeg', 'image/jpg'];
        if (!validTypes.includes(file.type)) {
            alert('Please upload a PNG or JPG image');
            return;
        }

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
        // Display visualizations
        if (data.visualizations) {
            this.displayVisualizations(data.visualizations);
        }

        // Display layers
        if (data.layers) {
            this.displayLayers(data.layers, data.statistics);
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

        const vizLabels = {
            'original': 'Original Image',
            'superpixels': 'Superpixel Boundaries',
            'superpixel_colors': 'Superpixel Average Colors',
            'clustered': 'Clustered Colors',
            'reconstruction': 'Reconstruction Preview'
        };

        for (const [key, imageData] of Object.entries(visualizations)) {
            const vizItem = document.createElement('div');
            vizItem.className = 'viz-item';
            vizItem.innerHTML = `
                <img src="data:image/png;base64,${imageData}" alt="${key}">
                <p>${vizLabels[key] || key}</p>
            `;
            this.vizGrid.appendChild(vizItem);
        }
    }

    displayLayers(layers, statistics) {
        this.layersGrid.innerHTML = '';

        layers.forEach((layerData, index) => {
            const layerItem = document.createElement('div');
            layerItem.className = 'layer-item';

            const stats = statistics.layer_sizes[index] || {};
            const color = stats.average_color_rgb || [0, 0, 0];

            layerItem.innerHTML = `
                <div class="layer-preview">
                    <img src="data:image/png;base64,${layerData}" alt="Layer ${index}">
                </div>
                <div class="layer-info">
                    <span class="layer-name">Layer ${index}</span>
                    <span class="layer-stats">${stats.percentage}% • ${this.formatNumber(stats.pixel_count)} px</span>
                    <div style="width: 20px; height: 20px; background: rgb(${color.join(',')}); border-radius: 4px; margin: 0.25rem auto; border: 1px solid #ddd;"></div>
                </div>
            `;

            this.layersGrid.appendChild(layerItem);
        });
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
        if (!this.processedData || !this.processedData.layers) {
            alert('No layers to export');
            return;
        }

        this.showLoading(true);

        const exportMode = document.querySelector('input[name="export-mode"]:checked').value;
        const baseName = this.baseName.value || 'icon';

        try {
            const response = await fetch('/export', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    layers: this.processedData.layers,
                    mode: exportMode,
                    base_name: baseName
                })
            });

            if (!response.ok) {
                throw new Error('Export failed');
            }

            // Download the zip file
            const blob = await response.blob();
            const url = window.URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `${baseName}_layers.zip`;
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
}

// Initialize the app
document.addEventListener('DOMContentLoaded', () => {
    new IconDecomposer();
});