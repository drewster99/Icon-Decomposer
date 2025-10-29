//
//  ProductOptionView.swift
//  Pricing
//
//  Created by Andrew Benson on 3/2/25.
//  Copyright © 2025 Nuclear Cyborg. All rights reserved.
//

import Foundation
import OSLog
import SwiftUI
import AVKit
import StoreKit

struct ProductOptionView: View {
    private let savingsPercentHighlightBackgroundColor = Color(.paywallSavingsHighlightBackground)
    
    public init(product: PurchaseProductDetails, isSelected: Bool, accentColor: Color, onSelect: @escaping () -> Void, savingsPercent: Double) {
        self.product = product
        self.isSelected = isSelected
        self.accentColor = accentColor
        self.onSelect = onSelect
        self.savingsPercent = savingsPercent
    }

    let product: PurchaseProductDetails
    let isSelected: Bool
    let accentColor: Color
    let onSelect: () -> Void
    let savingsPercent: Double

    var body: some View {
        Button(action: onSelect) {
                VStack(alignment: .leading) {
                    HStack(alignment: .center) {
                        Text(product.durationPlanName)
                            .font(.headline)
                        Spacer()
                        Text("\(product.weeklyCostText)/week")
                            .fontWeight(.regular)

                    }
                    HStack {
                        if product.hasTrial, let trialDescription = product.trialDurationDescription {
                            Text("\(trialDescription), then \(product.price)/\(product.duration)")
                                .fontWeight(.regular)
                        } else {
                            Text("\(product.price) per \(product.duration)")
                                .fontWeight(.regular)
                        }

                        Spacer()
                        Text("SAVE \(String(format: "%0.0f", savingsPercent))%")
                            
                            .padding(6)
                            .background(savingsPercentHighlightBackgroundColor)
                            .foregroundColor(.black)
                            .cornerRadius(4)
                            .opacity(savingsPercent > 1.0 ? 1.0 : 0.0)
                    }
                    if product.allowsFamilySharing {
                        HStack {
                            Text("Family sharing included")
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .transition(.scale(scale: 0.5, anchor: .center).animation(.spring()))
                    }
                }
            .padding()
            .background(isSelected ? accentColor.opacity(0.25) : Color.clear)
            .cornerRadius(8)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isSelected ? accentColor : Color.secondary.opacity(0.3), lineWidth: 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
