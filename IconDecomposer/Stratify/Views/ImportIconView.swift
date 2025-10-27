//
//  ImportIconView.swift
//  IconDecomposer
//
//  View for importing an icon with drag & drop support
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportIconView: View {
    let onImport: (NSImage) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Drop zone
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 80))
                    .foregroundStyle(isTargeted ? .blue : .secondary)

                Text("Drop an Icon Here")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("or")
                    .foregroundColor(.secondary)

                Button("Choose Icon File") {
                    chooseFile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Supports PNG, JPEG, HEIC, TIFF, and more • 1024×1024 recommended")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 600)
            .padding(60)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isTargeted ? Color.blue : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
                    )
            )
            .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            Spacer()
        }
        .padding()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.message = "Select an icon image"
        panel.prompt = "Import"

        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                onImport(image)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Try to load image from dropped item
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                    if let data = item as? Data, let image = NSImage(data: data) {
                        DispatchQueue.main.async {
                            onImport(image)
                        }
                    } else if let url = item as? URL, let image = NSImage(contentsOf: url) {
                        DispatchQueue.main.async {
                            onImport(image)
                        }
                    }
                }
                return true
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       let image = NSImage(contentsOf: url) {
                        DispatchQueue.main.async {
                            onImport(image)
                        }
                    }
                }
                return true
            }
        }

        return false
    }
}

#Preview {
    ImportIconView { image in
        print("Imported: \(image.size)")
    }
}
