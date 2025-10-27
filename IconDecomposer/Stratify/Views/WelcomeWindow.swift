//
//  WelcomeWindow.swift
//  IconDecomposer
//
//  Welcome screen shown on app launch
//

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeWindow: View {
    @State private var isTargeted = false
    @State private var recentDocuments: [URL] = []

    var body: some View {
        HSplitView {
            // Left: New Project
            VStack(spacing: 20) {
                Text("New Project")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.top, 40)

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

                    Text("Supports PNG, JPEG, HEIC, TIFF, and more\n1024×1024 recommended")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 500)
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
                .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted, perform: handleDrop(providers:))

                Spacer()
            }
            .frame(minWidth: 400)
            .padding()

            // Right: Open Existing & Recents
            VStack(alignment: .leading, spacing: 20) {
                Text("Open Existing")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.top, 40)

                Button(action: openExistingDocument) {
                    HStack {
                        Image(systemName: "folder")
                        Text("Open Project...")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Divider()
                    .padding(.vertical, 10)

                Text("Recent Projects")
                    .font(.headline)

                if recentDocuments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No recent projects")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(recentDocuments, id: \.self) { url in
                                Button(action: {
                                    openDocument(at: url)
                                }, label: {
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundColor(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.deletingPathExtension().lastPathComponent)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                            Text(url.path)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                })
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer()
            }
            .frame(minWidth: 300)
            .padding()
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear(perform: loadRecentDocuments)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.message = "Select an icon image"
        panel.prompt = "Import"

        if panel.runModal() == .OK, let url = panel.url {
            if let image = NSImage(contentsOf: url) {
                createDocumentWithImage(image)
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
                            self.createDocumentWithImage(image)
                        }
                    } else if let url = item as? URL, let image = NSImage(contentsOf: url) {
                        DispatchQueue.main.async {
                            self.createDocumentWithImage(image)
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
                            self.createDocumentWithImage(image)
                        }
                    }
                }
                return true
            }
        }

        return false
    }

    private func createDocumentWithImage(_ image: NSImage) {
        closeWelcomeWindow()

        // Store the image temporarily
        WelcomeWindow.pendingImage = image

        // Create a new document - it will pick up the pending image
        NSDocumentController.shared.newDocument(nil)
    }

    // Temporary storage for image dropped on welcome screen
    static var pendingImage: NSImage?

    private func openExistingDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.iconDecomposerProject]
        panel.allowsMultipleSelection = false
        panel.message = "Select a Stratify project to open"
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }

    private func openDocument(at url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, alreadyOpen, error in
            if let error = error {
                print("Error opening document: \(error)")
            }
        }
        closeWelcomeWindow()
    }

    private func loadRecentDocuments() {
        let documentController = NSDocumentController.shared
        recentDocuments = documentController.recentDocumentURLs.filter { url in
            url.pathExtension == "stratify"
        }
    }

    private func closeWelcomeWindow() {
        // Close the welcome window
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Icon Decomposer" }) {
            window.close()
        }
    }
}

#Preview {
    WelcomeWindow()
}
