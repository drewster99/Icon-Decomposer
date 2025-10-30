//
//  OriginalIconWindow.swift
//  Stratify
//
//  Window view for displaying original icon at full size
//

import SwiftUI

struct OriginalIconWindow: View {
    @EnvironmentObject var store: OriginalIconStore

    var body: some View {
        if let image = store.currentImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(CheckerboardBackground())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Original Icon")
        } else {
            ContentUnavailableView {
                Label("No Image", systemImage: "photo")
            } description: {
                Text("The image could not be loaded")
            }
        }
    }
}

#Preview {
    OriginalIconWindow()
        .environmentObject(OriginalIconStore.shared)
}