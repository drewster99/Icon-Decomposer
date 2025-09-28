// Layer grouping functionality extension for IconDecomposer

class LayerGrouping {
    constructor(decomposer) {
        this.decomposer = decomposer;
        this.groups = [];  // Array of groups, each group is array of layer indices
        this.expandedGroups = new Set();
        this.draggedElement = null;
        this.draggedType = null;  // 'layer' or 'group'
        this.draggedIndex = null;
    }

    initializeGroups(layerCount) {
        // Each layer starts in its own group
        this.groups = Array.from({length: layerCount}, (_, i) => [i]);
        this.expandedGroups.clear();
    }

    // Create merged preview for a group of layers
    createMergedPreview(layerIndices, isSelected = false) {
        // Return empty preview if no indices
        if (!layerIndices || layerIndices.length === 0) {
            return this.createEmptyPreview();
        }

        const canvas = document.createElement('canvas');
        canvas.width = 256;
        canvas.height = 256;
        const ctx = canvas.getContext('2d');

        // Draw checkerboard background for transparency
        this.drawCheckerboard(ctx, 256, 256);

        // Check if we have layer data
        if (!this.decomposer.currentLayers || this.decomposer.currentLayers.length === 0) {
            return canvas.toDataURL('image/png');
        }

        // Create a unique ID for this preview request to track it
        const previewId = layerIndices.join(',');

        // Schedule the async compositing
        this.compositeLayersAsync(layerIndices, canvas, ctx, isSelected, previewId);

        // Return the current canvas state (checkerboard for now)
        return canvas.toDataURL('image/png');
    }

    // New simpler async compositing function
    compositeLayersAsync(layerIndices, canvas, ctx, isSelected, previewId) {
        const validLayers = [];

        // Collect valid layer data
        layerIndices.forEach(idx => {
            if (this.decomposer.currentLayers && this.decomposer.currentLayers[idx]) {
                validLayers.push({
                    idx: idx,
                    data: this.decomposer.currentLayers[idx]
                });
            }
        });

        if (validLayers.length === 0) return;

        // Load all images
        const loadPromises = validLayers.map(({ idx, data }) => {
            return new Promise((resolve) => {
                const img = new Image();
                img.onload = () => resolve(img);
                img.onerror = () => resolve(null); // Don't fail, just skip
                img.src = 'data:image/png;base64,' + data;
            });
        });

        Promise.all(loadPromises).then(images => {
            // Clear and redraw
            ctx.clearRect(0, 0, 256, 256);
            this.drawCheckerboard(ctx, 256, 256);

            // Draw each layer that loaded successfully
            images.forEach(img => {
                if (img) {
                    ctx.drawImage(img, 0, 0, 256, 256);
                }
            });

            // Add dimming if not selected
            if (!isSelected && images.some(img => img !== null)) {
                ctx.globalAlpha = 0.3;
                ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
                ctx.fillRect(0, 0, 256, 256);
                ctx.globalAlpha = 1.0;
            }

            // Store the final preview for later updates
            const updatedDataUrl = canvas.toDataURL('image/png');

            // Trigger an update event if the decomposer has a preview update handler
            if (this.decomposer.onPreviewReady) {
                this.decomposer.onPreviewReady(layerIndices, updatedDataUrl, isSelected);
            }
        });
    }

    // Helper to draw checkerboard pattern
    drawCheckerboard(ctx, width, height) {
        ctx.fillStyle = '#f0f0f0';
        ctx.fillRect(0, 0, width, height);
        ctx.fillStyle = '#fafafa';
        for (let x = 0; x < width; x += 20) {
            for (let y = 0; y < height; y += 20) {
                if ((x / 20 + y / 20) % 2 === 0) {
                    ctx.fillRect(x, y, 20, 20);
                }
            }
        }
    }

    // Create an empty preview with just checkerboard
    createEmptyPreview() {
        const canvas = document.createElement('canvas');
        canvas.width = 256;
        canvas.height = 256;
        const ctx = canvas.getContext('2d');
        this.drawCheckerboard(ctx, 256, 256);
        return canvas.toDataURL('image/png');
    }



    // Group multiple layers together
    groupLayers(indices) {
        // Remove layers from their current groups
        const layersToGroup = [];
        this.groups = this.groups.map(group => {
            const remaining = group.filter(idx => !indices.includes(idx));
            const toMove = group.filter(idx => indices.includes(idx));
            layersToGroup.push(...toMove);
            return remaining;
        }).filter(group => group.length > 0);

        // Add new group
        if (layersToGroup.length > 0) {
            this.groups.push(layersToGroup);
        }
    }

    // Ungroup a group back to individual layers
    ungroupAt(groupIndex) {
        if (groupIndex >= 0 && groupIndex < this.groups.length) {
            const group = this.groups[groupIndex];
            if (group.length > 1) {
                // Remove the group and add individual layer groups
                this.groups.splice(groupIndex, 1, ...group.map(idx => [idx]));
                this.expandedGroups.delete(groupIndex);
            }
        }
    }

    // Move a layer from one group to another
    moveLayerToGroup(layerIndex, targetGroupIndex) {
        // Find and remove layer from current group
        let sourceGroupIndex = -1;
        this.groups = this.groups.map((group, idx) => {
            if (group.includes(layerIndex)) {
                sourceGroupIndex = idx;
                return group.filter(i => i !== layerIndex);
            }
            return group;
        }).filter(group => group.length > 0);

        // Add to target group
        if (targetGroupIndex >= 0 && targetGroupIndex < this.groups.length) {
            this.groups[targetGroupIndex].push(layerIndex);
            // Sort layers in group numerically
            this.groups[targetGroupIndex].sort((a, b) => a - b);
        } else {
            // Create new group if target doesn't exist
            this.groups.push([layerIndex]);
        }
    }

    // Merge two groups
    mergeGroups(sourceGroupIndex, targetGroupIndex) {
        if (sourceGroupIndex !== targetGroupIndex &&
            sourceGroupIndex >= 0 && targetGroupIndex >= 0 &&
            sourceGroupIndex < this.groups.length && targetGroupIndex < this.groups.length) {

            const sourceGroup = this.groups[sourceGroupIndex];
            this.groups[targetGroupIndex].push(...sourceGroup);
            // Sort merged group numerically
            this.groups[targetGroupIndex].sort((a, b) => a - b);
            this.groups.splice(sourceGroupIndex, 1);

            // Update expanded groups set
            const newExpandedGroups = new Set();
            this.expandedGroups.forEach(idx => {
                if (idx === sourceGroupIndex) return;
                if (idx > sourceGroupIndex) {
                    newExpandedGroups.add(idx - 1);
                } else {
                    newExpandedGroups.add(idx);
                }
            });
            this.expandedGroups = newExpandedGroups;
        }
    }

    // Toggle group expansion
    toggleGroupExpansion(groupIndex) {
        if (this.expandedGroups.has(groupIndex)) {
            this.expandedGroups.delete(groupIndex);
        } else {
            this.expandedGroups.add(groupIndex);
        }
    }

    // Get flattened layer data for export
    getFlattenedGroups() {
        return this.groups.map(group => {
            if (group.length === 1) {
                return {
                    type: 'single',
                    index: group[0],
                    data: this.decomposer.currentLayers[group[0]]
                };
            } else {
                // Merge layers in group
                return {
                    type: 'group',
                    indices: group,
                    data: this.mergeLayers(group)
                };
            }
        });
    }

    // Merge multiple layers into one
    mergeLayers(layerIndices) {
        // This would need to be implemented on the backend
        // For now, return the first layer as placeholder
        return this.decomposer.currentLayers[layerIndices[0]];
    }

    // Set up drag and drop handlers
    setupDragAndDrop(element, type, index) {
        element.draggable = true;

        element.addEventListener('dragstart', (e) => {
            this.draggedElement = element;
            this.draggedType = type;
            this.draggedIndex = index;
            element.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/html', element.innerHTML);
        });

        element.addEventListener('dragend', (e) => {
            element.classList.remove('dragging');
            document.querySelectorAll('.drag-over').forEach(el => {
                el.classList.remove('drag-over');
            });
            this.draggedElement = null;
            this.draggedType = null;
            this.draggedIndex = null;
        });

        element.addEventListener('dragover', (e) => {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            element.classList.add('drag-over');
        });

        element.addEventListener('dragleave', (e) => {
            element.classList.remove('drag-over');
        });

        element.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            element.classList.remove('drag-over');

            if (this.draggedElement && this.draggedElement !== element) {
                this.handleDrop(type, index);
            }
        });
    }

    handleDrop(targetType, targetIndex) {
        let needsUpdate = false;

        if (this.draggedType === 'layer' && targetType === 'layer') {
            // Dragging layer onto layer - merge into group
            const draggedLayerIndex = this.draggedIndex;
            const targetLayerIndex = targetIndex;

            // Find which groups they belong to
            let draggedGroupIndex = -1;
            let targetGroupIndex = -1;

            this.groups.forEach((group, idx) => {
                if (group.includes(draggedLayerIndex)) draggedGroupIndex = idx;
                if (group.includes(targetLayerIndex)) targetGroupIndex = idx;
            });

            if (draggedGroupIndex !== targetGroupIndex) {
                this.moveLayerToGroup(draggedLayerIndex, targetGroupIndex);
                // Auto-enable the dragged layer and its target group
                this.decomposer.selectedLayerIndices.add(draggedLayerIndex);

                // Find the new group index for the target
                this.groups.forEach((group, idx) => {
                    if (group.includes(targetLayerIndex)) {
                        this.decomposer.selectedGroupIndices.add(idx);
                    }
                });
                needsUpdate = true;
            }
        } else if (this.draggedType === 'group' && targetType === 'group') {
            // Dragging group onto group - merge groups
            this.mergeGroups(this.draggedIndex, targetIndex);
            needsUpdate = true;
        } else if (this.draggedType === 'layer' && targetType === 'group') {
            // Dragging layer onto group
            this.moveLayerToGroup(this.draggedIndex, targetIndex);
            // Auto-enable the dragged layer
            this.decomposer.selectedLayerIndices.add(this.draggedIndex);
            needsUpdate = true;
        }

        // Update affected groups without full re-render
        if (needsUpdate) {
            // Get unique set of affected group indices
            const affectedGroups = new Set();

            // Find groups affected by the drag operation
            if (this.draggedType === 'layer') {
                this.groups.forEach((group, idx) => {
                    if (group.includes(this.draggedIndex) || group.includes(targetIndex)) {
                        affectedGroups.add(idx);
                    }
                });
            } else if (this.draggedType === 'group' && targetType === 'group') {
                // Both source and target groups are affected
                affectedGroups.add(targetIndex);
                // Find the new index of the merged group
                this.groups.forEach((group, idx) => {
                    if (group.includes(this.draggedIndex)) {
                        affectedGroups.add(idx);
                    }
                });
            }

            // Re-render to update DOM structure
            this.decomposer.renderLayerGroups();

            // Update previews for affected groups after DOM is ready
            setTimeout(() => {
                affectedGroups.forEach(groupIdx => {
                    if (groupIdx < this.groups.length) {
                        this.decomposer.updateGroupPreview(groupIdx);
                    }
                });
                this.decomposer.updateExportPreview();
            }, 50);
        }
    }
}

// Export for use in main app
if (typeof module !== 'undefined' && module.exports) {
    module.exports = LayerGrouping;
}