import Foundation
import SwiftCrossUI

/// Modern developer-tool iconography vector shapes (no emojis, crisp resolution-independent vectors).
public enum IconType: Sendable {
    case table
    case database
    case schema
    case folder
    case view
    case function
    case column
    case index
    case key
    case search
    case refresh
    case plus
    case play
    case stop
    case history
    case copy
    case export
    case edit
    case close
    case chevronRight
    case chevronDown
    case chevronUp
    case chevronLeft
    case checkmark
    case warning
    case home
    case inspector
}

public struct ModernIcon: View {
    public let type: IconType
    public let color: Color
    public let size: Double
    public let strokeWidth: Double

    public init(
        _ type: IconType,
        color: Color = Color(white: 0.75),
        size: Double = 14,
        strokeWidth: Double = 1.4
    ) {
        self.type = type
        self.color = color
        self.size = size
        self.strokeWidth = strokeWidth
    }

    public var body: some View {
        IconVectorShape(type: type, targetSize: size)
            .stroke(color, style: StrokeStyle(width: strokeWidth, cap: .round, join: .round))
            .frame(width: size, height: size)
    }
}

public struct IconVectorShape: Shape {
    public let type: IconType
    public let targetSize: Double

    public init(type: IconType, targetSize: Double = 14) {
        self.type = type
        self.targetSize = targetSize
    }

    public func size(fitting proposal: ProposedViewSize) -> ViewSize {
        var w = proposal.width ?? targetSize
        if w.isInfinite || w.isNaN || w <= 0 {
            w = targetSize
        }
        var h = proposal.height ?? targetSize
        if h.isInfinite || h.isNaN || h <= 0 {
            h = targetSize
        }
        let s = min(w, h)
        return ViewSize(s, s)
    }

    public func path(in bounds: Path.Rect) -> Path {
        let x = { (p: Double) -> Double in bounds.x + bounds.width * p }
        let y = { (p: Double) -> Double in bounds.y + bounds.height * p }

        switch type {
        case .table:
            return Path()
                // outer box
                .move(to: [x(0.12), y(0.16)])
                .addLine(to: [x(0.88), y(0.16)])
                .addLine(to: [x(0.88), y(0.84)])
                .addLine(to: [x(0.12), y(0.84)])
                .addLine(to: [x(0.12), y(0.16)])
                // header divider
                .move(to: [x(0.12), y(0.40)])
                .addLine(to: [x(0.88), y(0.40)])
                // vertical column divider
                .move(to: [x(0.44), y(0.40)])
                .addLine(to: [x(0.44), y(0.84)])

        case .database:
            return Path()
                // top rim
                .move(to: [x(0.15), y(0.28)])
                .addQuadCurve(control: [x(0.50), y(0.14)], to: [x(0.85), y(0.28)])
                .addQuadCurve(control: [x(0.50), y(0.42)], to: [x(0.15), y(0.28)])
                // sides
                .move(to: [x(0.15), y(0.28)])
                .addLine(to: [x(0.15), y(0.72)])
                .move(to: [x(0.85), y(0.28)])
                .addLine(to: [x(0.85), y(0.72)])
                // middle curve
                .move(to: [x(0.15), y(0.50)])
                .addQuadCurve(control: [x(0.50), y(0.64)], to: [x(0.85), y(0.50)])
                // bottom curve
                .move(to: [x(0.15), y(0.72)])
                .addQuadCurve(control: [x(0.50), y(0.86)], to: [x(0.85), y(0.72)])

        case .schema, .folder:
            return Path()
                .move(to: [x(0.12), y(0.24)])
                .addLine(to: [x(0.42), y(0.24)])
                .addLine(to: [x(0.52), y(0.36)])
                .addLine(to: [x(0.88), y(0.36)])
                .addLine(to: [x(0.88), y(0.82)])
                .addLine(to: [x(0.12), y(0.82)])
                .addLine(to: [x(0.12), y(0.24)])

        case .view:
            return Path()
                .move(to: [x(0.10), y(0.50)])
                .addQuadCurve(control: [x(0.50), y(0.18)], to: [x(0.90), y(0.50)])
                .addQuadCurve(control: [x(0.50), y(0.82)], to: [x(0.10), y(0.50)])
                .addCircle(center: [x(0.50), y(0.50)], radius: bounds.width * 0.15)

        case .function:
            return Path()
                .move(to: [x(0.58), y(0.12)])
                .addLine(to: [x(0.28), y(0.50)])
                .addLine(to: [x(0.52), y(0.50)])
                .addLine(to: [x(0.42), y(0.88)])
                .addLine(to: [x(0.74), y(0.46)])
                .addLine(to: [x(0.48), y(0.46)])
                .addLine(to: [x(0.58), y(0.12)])

        case .column:
            return Path()
                .move(to: [x(0.32), y(0.18)])
                .addLine(to: [x(0.68), y(0.18)])
                .addLine(to: [x(0.68), y(0.82)])
                .addLine(to: [x(0.32), y(0.82)])
                .addLine(to: [x(0.32), y(0.18)])

        case .index:
            return Path()
                .move(to: [x(0.15), y(0.38)])
                .addLine(to: [x(0.85), y(0.38)])
                .move(to: [x(0.15), y(0.64)])
                .addLine(to: [x(0.85), y(0.64)])
                .move(to: [x(0.40), y(0.18)])
                .addLine(to: [x(0.32), y(0.84)])
                .move(to: [x(0.66), y(0.18)])
                .addLine(to: [x(0.58), y(0.84)])

        case .key:
            return Path()
                .addCircle(center: [x(0.36), y(0.36)], radius: bounds.width * 0.20)
                .move(to: [x(0.50), y(0.50)])
                .addLine(to: [x(0.84), y(0.84)])
                .move(to: [x(0.70), y(0.70)])
                .addLine(to: [x(0.84), y(0.56)])
                .move(to: [x(0.78), y(0.78)])
                .addLine(to: [x(0.88), y(0.68)])

        case .search:
            return Path()
                .addCircle(center: [x(0.42), y(0.42)], radius: bounds.width * 0.25)
                .move(to: [x(0.60), y(0.60)])
                .addLine(to: [x(0.86), y(0.86)])

        case .refresh:
            return Path()
                .addArc(
                    center: [x(0.50), y(0.50)],
                    radius: bounds.width * 0.32,
                    startAngle: 0.3,
                    endAngle: 5.5,
                    clockwise: true
                )
                .move(to: [x(0.74), y(0.24)])
                .addLine(to: [x(0.80), y(0.46)])
                .addLine(to: [x(0.58), y(0.42)])

        case .plus:
            return Path()
                .move(to: [x(0.50), y(0.20)])
                .addLine(to: [x(0.50), y(0.80)])
                .move(to: [x(0.20), y(0.50)])
                .addLine(to: [x(0.80), y(0.50)])

        case .play:
            return Path()
                .move(to: [x(0.26), y(0.20)])
                .addLine(to: [x(0.82), y(0.50)])
                .addLine(to: [x(0.26), y(0.80)])
                .addLine(to: [x(0.26), y(0.20)])

        case .stop:
            return Path()
                .move(to: [x(0.25), y(0.25)])
                .addLine(to: [x(0.75), y(0.25)])
                .addLine(to: [x(0.75), y(0.75)])
                .addLine(to: [x(0.25), y(0.75)])
                .addLine(to: [x(0.25), y(0.25)])

        case .history:
            return Path()
                .addCircle(center: [x(0.50), y(0.50)], radius: bounds.width * 0.35)
                .move(to: [x(0.50), y(0.26)])
                .addLine(to: [x(0.50), y(0.50)])
                .addLine(to: [x(0.68), y(0.50)])

        case .copy:
            return Path()
                .move(to: [x(0.35), y(0.18)])
                .addLine(to: [x(0.82), y(0.18)])
                .addLine(to: [x(0.82), y(0.65)])
                .move(to: [x(0.18), y(0.35)])
                .addLine(to: [x(0.65), y(0.35)])
                .addLine(to: [x(0.65), y(0.82)])
                .addLine(to: [x(0.18), y(0.82)])
                .addLine(to: [x(0.18), y(0.35)])

        case .export:
            return Path()
                .move(to: [x(0.18), y(0.52)])
                .addLine(to: [x(0.18), y(0.82)])
                .addLine(to: [x(0.82), y(0.82)])
                .addLine(to: [x(0.82), y(0.52)])
                .move(to: [x(0.50), y(0.64)])
                .addLine(to: [x(0.50), y(0.20)])
                .move(to: [x(0.32), y(0.38)])
                .addLine(to: [x(0.50), y(0.20)])
                .addLine(to: [x(0.68), y(0.38)])

        case .edit:
            return Path()
                .move(to: [x(0.20), y(0.80)])
                .addLine(to: [x(0.38), y(0.80)])
                .addLine(to: [x(0.80), y(0.38)])
                .addLine(to: [x(0.62), y(0.20)])
                .addLine(to: [x(0.20), y(0.62)])
                .addLine(to: [x(0.20), y(0.80)])
                .move(to: [x(0.52), y(0.30)])
                .addLine(to: [x(0.70), y(0.48)])

        case .close:
            return Path()
                .move(to: [x(0.25), y(0.25)])
                .addLine(to: [x(0.75), y(0.75)])
                .move(to: [x(0.75), y(0.25)])
                .addLine(to: [x(0.25), y(0.75)])

        case .chevronRight:
            return Path()
                .move(to: [x(0.35), y(0.22)])
                .addLine(to: [x(0.68), y(0.50)])
                .addLine(to: [x(0.35), y(0.78)])

        case .chevronDown:
            return Path()
                .move(to: [x(0.22), y(0.35)])
                .addLine(to: [x(0.50), y(0.68)])
                .addLine(to: [x(0.78), y(0.35)])

        case .chevronUp:
            return Path()
                .move(to: [x(0.22), y(0.65)])
                .addLine(to: [x(0.50), y(0.32)])
                .addLine(to: [x(0.78), y(0.65)])

        case .chevronLeft:
            return Path()
                .move(to: [x(0.65), y(0.22)])
                .addLine(to: [x(0.32), y(0.50)])
                .addLine(to: [x(0.65), y(0.78)])

        case .checkmark:
            return Path()
                .move(to: [x(0.20), y(0.52)])
                .addLine(to: [x(0.42), y(0.74)])
                .addLine(to: [x(0.80), y(0.30)])

        case .warning:
            return Path()
                .move(to: [x(0.50), y(0.18)])
                .addLine(to: [x(0.84), y(0.80)])
                .addLine(to: [x(0.16), y(0.80)])
                .addLine(to: [x(0.50), y(0.18)])
                .move(to: [x(0.50), y(0.40)])
                .addLine(to: [x(0.50), y(0.58)])
                .move(to: [x(0.50), y(0.68)])
                .addLine(to: [x(0.50), y(0.72)])

        case .home:
            return Path()
                .move(to: [x(0.18), y(0.48)])
                .addLine(to: [x(0.50), y(0.20)])
                .addLine(to: [x(0.82), y(0.48)])
                .move(to: [x(0.26), y(0.44)])
                .addLine(to: [x(0.26), y(0.80)])
                .addLine(to: [x(0.74), y(0.80)])
                .addLine(to: [x(0.74), y(0.44)])

        case .inspector:
            return Path()
                .move(to: [x(0.15), y(0.20)])
                .addLine(to: [x(0.85), y(0.20)])
                .addLine(to: [x(0.85), y(0.80)])
                .addLine(to: [x(0.15), y(0.80)])
                .addLine(to: [x(0.15), y(0.20)])
                .move(to: [x(0.62), y(0.20)])
                .addLine(to: [x(0.62), y(0.80)])
        }
    }
}
