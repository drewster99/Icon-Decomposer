//
//  WelcomeWindow.swift
//  Stratify
//
//  Welcome screen shown on app launch
//

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeWindow: View {
    private static let fontFamily = "Didot"
    var onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            // Header
            VStack(spacing: 12) {
                Text("Welcome to Stratify")
                    .font(.custom(Self.fontFamily, size: 36, relativeTo: .largeTitle))

                Text("Easily convert your single-image icons to Icon Composer layers")
                    .font(.custom(Self.fontFamily, size: 20, relativeTo: .title3))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 50)

            // Three steps
            HStack(spacing: 50) {
                // Step 1
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 80, height: 80)

                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                    }

                    Text("Step 1")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("Import your single file\nPNG or JPG icon")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 200)

                // Step 2
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 80, height: 80)

                        Image(systemName: "square.stack.3d.down.forward")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                    }

                    Text("Step 2")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("Stratify automatically splits\ninto layers that you can adjust")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 200)

                // Step 3
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 80, height: 80)

                        Image(systemName: "shippingbox")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                    }

                    Text("Step 3")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("Export the layer stack into\na .icon Icon Composer bundle")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 200)
            }
            .padding(.vertical, 20)

            // Get Started button
            Button(action: getStarted) {
                Text("Get Started")
                    .font(.title3)
                    .fontWeight(.medium)
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 10)

            Spacer()
        }
        .frame(width: 800, height: 550)
    }

    private func getStarted() {
        // Close the welcome window
        if let window = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Stratify" }) {
            window.close()
        }

        // Call the callback to switch scenes and create new document
        onGetStarted()
    }

    // Temporary storage for image dropped on welcome screen
    static var pendingImage: NSImage?
}

#Preview {
    WelcomeWindow(onGetStarted: {})
}
