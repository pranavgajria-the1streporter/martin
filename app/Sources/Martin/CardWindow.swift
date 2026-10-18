import AppKit
import WebKit

/// Clicks land on the card's buttons without first bringing Martin to the front.
final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A clear window just below the menu bar, under the notch, that holds Martin's card.
/// The window stays on screen all the time and ignores the mouse while Martin has nothing to say:
/// macOS stops drawing a hidden window, and a card whose animations never advance sits stuck under the menu bar.
@MainActor
final class CardWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let panel: CardPanel
    private var web: ClickThroughWebView!
    private var loaded = false
    private var queued: [String] = []
    var onMessage: (([String: Any]) -> Void)?

    /// True while macOS is drawing the window. Written to the log, so a stalled card shows its cause.
    var isDrawn: Bool { panel.isVisible && panel.occlusionState.contains(.visible) }

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 170)
        panel = CardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true

        web = makeWeb()
        panel.contentView = web

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.parkIfIdle() }
        }
    }

    private func makeWeb() -> ClickThroughWebView {
        let config = WKWebViewConfiguration()
        let view = ClickThroughWebView(frame: NSRect(origin: .zero, size: panel.frame.size), configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        config.userContentController.add(self, name: "martin")
        if let url = Bundle.main.url(forResource: "martin", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    /// Throws away the web view and loads the page again. Used when a card has not appeared.
    func rebuild() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "martin")
        web.navigationDelegate = nil
        loaded = false
        queued.removeAll()
        web = makeWeb()
        panel.contentView = web
    }

    func show(_ nudge: Nudge, late: Bool, counts: [String: Int], session: Int) {
        place()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        let countsJSON = counts.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        run("martin.play('\(nudge.rawValue)', { late: \(late), session: \(session), counts: { \(countsJSON) } })")
    }

    /// For testing: saves a picture of the card (open Martin.app --args --nudge walk --snapshot /tmp/martin).
    func snapshot(to path: String) {
        web.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("martin: snapshot \(path)\n".data(using: .utf8)!)
        }
    }

    func dismiss() { run("martin.dismiss()") }

    /// Between cards: still on screen so macOS keeps drawing it, but clear and click-through.
    func hide() {
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    func parkIfIdle() {
        guard panel.ignoresMouseEvents else { return }
        place()
        panel.orderFrontRegardless()
    }

    /// Centre under the notch, starting at the bottom of the menu bar.
    /// The card is the notch plus 30 points on each end.
    private func place() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
        var notch: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = screen.frame.width - left.width - right.width
        }
        let cardWidth = notch > 0 ? notch + 60 : 250
        let width = cardWidth + 70
        let height: CGFloat = 170
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let top = screen.frame.maxY - (menuBar > 0 ? menuBar : 32)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
        run("martin.setWidth(\(Int(cardWidth.rounded())))")
    }

    private func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js, completionHandler: nil) } else { queued.append(js) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        loaded = true
        queued.forEach { web.evaluateJavaScript($0, completionHandler: nil) }
        queued.removeAll()
    }

    /// macOS can end the page's process while Martin sits idle. Load it again so the next card has a page to run in.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("card: web process ended, rebuilding")
        rebuild()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}
