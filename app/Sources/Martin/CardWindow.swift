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
/// It is only on screen while Martin has something to say.
@MainActor
final class CardWindow: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let panel: CardPanel
    private let web: ClickThroughWebView
    private var loaded = false
    private var queued: [String] = []
    var onMessage: (([String: Any]) -> Void)?

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 170)
        panel = CardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        web = ClickThroughWebView(frame: frame, configuration: WKWebViewConfiguration())
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.configuration.userContentController.add(self, name: "martin")
        panel.contentView = web

        if let url = Bundle.main.url(forResource: "martin", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    func show(_ nudge: Nudge, late: Bool, counts: [String: Int]) {
        place()
        panel.orderFrontRegardless()
        let countsJSON = counts.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ")
        run("martin.play('\(nudge.rawValue)', { late: \(late), counts: { \(countsJSON) } })")
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

    func hide() { panel.orderOut(nil) }

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
        loaded = true
        queued.forEach { web.evaluateJavaScript($0, completionHandler: nil) }
        queued.removeAll()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}
