import AppKit
import SwiftUI

/// A vertical split with a draggable divider (editor above, results below).
/// Both panes always take the full width.
struct SplitPane<Top: View, Bottom: View>: View {
    @Binding var fraction: CGFloat
    var minTop: CGFloat = 96
    var minBottom: CGFloat = 120
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.height - 1, minTop + minBottom)
            let topHeight = min(max(usable * fraction, minTop), usable - minBottom)
            VStack(spacing: 0) {
                top
                    .frame(width: geo.size.width, height: topHeight)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .overlay {
                        // A taller invisible hit area than the 1 pt line.
                        Color.clear
                            .frame(height: Space.s)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = dragStart ?? topHeight
                                        dragStart = start
                                        fraction = (start + value.translation.height) / usable
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                    }
                    .accessibilityHidden(true)
                bottom
                    .frame(width: geo.size.width)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}
