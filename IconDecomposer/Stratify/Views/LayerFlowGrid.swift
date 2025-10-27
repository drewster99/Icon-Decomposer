//
//  LayerFlowGrid.swift
//  Stratify
//
//  Flow layout for layer thumbnails
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stratifyLayerUTType = UTType(exportedAs: "com.nuclearcyborg.Stratify.layer")
}

struct LayerFlowGrid: View {
    let layers: [Layer]
    let selectedLayerIDs: Set<UUID>
    let onToggle: (UUID) -> Void
    let onDrop: (Layer, Layer) -> Void

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let spacing: CGFloat = 12

            // Calculate optimal number of columns (3-5 based on width)
            let columnCount = max(3, min(5, Int(availableWidth / 200)))
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            let columnWidth = (availableWidth - totalSpacing) / CGFloat(columnCount)

            let columns = Array(repeating: GridItem(.fixed(columnWidth), spacing: spacing), count: columnCount)

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
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
                .padding(spacing)
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
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width)
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
                .aspectRatio(1, contentMode: .fit)
            }

            // Layer info
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .blue : .secondary)

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
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .onDrag {
            // Encode the layer for dragging
            print("🔵 Starting drag for layer: \(layer.name)")
            guard let data = try? JSONEncoder().encode(layer) else {
                print("❌ Failed to encode layer for dragging")
                return NSItemProvider()
            }
            print("✅ Encoded layer data: \(data.count) bytes")
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.stratifyLayerUTType.identifier, visibility: .all) { completion in
                print("📤 Providing data for drag")
                completion(data, nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [UTType.stratifyLayerUTType], isTargeted: $isDragTarget) { providers in
            print("🟢 Drop received on layer: \(layer.name)")
            print("   Providers count: \(providers.count)")

            // Decode the dropped layer
            guard let provider = providers.first else {
                print("❌ No provider found")
                return false
            }

            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.stratifyLayerUTType.identifier) { data, error in
                if let error = error {
                    print("❌ Error loading data: \(error)")
                    return
                }

                guard let data = data else {
                    print("❌ No data received")
                    return
                }

                print("📥 Received data: \(data.count) bytes")

                DispatchQueue.main.async {
                    guard let droppedLayer = try? JSONDecoder().decode(Layer.self, from: data) else {
                        print("❌ Failed to decode layer")
                        return
                    }

                    print("✅ Decoded layer: \(droppedLayer.name)")

                    guard droppedLayer.id != layer.id else {
                        print("⚠️ Dropped on self, ignoring")
                        return
                    }

                    print("🎯 Calling onDrop callback")
                    onDrop(droppedLayer)
                }
            }

            return true
        }
    }
}
