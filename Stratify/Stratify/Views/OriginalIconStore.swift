//
//  OriginalIconStore.swift
//  Stratify
//
//  Shared storage for passing image to original icon window
//

import SwiftUI
import Combine

class OriginalIconStore: ObservableObject {
    static let shared = OriginalIconStore()

    @Published var currentImage: NSImage?

    private init() {}
}