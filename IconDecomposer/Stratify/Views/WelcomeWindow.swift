//
//  WelcomeWindow.swift
//  IconDecomposer
//
//  Welcome screen shown on app launch
//

import SwiftUI

struct WelcomeWindow: View {
    var body: some View {
        HStack(spacing: 0) {
            // Left side - branding
            VStack {
                Image(systemName: "square.stack.3d.down.forward.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue.gradient)
                    .padding(.bottom, 20)

                Text("Icon Decomposer")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Break down app icons into editable layers")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(width: 300)
            .padding(40)
            .background(Color(nsColor: .controlBackgroundColor))

            // Right side - actions
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    WelcomeActionButton(
                        icon: "plus.square.fill",
                        title: "New Project",
                        description: "Import an icon and decompose it into layers"
                    ) {
                        createNewDocument()
                    }

                    WelcomeActionButton(
                        icon: "doc.fill",
                        title: "Open Project",
                        description: "Continue working on a saved project"
                    ) {
                        openDocument()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Projects")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    // TODO: Show recent documents
                    Text("No recent projects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 32)
                }

                Spacer()

                HStack {
                    Spacer()
                    Toggle("Show this window on startup", isOn: .constant(true))
                        .font(.caption)
                }
            }
            .padding(30)
            .frame(width: 400)
        }
        .frame(width: 1190, height: 675)
    }

    private func createNewDocument() {
        NSDocumentController.shared.newDocument(nil)
        closeWelcomeWindow()
    }

    private func openDocument() {
        NSDocumentController.shared.openDocument(nil)
        closeWelcomeWindow()
    }

    private func closeWelcomeWindow() {
        // Close the welcome window
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Icon Decomposer" }) {
            window.close()
        }
    }
}

struct WelcomeActionButton: View {
    let icon: String
    let title: String
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WelcomeWindow()
}
