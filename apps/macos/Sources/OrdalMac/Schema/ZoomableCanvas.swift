import AppKit
import Observation
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

    /// The whole canvas as a PNG at 2x.
    func pngData() -> Data? {
        guard let doc = scrollView?.documentView else { return nil }
        guard let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return nil }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// An `NSScrollView` with native trackpad panning and pinch / ⌘-scroll zoom
/// around SwiftUI content, so text stays crisp at every zoom level.
struct ZoomableCanvas<Content: View>: NSViewRepresentable {
    let size: CGSize
    let controller: CanvasController
    /// Overrides the app's appearance for the canvas (nil = match the app).
    var appearance: NSAppearance? = nil
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = CanvasController.minZoom
        scroll.maxMagnification = CanvasController.maxZoom
        scroll.drawsBackground = false
        scroll.appearance = appearance
        let hosting = NSHostingView(rootView: content())
        hosting.frame = CGRect(origin: .zero, size: size)
        scroll.documentView = hosting
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll)
        controller.scrollView = scroll
        DispatchQueue.main.async { controller.sync() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let hosting = scroll.documentView as? NSHostingView<Content> else { return }
        if scroll.appearance != appearance { scroll.appearance = appearance }
        hosting.rootView = content()
        if hosting.frame.size != size { hosting.frame.size = size }
        controller.scrollView = scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    @MainActor
    final class Coordinator: NSObject {
        let controller: CanvasController
        private var tokens: [NSObjectProtocol] = []

        init(_ controller: CanvasController) { self.controller = controller }

        func observe(_ scroll: NSScrollView) {
            let center = NotificationCenter.default
            for name in [NSView.boundsDidChangeNotification, NSScrollView.didEndLiveMagnifyNotification, NSScrollView.didLiveScrollNotification] {
                let object: Any? = name == NSView.boundsDidChangeNotification ? scroll.contentView : scroll
                tokens.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller.sync() }
                })
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
