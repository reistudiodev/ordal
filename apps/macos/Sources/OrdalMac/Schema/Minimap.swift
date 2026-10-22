import DBClientKit
import SwiftUI

/// The whole diagram in miniature with the visible area outlined; click or
/// drag to move around.
struct Minimap: View {
    let tab: SchemaTabModel
    let canvas: CGSize
    let controller: CanvasController
    static let size = CGSize(width: 220, height: 150)

    var body: some View {
        let scale = min(Self.size.width / max(canvas.width, 1), Self.size.height / max(canvas.height, 1))
        Canvas { ctx, _ in
            for t in tab.visibleTables {
                guard let p = tab.positions[t.name] else { continue }
                let rect = CGRect(x: p.x * scale, y: p.y * scale,
                                  width: SchemaLayout.cardWidth * scale, height: SchemaLayout.cardHeight(t) * scale)
                let color: Color = tab.selected == t.name ? .accentColor : .secondary.opacity(0.55)
                ctx.fill(Path(rect), with: .color(color))
            }
            let v = controller.visibleRect
            let viewport = CGRect(x: v.minX * scale, y: v.minY * scale, width: v.width * scale, height: v.height * scale)
            ctx.fill(Path(viewport), with: .color(.accentColor.opacity(0.1)))
            ctx.stroke(Path(viewport), with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { v in
                controller.center(on: CGPoint(x: v.location.x / scale, y: v.location.y / scale))
            }
        )
        .help("Click or drag to move around the diagram")
        .accessibilityLabel("Minimap")
    }
}

/// The key for the column glyphs, as a bar at the bottom of the canvas.
struct DiagramLegend: View {
    var body: some View {
        HStack(spacing: Space.l) {
            item(ColumnGlyph.primaryKey, "Primary key")
            item(ColumnGlyph.identity, "Identity")
            item(ColumnGlyph.unique, "Unique")
            item(ColumnGlyph.nullable, "Nullable")
            item(ColumnGlyph.notNull, "Non-nullable")
            item("line.diagonal", "Inferred relation", dashed: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s - 2)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func item(_ symbol: String, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: Space.hairline) {
            if dashed {
                Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 18, y: 5)) }
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 18, height: 10)
            } else {
                Image(systemName: symbol)
            }
            Text(label)
        }
    }
}
