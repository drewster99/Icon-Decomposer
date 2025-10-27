//
//  SharedViews.swift
//  IconDecomposer
//
//  Shared UI components
//

import SwiftUI

/// Checkerboard background for transparency visualization
struct CheckerboardBackground: View {
    let squareSize: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let rows = Int(ceil(size.height / squareSize))
                let columns = Int(ceil(size.width / squareSize))

                for row in 0..<rows {
                    for column in 0..<columns {
                        let isLight = (row + column) % 2 == 0
                        let color = isLight ? Color(white: 0.95) : Color(white: 0.85)

                        let rect = CGRect(
                            x: CGFloat(column) * squareSize,
                            y: CGFloat(row) * squareSize,
                            width: squareSize,
                            height: squareSize
                        )

                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }
}
