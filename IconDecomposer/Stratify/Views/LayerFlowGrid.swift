//
//  LayerFlowGrid.swift
//  IconDecomposer
//
//  Flow layout for layer thumbnails
//

import SwiftUI

struct LayerFlowGrid: View {
    let layers: [Layer]
    let selectedLayerIDs: Set<UUID>
    let onToggle: (UUID) -> Void
    let onDrop: (Layer, Layer) -> Void

    let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(layers) { layer in
                LayerGridItem(
                    layer: layer,
                    isSelected: selectedLayerIDs.contains(layer.id),
                    onToggle: {
                        onToggle(layer.id)
                    },
                    onDrop: { droppedLayer in
                        onDrop(droppedLayer, layer)
                    }
                )
            }
        }
    }
}

struct LayerGridItem: View {
    let layer: Layer
    let isSelected: Bool
    let onToggle: () -> Void
    let onDrop: (Layer) -> Void

    @State private var isDragTarget = false

    var body: some View {
        VStack(spacing: 8) {
            // Layer thumbnail
            if let image = layer.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .background(CheckerboardBackground())
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isDragTarget ? Color.blue : (isSelected ? Color.blue : Color.clear),
                                lineWidth: isDragTarget ? 3 : (isSelected ? 2 : 0)
                            )
                    )
            }

            // Layer info
            VStack(spacing: 4) {
                HStack {
                    Button(action: onToggle) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundColor(isSelected ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)

                    Text(layer.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()
                }

                HStack {
                    Text("\(layer.pixelCount.formatted()) px")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDragTarget ? Color.blue.opacity(0.1) : (isSelected ? Color.blue.opacity(0.05) : Color(nsColor: .controlBackgroundColor)))
        )
        .onDrag {
            // Encode the layer for dragging
            let data = try? JSONEncoder().encode(layer)
            return NSItemProvider(item: data as? NSSecureCoding, typeIdentifier: "com.icondecomposer.layer")
        }
        .onDrop(of: ["com.icondecomposer.layer"], isTargeted: $isDragTarget) { providers in
            // Decode the dropped layer
            guard let provider = providers.first else { return false }

            _ = provider.loadDataRepresentation(forTypeIdentifier: "com.icondecomposer.layer") { data, error in
                guard let data = data,
                      let droppedLayer = try? JSONDecoder().decode(Layer.self, from: data),
                      droppedLayer.id != layer.id else { return }

                DispatchQueue.main.async {
                    onDrop(droppedLayer)
                }
            }

            return true
        }
    }
}
