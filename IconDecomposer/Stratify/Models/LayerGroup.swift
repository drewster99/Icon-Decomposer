//
//  LayerGroup.swift
//  Stratify
//
//  Represents a group of layers for .icon bundle export
//

import Foundation

struct LayerGroup: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var layers: [Layer]
    var effects: GroupEffects

    init(id: UUID = UUID(),
         name: String,
         layers: [Layer],
         effects: GroupEffects = GroupEffects()) {
        self.id = id
        self.name = name
        self.layers = layers
        self.effects = effects
    }
}

struct GroupEffects: Codable, Sendable {
    /// Apply glass effect to this group
    var hasGlass: Bool = false

    /// Shadow opacity (0.0 - 1.0)
    var shadowOpacity: Float = 0.5

    /// Translucency value (0.0 - 1.0)
    var translucencyValue: Float = 0.4

    /// Lighting mode
    var lighting: LightingMode = .combined

    /// Enable specular highlights
    var hasSpecular: Bool = true
}

enum LightingMode: String, Codable, Sendable {
    case individual
    case combined
}
