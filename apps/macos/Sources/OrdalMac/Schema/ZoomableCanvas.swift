import AppKit
import Observation
import OrdalKit
import SwiftUI

/// Drives a `ZoomableCanvas`: zoom, fit, scroll-to, export, and the visible
/// rect the minimap draws.
@MainActor @Observable
final class CanvasController {
    fileprivate weak var scrollView: NSScrollView?
    /// The part of the canvas on screen, in canvas coordinates.
    private(set) var visibleRect: CGRect = .zero
    private(set) var magnification: CGFloat = 1

    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 2

    fileprivate func sync() {
        guard let scrollView else { return }
        let rect = scrollView.documentVisibleRect
        if rect != visibleRect { visibleRect = rect }
        if scrollView.magnification != magnification { magnification = scrollView.magnification }
    }

    func zoom(by factor: CGFloat) {
        guard let scrollView else { return }
        let target = min(max(scrollView.magnification * factor, Self.minZoom), Self.maxZoom)
        scrollView.setMagnification(target, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        sync()
    }

    func zoomToActualSize() {
        guard let scrollView else { return }
        scrollView.setMagnification(1, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        sync()
    }

    /// Fits `rect` (canvas coordinates) on screen with a small margin.
    func fit(_ rect: CGRect) {
        guard let scrollView else { return }
        scrollView.magnify(toFit: rect.insetBy(dx: -40, dy: -40))
        if scrollView.magnification > 1 { scrollView.setMagnification(1, centeredAt: CGPoint(x: rect.midX, y: rect.midY)) }
        sync()
    }

    /// Scrolls so `point` (canvas coordinates) is in the middle of the view.
    func center(on point: CGPoint) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let size = scrollView.contentView.bounds.size
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(0, origin.x), max(0, doc.bounds.width - size.width))
        origin.y = min(max(0, origin.y), max(0, doc.bounds.height - size.height))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sync()
    }

    /// The whole canvas as a PNG.
    func pngData() -> Data? {
        guard let doc = scrollView?.documentView else { return nil }
        guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return nil }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// For the snapshot checks: the hosting view that receives mouse events.
    var documentView: NSView? { scrollView?.documentView }
}

/// What the canvas does with the mouse. All points are canvas coordinates.
struct CanvasInteraction {
    /// The card under a point and its top-left corner, if any.
    var cardAt: (CGPoint) -> (name: String, origin: CGPoint)?
    /// Whether a point is on a card's ⋮ button.
    var isMenuButton: (CGPoint, _ card: String, _ origin: CGPoint) -> Bool
    /// The ⋮ menu for a card (also shown on right-click).
    var menu: (_ card: String) -> NSMenu
    var move: (_ card: String, _ origin: CGPoint, _ persist: Bool) -> Void
    var clickCard: (_ card: String, _ clickCount: Int) -> Void
    var clickBackground: () -> Void
    /// The pointer moved to a point (nil when it left the canvas or a drag began).
    var hover: (CGPoint?) -> Void
}

/// Hosts the SwiftUI diagram and handles every pointer interaction in AppKit,
/// where `convert(_:from:)` accounts for the scroll view's magnification
/// exactly (SwiftUI's own hover and hit-testing drift when zoomed). Dragging
/// a card moves it in the model on every event, so its connectors follow;
/// dragging empty canvas pans; hover and the ⋮ menu are resolved here too.
final class DiagramHostingView<Content: View>: NSHostingView<Content> {
    var interaction: CanvasInteraction?

    private enum Drag {
        case card(name: String, grab: CGSize, startWindow: CGPoint, moved: Bool)
        case pan(startWindow: CGPoint, startOrigin: CGPoint, moved: Bool)
    }
    private var drag: Drag?
    /// Screen distance before a press becomes a drag.
    private let threshold: CGFloat = 3

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let interaction else { return super.mouseMoved(with: event) }
        if drag == nil { interaction.hover(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseExited(with event: NSEvent) {
        guard let interaction else { return super.mouseExited(with: event) }
        interaction.hover(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let interaction else { return super.rightMouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if let (name, _) = interaction.cardAt(p) {
            interaction.menu(name).popUp(positioning: nil, at: p, in: self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let interaction else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        if let (name, origin) = interaction.cardAt(p) {
            if interaction.isMenuButton(p, name, origin) {
                // Open under the ⋮ button, like a pull-down.
                let anchor = CGPoint(x: origin.x + SchemaLayout.cardWidth - 28, y: origin.y + SchemaLayout.headerHeight)
                interaction.menu(name).popUp(positioning: nil, at: anchor, in: self)
                return
            }
            interaction.hover(nil)
            drag = .card(name: name, grab: CGSize(width: p.x - origin.x, height: p.y - origin.y),
                         startWindow: event.locationInWindow, moved: false)
        } else if let clip = enclosingScrollView?.contentView {
            drag = .pan(startWindow: event.locationInWindow, startOrigin: clip.bounds.origin, moved: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction, let current = drag else { return super.mouseDragged(with: event) }
        switch current {
        case let .card(name, grab, start, moved):
            guard moved || distance(event.locationInWindow, start) >= threshold else { return }
            if !moved { NSCursor.closedHand.push() }
            drag = .card(name: name, grab: grab, startWindow: start, moved: true)
            autoscroll(with: event)
            let p = convert(event.locationInWindow, from: nil)
            interaction.move(name, CGPoint(x: p.x - grab.width, y: p.y - grab.height), false)
        case let .pan(start, startOrigin, moved):
            guard moved || distance(event.locationInWindow, start) >= threshold,
                  let scroll = enclosingScrollView else { return }
            if !moved { NSCursor.closedHand.push() }
            drag = .pan(startWindow: start, startOrigin: startOrigin, moved: true)
            // Window points to canvas units; the window's y axis points up, the canvas's down.
            let m = scroll.magnification
            let dx = (event.locationInWindow.x - start.x) / m
            let dy = (event.locationInWindow.y - start.y) / m
            let doc = bounds.size, clip = scroll.contentView.bounds.size
            let origin = CGPoint(x: min(max(0, startOrigin.x - dx), max(0, doc.width - clip.width)),
                                 y: min(max(0, startOrigin.y + dy), max(0, doc.height - clip.height)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction, let current = drag else { return super.mouseUp(with: event) }
        drag = nil
        switch current {
        case let .card(name, grab, _, moved):
            if moved {
                NSCursor.pop()
                let p = convert(event.locationInWindow, from: nil)
                interaction.move(name, CGPoint(x: p.x - grab.width, y: p.y - grab.height), true)
            } else {
                interaction.clickCard(name, event.clickCount)
            }
        case let .pan(_, _, moved):
            if moved { NSCursor.pop() } else { interaction.clickBackground() }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// An `NSScrollView` with native trackpad panning and pinch / ⌘-scroll zoom
/// around SwiftUI content, so text stays crisp at every zoom level. The
/// canvas always covers the whole viewport, whatever the zoom.
struct ZoomableCanvas<Content: View>: NSViewRepresentable {
    /// The size the content needs; the canvas grows to fill the viewport.
    let contentSize: CGSize
    let controller: CanvasController
    /// Overrides the app's appearance for the canvas (nil = match the app).
    var appearance: NSAppearance? = nil
    let interaction: CanvasInteraction
    /// Builds the content for the canvas's effective size.
    let content: (CGSize) -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = CanvasController.minZoom
        scroll.maxMagnification = CanvasController.maxZoom
        scroll.drawsBackground = true
        scroll.backgroundColor = DiagramPalette.canvas
        scroll.appearance = appearance
        let hosting = DiagramHostingView(rootView: content(contentSize))
        hosting.interaction = interaction
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        scroll.documentView = hosting
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        context.coordinator.parent = self
        context.coordinator.observe(scroll)
        controller.scrollView = scroll
        DispatchQueue.main.async {
            context.coordinator.layout(scroll)
            controller.sync()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if scroll.appearance != appearance { scroll.appearance = appearance }
        (scroll.documentView as? DiagramHostingView<Content>)?.interaction = interaction
        controller.scrollView = scroll
        context.coordinator.layout(scroll)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ZoomableCanvas
        private var tokens: [NSObjectProtocol] = []

        init(_ parent: ZoomableCanvas) { self.parent = parent }

        /// Sizes the document to cover the viewport (in canvas units, so
        /// zooming out never shows anything but canvas) and re-renders it.
        func layout(_ scroll: NSScrollView) {
            guard let hosting = scroll.documentView as? DiagramHostingView<Content> else { return }
            let clip = scroll.contentView.bounds.size
            let size = CGSize(width: max(parent.contentSize.width, clip.width.rounded(.up)),
                              height: max(parent.contentSize.height, clip.height.rounded(.up)))
            if hosting.frame.size != size { hosting.frame.size = size }
            hosting.rootView = parent.content(size)
        }

        func observe(_ scroll: NSScrollView) {
            let center = NotificationCenter.default
            let sync = { [weak self, weak scroll] in
                guard let self, let scroll else { return }
                self.parent.controller.sync()
                // Zoom or resize can expose area beyond the content: grow to cover it.
                let clip = scroll.contentView.bounds.size
                if let doc = scroll.documentView, clip.width > doc.frame.width + 0.5 || clip.height > doc.frame.height + 0.5 {
                    self.layout(scroll)
                }
            }
            let names: [(Notification.Name, Any?)] = [
                (NSView.boundsDidChangeNotification, scroll.contentView),
                (NSView.frameDidChangeNotification, scroll),
                (NSScrollView.didEndLiveMagnifyNotification, scroll),
                (NSScrollView.didLiveScrollNotification, scroll),
            ]
            for (name, object) in names {
                tokens.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
                    MainActor.assumeIsolated { sync() }
                })
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Colours shared by the canvas, its background and the scroll view, so the
/// whole tab is one surface.
enum DiagramPalette {
    static let canvas = NSColor.windowBackgroundColor
    static let dots = NSColor.tertiaryLabelColor.withAlphaComponent(0.6)
}
