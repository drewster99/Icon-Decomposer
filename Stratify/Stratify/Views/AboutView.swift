//
//  AboutView.swift
//  Stratify
//
//  Created by Andrew Benson on 10/27/25.
//

import SwiftUI
import SpriteKit

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            // App Icon and Name
            VStack(spacing: 12) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .cornerRadius(16)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(.blue)
                }

                Text(AppConfig.appName)
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(AppConfig.appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            // Mini Game (scaled down to 0.25x = 200x150 from 800x600)
            ZStack(alignment: .top) {
                MiniGameView()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(200.0/150.0, contentMode: .fit)
                    .padding()
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                Text("MINIGAME")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.windowBackgroundColor))
                    .offset(y: -4)
            }
            .padding(.vertical, 8)

            // Review request
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Please consider")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Link("reviewing this app", destination: AppConfig.appStoreReviewURL)
                        .font(.caption2)

                    Text("on the App Store.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text("We really appreciate it.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)

            // Copyright
            Text("Copyright © 2025 Nuclear Cyborg Corp.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            // Links
            HStack(spacing: 16) {
                Link("Website", destination: AppConfig.websiteURL)
                    .font(.caption)

                Text("•")
                    .foregroundColor(.secondary)

                Link("Privacy Policy", destination: AppConfig.privacyURL)
                    .font(.caption)

                Text("•")
                    .foregroundColor(.secondary)

                Link("Terms of Use", destination: AppConfig.termsURL)
                    .font(.caption)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 380, height: 520)
    }
}

struct MiniGameView: NSViewRepresentable {
    func makeNSView(context: Context) -> SKView {
        let skView = SKView()
        skView.ignoresSiblingOrder = true

        // Ensure at least 1 credit for the mini-game
        let credits = UserDefaults.standard.integer(forKey: "StratifyMinigameCredits")
        if credits == 0 {
            UserDefaults.standard.set(1, forKey: "StratifyMinigameCredits")
        }

        // Create scene at original size (800x600) but display in smaller frame (200x150)
        // This scales everything down proportionally (0.25x) including text
        let scene = CreditsScene(size: CGSize(width: 800, height: 600))
        scene.scaleMode = .aspectFit
        skView.presentScene(scene)

        return skView
    }

    func updateNSView(_ nsView: SKView, context: Context) {
        // No updates needed
    }
}

#Preview {
    AboutView()
}
