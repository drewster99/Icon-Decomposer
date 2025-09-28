class IconDecomposer {
    constructor() {
        this.currentImage = null;
        this.processedData = null;
        this.initElements();
        this.initEventListeners();

        // Initialize layer grouping
        this.layerGrouping = new LayerGrouping(this);

        // Set up preview ready handler for async updates
        this.onPreviewReady = (layerIndices, dataUrl, isSelected) => {
            // Find which group these layers belong to
            this.layerGrouping.groups.forEach((group, groupIdx) => {
                const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));
                const layersBeingShown = selectedInGroup.length > 0 ? selectedInGroup : group;

                // Check if this matches the layers we just rendered
                if (layersBeingShown.length === layerIndices.length &&
                    layersBeingShown.every(idx => layerIndices.includes(idx))) {

                    // Update the preview in the DOM
                    const groupElement = document.querySelector(`.layer-group[data-group-index="${groupIdx}"]`);
                    if (groupElement) {
                        const previewImg = groupElement.querySelector('.layer-preview img');
                        if (previewImg) {
                            previewImg.src = dataUrl;
                        }
                    }
                }
            });
        };
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
        this.selectedLayerIndices = new Set();  // Individual layer selection
        this.selectedGroupIndices = new Set();  // Group-level selection
        this.currentLayers = [];
        this.currentLayersFull = [];  // Full resolution layers for export
        this.layerStatistics = [];

        // Layer grouping state
        this.layerGroups = [];  // Array of arrays, each sub-array contains layer indices in that group
        this.expandedGroups = new Set();  // Track which groups are expanded
        this.draggedItem = null;
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

        // Close expanded groups when clicking on the parent section (not on layer items)
        const layersSection = this.layersGrid.parentElement;
        if (layersSection) {
            layersSection.addEventListener('click', (e) => {
                // If we clicked directly on the section or grid (not a child element)
                if (e.target === layersSection || e.target === this.layersGrid) {
                    if (this.layerGrouping && this.layerGrouping.expandedGroups.size > 0) {
                        this.layerGrouping.expandedGroups.clear();
                        this.renderLayerGroups();
                    }
                }
            });
        }
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

        // Store full resolution layers for export (if available)
        if (data.layers_full) {
            this.currentLayersFull = data.layers_full;
        }

        // Display visualizations
        if (data.visualizations) {
            this.displayVisualizations(data.visualizations);
        }

        // Display layers (using preview versions)
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

        // Initialize grouping (ensure layerGrouping exists first)
        if (!this.layerGrouping) {
            this.layerGrouping = new LayerGrouping(this);

            // Also set up the preview ready handler if not already done
            if (!this.onPreviewReady) {
                this.onPreviewReady = (layerIndices, dataUrl, isSelected) => {
                    // Find which group these layers belong to
                    this.layerGrouping.groups.forEach((group, groupIdx) => {
                        const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));
                        const layersBeingShown = selectedInGroup.length > 0 ? selectedInGroup : group;

                        // Check if this matches the layers we just rendered
                        if (layersBeingShown.length === layerIndices.length &&
                            layersBeingShown.every(idx => layerIndices.includes(idx))) {

                            // Update the preview in the DOM
                            const groupElement = document.querySelector(`.layer-group[data-group-index="${groupIdx}"]`);
                            if (groupElement) {
                                const previewImg = groupElement.querySelector('.layer-preview img');
                                if (previewImg) {
                                    previewImg.src = dataUrl;
                                }
                            }
                        }
                    });
                };
            }
        }
        this.layerGrouping.initializeGroups(layers.length);

        // Clear previous selections and select all by default
        this.selectedLayerIndices.clear();
        this.selectedGroupIndices.clear();
        layers.forEach((_, index) => this.selectedLayerIndices.add(index));

        // Mark all groups as selected initially
        this.layerGrouping.groups.forEach((_, groupIndex) => {
            this.selectedGroupIndices.add(groupIndex);
        });

        // Render layers with grouping support
        this.renderLayerGroups();

        // Update export preview with all layers selected
        this.updateExportPreview();
    }

    renderLayerGroups() {
        this.layersGrid.innerHTML = '';

        this.layerGrouping.groups.forEach((group, groupIndex) => {
            if (group.length === 0) return;

            // Always render as a group for consistency
            this.renderLayerGroup(group, groupIndex);
        });
    }

    renderSingleLayer(layerIndex, groupIndex) {
        const layerData = this.currentLayers[layerIndex];
        const stats = this.layerStatistics[layerIndex] || {};
        const color = stats.average_color_rgb || [0, 0, 0];
        const isSelected = this.selectedLayerIndices.has(layerIndex);

        const layerItem = document.createElement('div');
        layerItem.className = 'layer-item' + (isSelected ? ' selected' : '');
        layerItem.dataset.layerIndex = layerIndex;
        layerItem.dataset.groupIndex = groupIndex;

        layerItem.innerHTML = `
            <input type="checkbox" class="layer-checkbox" data-index="${layerIndex}" ${isSelected ? 'checked' : ''}>
            <div class="layer-preview">
                <img src="data:image/png;base64,${layerData}" alt="Layer ${layerIndex}">
            </div>
            <div class="layer-info">
                <span class="layer-name">Layer ${layerIndex}</span>
                <span class="layer-stats">${stats.percentage}% • ${this.formatNumber(stats.pixel_count)} px</span>
                <div style="width: 20px; height: 20px; background: rgb(${color.join(',')}); border-radius: 4px; margin: 0.25rem auto; border: 1px solid #ddd;"></div>
            </div>
        `;

        // Add event handlers
        const checkbox = layerItem.querySelector('.layer-checkbox');
        checkbox.addEventListener('change', (e) => this.handleLayerSelection(e, layerIndex));

        layerItem.addEventListener('click', (e) => {
            if (e.target.type !== 'checkbox') {
                checkbox.checked = !checkbox.checked;
                this.handleLayerSelection({ target: checkbox }, layerIndex);
            }
        });

        // Set up drag and drop
        this.layerGrouping.setupDragAndDrop(layerItem, 'layer', layerIndex);

        this.layersGrid.appendChild(layerItem);
    }

    renderLayerGroup(group, groupIndex) {
        const isExpanded = this.layerGrouping.expandedGroups.has(groupIndex);
        const groupItem = document.createElement('div');
        groupItem.className = 'layer-group' + (isExpanded ? ' expanded' : '');
        groupItem.dataset.groupIndex = groupIndex;

        // Calculate group stats from selected layers only
        let totalPixels = 0;
        let totalPercentage = 0;
        let avgColor = [0, 0, 0];
        let colorWeightSum = 0;

        group.forEach(idx => {
            // Only count selected layers for stats
            if (this.selectedLayerIndices.has(idx)) {
                const stats = this.layerStatistics[idx] || {};
                const pixelCount = stats.pixel_count || 0;
                totalPixels += pixelCount;
                totalPercentage += stats.percentage || 0;

                // Calculate weighted average color
                if (stats.average_color_rgb) {
                    avgColor[0] += stats.average_color_rgb[0] * pixelCount;
                    avgColor[1] += stats.average_color_rgb[1] * pixelCount;
                    avgColor[2] += stats.average_color_rgb[2] * pixelCount;
                    colorWeightSum += pixelCount;
                }
            }
        });

        // Normalize the weighted average color
        if (colorWeightSum > 0) {
            avgColor[0] = Math.round(avgColor[0] / colorWeightSum);
            avgColor[1] = Math.round(avgColor[1] / colorWeightSum);
            avgColor[2] = Math.round(avgColor[2] / colorWeightSum);
        }

        const isGroupSelected = this.selectedGroupIndices.has(groupIndex);
        const selectedLayersInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));
        const allLayersSelected = selectedLayersInGroup.length === group.length;
        const someLayersSelected = selectedLayersInGroup.length > 0;

        // Show selected layers only, empty if none selected
        let mergedPreview;
        if (selectedLayersInGroup.length === 0) {
            // Create empty dimmed preview
            const canvas = document.createElement('canvas');
            canvas.width = 256;
            canvas.height = 256;
            const ctx = canvas.getContext('2d');

            // Draw checkerboard
            ctx.fillStyle = '#f0f0f0';
            ctx.fillRect(0, 0, 256, 256);
            ctx.fillStyle = '#fafafa';
            for (let x = 0; x < 256; x += 20) {
                for (let y = 0; y < 256; y += 20) {
                    if ((x / 20 + y / 20) % 2 === 0) {
                        ctx.fillRect(x, y, 20, 20);
                    }
                }
            }

            // Add dimming
            ctx.globalAlpha = 0.3;
            ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
            ctx.fillRect(0, 0, 256, 256);

            mergedPreview = canvas.toDataURL('image/png');
        } else {
            mergedPreview = this.layerGrouping.createMergedPreview(
                selectedLayersInGroup,
                isGroupSelected && selectedLayersInGroup.length > 0  // Bright if group selected and has selected layers
            );
        }

        // Determine the group name
        const groupName = group.length === 1
            ? `Layer ${group[0]}`
            : `L ${group.join('+')}`;

        // Show color square for all groups (weighted average for multi-layer)
        const colorSquare = colorWeightSum > 0
            ? `<div class="color-square" style="background-color: rgb(${avgColor[0]}, ${avgColor[1]}, ${avgColor[2]})"></div>`
            : `<div class="color-square" style="visibility: hidden;"></div>`;

        groupItem.innerHTML = `
            <div class="layer-card">
                <div class="layer-preview-container">
                    <input type="checkbox" class="group-checkbox" data-group-index="${groupIndex}" ${isGroupSelected ? 'checked' : ''}>
                    <div class="layer-preview ${group.length > 1 ? 'stacked' : ''}">
                        <img src="${mergedPreview}" alt="${groupName}">
                    </div>
                </div>
                <div class="layer-info">
                    <div class="layer-name">${groupName}</div>
                    <div class="layer-stats">${totalPercentage.toFixed(2)}% • ${this.formatNumber(totalPixels)} px</div>
                    ${colorSquare}
                    ${group.length > 1 ? `<button class="expand-toggle">${isExpanded ? '▼' : '▶'}</button>` : ''}
                </div>
            </div>
        `;

        // Add event handlers
        const card = groupItem.querySelector('.layer-card');
        const expandBtn = groupItem.querySelector('.expand-toggle');
        const checkbox = groupItem.querySelector('.group-checkbox');

        if (expandBtn) {
            expandBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.layerGrouping.toggleGroupExpansion(groupIndex);
                this.renderLayerGroups();
            });
        }

        checkbox.addEventListener('change', (e) => {
            e.stopPropagation();

            // Update group selection state
            if (e.target.checked) {
                this.selectedGroupIndices.add(groupIndex);
            } else {
                this.selectedGroupIndices.delete(groupIndex);
            }

            // Use the same update function for consistency
            this.updateGroupPreview(groupIndex);
            this.updateExportPreview();
            // Update visual state of layers in expanded group if visible
            if (isExpanded) {
                this.renderLayerGroups();
            }
        });

        // Set up drag and drop for group
        this.layerGrouping.setupDragAndDrop(card, 'group', groupIndex);

        this.layersGrid.appendChild(groupItem);

        // Render individual layers if expanded
        if (isExpanded) {
            const contents = document.createElement('div');
            contents.className = 'group-contents';

            group.forEach(layerIndex => {
                const layerData = this.currentLayers[layerIndex];
                const stats = this.layerStatistics[layerIndex] || {};
                const color = stats.average_color_rgb || [0, 0, 0];
                const isSelected = this.selectedLayerIndices.has(layerIndex);

                const layerItem = document.createElement('div');
                layerItem.className = 'layer-item grouped' + (isSelected ? ' selected' : '');
                layerItem.dataset.layerIndex = layerIndex;
                layerItem.dataset.groupIndex = groupIndex;

                layerItem.innerHTML = `
                    <input type="checkbox" class="layer-checkbox" data-index="${layerIndex}" ${isSelected ? 'checked' : ''}>
                    <div class="layer-preview">
                        <img src="data:image/png;base64,${layerData}" alt="Layer ${layerIndex}">
                    </div>
                    <div class="layer-info">
                        <span class="layer-name">Layer ${layerIndex}</span>
                        <span class="layer-stats">${stats.percentage}% • ${this.formatNumber(stats.pixel_count)} px</span>
                        <div style="width: 20px; height: 20px; background: rgb(${color.join(',')}); border-radius: 4px; margin: 0.25rem auto; border: 1px solid #ddd;"></div>
                    </div>
                    <button class="remove-from-group-btn" title="Remove from group">↗</button>
                `;

                const checkbox = layerItem.querySelector('.layer-checkbox');
                const removeBtn = layerItem.querySelector('.remove-from-group-btn');

                // Hide remove button if this is the only layer in the group
                if (group.length <= 1) {
                    removeBtn.style.display = 'none';
                }

                checkbox.addEventListener('change', (e) => {
                    this.handleLayerSelection(e, layerIndex);
                });

                removeBtn.addEventListener('click', (e) => {
                    e.stopPropagation();

                    // Don't allow removing if it's the last layer in the group
                    if (group.length <= 1) {
                        return;
                    }

                    // Remove this layer from the group and create its own group
                    const newGroups = [];
                    const wasExpanded = this.layerGrouping.expandedGroups.has(groupIndex);

                    // Track which new indices correspond to expanded groups
                    const newExpandedIndices = new Set();
                    let currentNewIndex = 0;

                    this.layerGrouping.groups.forEach((g, idx) => {
                        if (idx === groupIndex) {
                            // Split this group
                            const remaining = g.filter(i => i !== layerIndex);
                            if (remaining.length > 0) {
                                newGroups.push(remaining);
                                // If only 1 item left, collapse the group
                                if (remaining.length > 1 && wasExpanded) {
                                    newExpandedIndices.add(currentNewIndex);
                                }
                                currentNewIndex++;
                            }
                            // Add the removed layer as its own group
                            newGroups.push([layerIndex]);
                            currentNewIndex++;
                        } else {
                            newGroups.push(g);
                            // Preserve expanded state for other groups
                            if (this.layerGrouping.expandedGroups.has(idx)) {
                                newExpandedIndices.add(currentNewIndex);
                            }
                            currentNewIndex++;
                        }
                    });

                    this.layerGrouping.groups = newGroups;
                    this.layerGrouping.expandedGroups = newExpandedIndices;
                    this.renderLayerGroups();
                });

                layerItem.addEventListener('click', (e) => {
                    if (e.target.type !== 'checkbox' && !e.target.classList.contains('remove-from-group-btn')) {
                        checkbox.checked = !checkbox.checked;
                        this.handleLayerSelection({ target: checkbox }, layerIndex);
                    }
                });

                this.layerGrouping.setupDragAndDrop(layerItem, 'layer', layerIndex);
                contents.appendChild(layerItem);
            });

            groupItem.appendChild(contents);
        }
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

        // Get selected layers organized by groups
        const exportLayers = [];
        const exportStats = [];

        // Process each group - only export if group is checked
        this.layerGrouping.groups.forEach((group, groupIdx) => {
            // Skip unchecked groups
            if (!this.selectedGroupIndices.has(groupIdx)) return;

            // Get checked layers within this checked group
            const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));

            if (selectedInGroup.length === 0) return;

            // Export the selected layers (use full resolution if available)
            selectedInGroup.forEach(idx => {
                // Use full resolution layers for export if available, otherwise fall back to preview
                const layerToExport = this.currentLayersFull.length > 0
                    ? this.currentLayersFull[idx]
                    : this.currentLayers[idx];
                exportLayers.push(layerToExport);
                const stats = this.layerStatistics[idx];
                exportStats.push(stats ? stats.pixel_count : 0);
            });
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
                        layers: exportLayers,
                        base_name: baseName,
                        layer_stats: exportStats
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
                        layers: exportLayers,
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

        if (checkbox.checked) {
            this.selectedLayerIndices.add(index);
        } else {
            this.selectedLayerIndices.delete(index);
        }

        // Find which group this layer belongs to
        let targetGroupIndex = -1;
        this.layerGrouping.groups.forEach((group, groupIdx) => {
            if (group.includes(index)) {
                targetGroupIndex = groupIdx;
            }
        });

        if (targetGroupIndex >= 0) {
            this.updateGroupPreview(targetGroupIndex);

            // Update visual state of the individual layer item
            const layerItem = document.querySelector(`.layer-item[data-layer-index="${index}"]`);
            if (layerItem) {
                if (checkbox.checked) {
                    layerItem.classList.add('selected');
                } else {
                    layerItem.classList.remove('selected');
                }
            }
        }

        // Update export preview
        this.updateExportPreview();
    }

    updateGroupPreview(groupIndex) {
        const groupElement = document.querySelector(`.layer-group[data-group-index="${groupIndex}"]`);
        if (!groupElement) return;

        const group = this.layerGrouping.groups[groupIndex];
        const isGroupSelected = this.selectedGroupIndices.has(groupIndex);
        const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));

        // Calculate what to show in preview - show nothing if no layers selected
        const isBright = isGroupSelected && selectedInGroup.length > 0;

        // Update the preview image synchronously first
        const previewImg = groupElement.querySelector('.layer-preview img');
        if (previewImg) {
            if (selectedInGroup.length === 0) {
                // Show empty preview (just checkerboard) when no layers selected
                const canvas = document.createElement('canvas');
                canvas.width = 256;
                canvas.height = 256;
                const ctx = canvas.getContext('2d');

                // Draw checkerboard
                ctx.fillStyle = '#f0f0f0';
                ctx.fillRect(0, 0, 256, 256);
                ctx.fillStyle = '#fafafa';
                for (let x = 0; x < 256; x += 20) {
                    for (let y = 0; y < 256; y += 20) {
                        if ((x / 20 + y / 20) % 2 === 0) {
                            ctx.fillRect(x, y, 20, 20);
                        }
                    }
                }

                // Add dimming since nothing is selected
                ctx.globalAlpha = 0.3;
                ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
                ctx.fillRect(0, 0, 256, 256);

                previewImg.src = canvas.toDataURL('image/png');
            } else {
                // Show selected layers
                const immediatePreview = this.layerGrouping.createMergedPreview(selectedInGroup, isBright);
                previewImg.src = immediatePreview;
            }
        }

        // Update stats
        let totalPixels = 0;
        let totalPercentage = 0;
        let avgColor = [0, 0, 0];
        let colorWeightSum = 0;

        group.forEach(idx => {
            if (this.selectedLayerIndices.has(idx)) {
                const stats = this.layerStatistics[idx] || {};
                const pixelCount = stats.pixel_count || 0;
                totalPixels += pixelCount;
                totalPercentage += stats.percentage || 0;

                if (stats.average_color_rgb) {
                    avgColor[0] += stats.average_color_rgb[0] * pixelCount;
                    avgColor[1] += stats.average_color_rgb[1] * pixelCount;
                    avgColor[2] += stats.average_color_rgb[2] * pixelCount;
                    colorWeightSum += pixelCount;
                }
            }
        });

        if (colorWeightSum > 0) {
            avgColor[0] = Math.round(avgColor[0] / colorWeightSum);
            avgColor[1] = Math.round(avgColor[1] / colorWeightSum);
            avgColor[2] = Math.round(avgColor[2] / colorWeightSum);
        }

        // Update stats display
        const statsElement = groupElement.querySelector('.layer-stats');
        if (statsElement) {
            statsElement.textContent = `${totalPercentage.toFixed(2)}% • ${this.formatNumber(totalPixels)} px`;
        }

        // Update color square
        const colorSquare = groupElement.querySelector('.color-square');
        if (colorSquare) {
            if (colorWeightSum > 0) {
                colorSquare.style.backgroundColor = `rgb(${avgColor[0]}, ${avgColor[1]}, ${avgColor[2]})`;
                colorSquare.style.visibility = 'visible';
            } else {
                colorSquare.style.visibility = 'hidden';
            }
        }
    }

    async updateExportPreview() {
        if (!this.currentLayers || !this.currentVisualizations) return;

        // Show selected layers in export section
        this.displaySelectedLayers();

        // Request new reconstruction with only selected layers
        await this.updateReconstruction();
    }

    // Generate merged preview for export section
    generateExportPreview(layerIndices, imgId) {
        if (!layerIndices || layerIndices.length === 0) return;

        const canvas = document.createElement('canvas');
        canvas.width = 256;
        canvas.height = 256;
        const ctx = canvas.getContext('2d');

        // Draw checkerboard
        ctx.fillStyle = '#f0f0f0';
        ctx.fillRect(0, 0, 256, 256);
        ctx.fillStyle = '#fafafa';
        for (let x = 0; x < 256; x += 20) {
            for (let y = 0; y < 256; y += 20) {
                if ((x / 20 + y / 20) % 2 === 0) {
                    ctx.fillRect(x, y, 20, 20);
                }
            }
        }

        // Load and composite all layers
        const loadPromises = layerIndices.map(idx => {
            return new Promise((resolve) => {
                if (this.currentLayers[idx]) {
                    const img = new Image();
                    img.onload = () => resolve(img);
                    img.onerror = () => resolve(null);
                    img.src = 'data:image/png;base64,' + this.currentLayers[idx];
                } else {
                    resolve(null);
                }
            });
        });

        Promise.all(loadPromises).then(images => {
            // Clear and redraw with layers
            ctx.clearRect(0, 0, 256, 256);

            // Redraw checkerboard
            ctx.fillStyle = '#f0f0f0';
            ctx.fillRect(0, 0, 256, 256);
            ctx.fillStyle = '#fafafa';
            for (let x = 0; x < 256; x += 20) {
                for (let y = 0; y < 256; y += 20) {
                    if ((x / 20 + y / 20) % 2 === 0) {
                        ctx.fillRect(x, y, 20, 20);
                    }
                }
            }

            // Draw each layer
            images.forEach(img => {
                if (img) {
                    ctx.drawImage(img, 0, 0, 256, 256);
                }
            });

            // Update the specific image element
            const imgElement = document.getElementById(imgId);
            if (imgElement) {
                imgElement.src = canvas.toDataURL('image/png');
            }
        });
    }

    displaySelectedLayers() {
        if (!this.selectedLayers) return;

        this.selectedLayers.innerHTML = '';

        // Check if any groups are selected
        const hasSelection = this.selectedGroupIndices.size > 0 && this.selectedLayerIndices.size > 0;

        if (!hasSelection) {
            this.selectedLayers.innerHTML = '<p style="color: #718096; text-align: center;">No layers selected for export</p>';
            return;
        }

        const selectedContainer = document.createElement('div');
        selectedContainer.className = 'selected-layers-grid';

        // Display only checked groups with their checked layers
        this.layerGrouping.groups.forEach((group, groupIdx) => {
            // Skip unchecked groups
            if (!this.selectedGroupIndices.has(groupIdx)) return;

            const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));
            if (selectedInGroup.length === 0) return;

            const item = document.createElement('div');
            item.className = 'selected-layer-item';

            // Determine the name
            const groupName = selectedInGroup.length === 1
                ? `Layer ${selectedInGroup[0]}`
                : `L ${selectedInGroup.join('+')}`;

            // Create preview with the selected layers
            if (selectedInGroup.length === 1 && this.currentLayers[selectedInGroup[0]]) {
                // For single layer, use the layer data directly
                const previewSrc = 'data:image/png;base64,' + this.currentLayers[selectedInGroup[0]];
                item.innerHTML = `
                    <img src="${previewSrc}" alt="${groupName}">
                    <p>${groupName}</p>
                `;
            } else {
                // For groups, create a placeholder and update it async
                const imgId = `export-preview-${groupIdx}-${Date.now()}`;

                // Create initial checkerboard preview
                const tempCanvas = document.createElement('canvas');
                tempCanvas.width = 256;
                tempCanvas.height = 256;
                const tempCtx = tempCanvas.getContext('2d');
                tempCtx.fillStyle = '#f0f0f0';
                tempCtx.fillRect(0, 0, 256, 256);
                tempCtx.fillStyle = '#fafafa';
                for (let x = 0; x < 256; x += 20) {
                    for (let y = 0; y < 256; y += 20) {
                        if ((x / 20 + y / 20) % 2 === 0) {
                            tempCtx.fillRect(x, y, 20, 20);
                        }
                    }
                }

                item.innerHTML = `
                    <img id="${imgId}" src="${tempCanvas.toDataURL('image/png')}" alt="${groupName}">
                    <p>${groupName}</p>
                `;

                // Generate the merged preview and update when ready
                this.generateExportPreview(selectedInGroup, imgId);
            }

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

        // Create reconstruction from selected layers (only from checked groups)
        const layersToReconstruct = [];
        this.layerGrouping.groups.forEach((group, groupIdx) => {
            if (this.selectedGroupIndices.has(groupIdx)) {
                const selectedInGroup = group.filter(idx => this.selectedLayerIndices.has(idx));
                layersToReconstruct.push(...selectedInGroup);
            }
        });

        if (layersToReconstruct.length > 0) {
            // Request reconstruction from backend
            try {
                const response = await fetch('/reconstruct', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({
                        layers: this.currentLayers,
                        selected: layersToReconstruct
                    })
                });

                if (response.ok) {
                    const data = await response.json();
                    if (data.reconstruction) {
                        const reconstructionItem = document.createElement('div');
                        reconstructionItem.className = 'preview-item';
                        reconstructionItem.innerHTML = `
                            <img src="data:image/png;base64,${data.reconstruction}" alt="Result">
                            <p>Result</p>
                        `;
                        previewContainer.appendChild(reconstructionItem);
                    }
                } else {
                    // Fallback to original reconstruction
                    const reconstructionItem = document.createElement('div');
                    reconstructionItem.className = 'preview-item';
                    reconstructionItem.innerHTML = `
                        <img src="data:image/png;base64,${this.currentVisualizations.reconstruction}" alt="Result">
                        <p>Result</p>
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