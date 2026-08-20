import Cocoa

// MARK: - Helpers

class FlippedView: NSView {
    override var isFlipped: Bool { true }   // top-to-bottom stacking
}

// MARK: - Orb view

class OrbView: NSView {
    var glowIntensity: CGFloat = 0
    private var pulseTimer: Timer?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 5, dy: 5)
        let path = NSBezierPath(ovalIn: r)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.5, green: 0.3, blue: 1.0, alpha: 0.7)
        shadow.shadowBlurRadius = 10 + glowIntensity * 8
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor(red: 0.35, green: 0.2, blue: 0.85, alpha: 0.95).setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let grad = NSGradient(
            colors: [
                NSColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1),
                NSColor(red: 0.2,  green: 0.1,  blue: 0.6, alpha: 1),
            ],
            atLocations: [0, 1], colorSpace: .deviceRGB)
        grad?.draw(in: path, angle: 135)

        if glowIntensity > 0 {
            NSColor(red: 0.8, green: 0.7, blue: 1.0, alpha: glowIntensity * 0.45).setFill()
            path.fill()
        }

        // Specular highlight
        let hi = NSBezierPath(ovalIn: NSRect(
            x: r.minX + r.width * 0.25, y: r.maxY - r.height * 0.38,
            width: r.width * 0.35,      height: r.height * 0.22))
        NSColor(white: 1, alpha: 0.35).setFill()
        hi.fill()
    }

    func pulse() {
        pulseTimer?.invalidate()
        glowIntensity = 1.0
        needsDisplay = true

        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values   = [1.0, 1.18, 0.96, 1.0]
        anim.keyTimes = [0,   0.3,  0.7,  1.0]
        anim.duration = 0.35
        wantsLayer = true
        layer?.add(anim, forKey: "pop")

        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] t in
            guard let s = self else { t.invalidate(); return }
            s.glowIntensity = max(0, s.glowIntensity - 0.07)
            s.needsDisplay = true
            if s.glowIntensity == 0 { t.invalidate() }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let c  = NSPoint(x: bounds.midX, y: bounds.midY)
        let r  = (min(bounds.width, bounds.height) / 2) - 5
        let dx = point.x - c.x, dy = point.y - c.y
        return (dx*dx + dy*dy <= r*r) ? super.hitTest(point) : nil
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var orbPanel:   NSPanel!
    var infoPanel:  NSPanel!
    var orbView:    OrbView!
    var counterLabel: NSTextField!
    var scrollView: NSScrollView!
    var contentStack: FlippedView!
    var messages: [String] = []
    var infoVisible = false

    static let panelW: CGFloat = 300
    static let panelH: CGFloat = 320   // fixed height — history scrolls inside

    func applicationDidFinishLaunching(_: Notification) {
        setupOrb()
        setupInfoPanel()
        startServer()
    }

    // MARK: Orb panel

    func setupOrb() {
        let size: CGFloat = 56
        orbPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        orbPanel.level = .floating
        orbPanel.backgroundColor = .clear
        orbPanel.isOpaque = false
        orbPanel.hasShadow = false
        orbPanel.isMovableByWindowBackground = true
        orbPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let screen = NSScreen.main {
            orbPanel.setFrameOrigin(NSPoint(x: screen.frame.width - 76, y: 80))
        }

        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        orbPanel.contentView = orbView

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleInfo))
        orbView.addGestureRecognizer(click)
        orbPanel.orderFront(nil)
    }

    // MARK: Info panel (history)

    func setupInfoPanel() {
        let W = AppDelegate.panelW, H = AppDelegate.panelH
        infoPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        infoPanel.level = .floating
        infoPanel.backgroundColor = NSColor(red: 0.07, green: 0.05, blue: 0.13, alpha: 0.97)
        infoPanel.isOpaque = false
        infoPanel.hasShadow = true

        let cv = infoPanel.contentView!
        cv.wantsLayer = true
        cv.layer?.cornerRadius = 16
        cv.layer?.masksToBounds = true
        cv.layer?.borderColor = NSColor(red: 0.5, green: 0.3, blue: 1.0, alpha: 0.35).cgColor
        cv.layer?.borderWidth = 1

        // Header bar
        let headerH: CGFloat = 36
        let headerBg = NSView(frame: NSRect(x: 0, y: H - headerH, width: W, height: headerH))
        headerBg.wantsLayer = true
        headerBg.layer?.backgroundColor = NSColor(red: 0.12, green: 0.08, blue: 0.22, alpha: 1).cgColor
        cv.addSubview(headerBg)

        let title = NSTextField(labelWithString: "✦  Wisp")
        title.textColor = NSColor(red: 0.7, green: 0.55, blue: 1.0, alpha: 1)
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.frame = NSRect(x: 14, y: H - headerH + (headerH - 15) / 2, width: 80, height: 15)
        cv.addSubview(title)

        counterLabel = NSTextField(labelWithString: "")
        counterLabel.textColor = NSColor(white: 1, alpha: 0.3)
        counterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        counterLabel.alignment = .right
        counterLabel.frame = NSRect(x: W - 80, y: H - headerH + (headerH - 13) / 2, width: 66, height: 13)
        cv.addSubview(counterLabel)

        // Thin divider
        let div = NSView(frame: NSRect(x: 0, y: H - headerH - 1, width: W, height: 1))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        cv.addSubview(div)

        // Scroll area
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: H - headerH - 1))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScroller?.controlSize = .mini

        contentStack = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 0))
        scrollView.documentView = contentStack
        cv.addSubview(scrollView)

        // Dismiss on click in empty space
        let click = NSClickGestureRecognizer(target: self, action: #selector(hideInfo))
        cv.addGestureRecognizer(click)
    }

    // MARK: Build a single history row

    func makeRow(index: Int, text: String) -> NSView {
        let numW:  CGFloat = 32
        let pad:   CGFloat = 10
        let textX  = 14 + numW
        let textW  = AppDelegate.panelW - textX - 10

        let tmp = NSTextField(wrappingLabelWithString: text)
        tmp.font = NSFont.systemFont(ofSize: 12)
        let textH = max(16, ceil(
            tmp.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 9999)).height ?? 16))
        let rowH = textH + pad * 2

        let row = NSView(frame: NSRect(x: 0, y: 0, width: AppDelegate.panelW, height: rowH))

        // Separator above every row except first
        if index > 1 {
            let sep = NSView(frame: NSRect(x: 14, y: 0, width: AppDelegate.panelW - 28, height: 0.5))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            row.addSubview(sep)
        }

        let numLabel = NSTextField(labelWithString: "#\(index)")
        numLabel.textColor = NSColor(red: 0.5, green: 0.3, blue: 1.0, alpha: 0.5)
        numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        numLabel.frame = NSRect(x: 14, y: pad, width: numW - 4, height: 13)
        row.addSubview(numLabel)

        let tf = NSTextField(wrappingLabelWithString: text)
        tf.textColor = NSColor(white: 0.88, alpha: 1)
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.frame = NSRect(x: textX, y: pad, width: textW, height: textH)
        row.addSubview(tf)

        return row
    }

    func appendRowToStack(_ text: String) {
        let idx = messages.count   // already appended, so count = current index
        let row = makeRow(index: idx, text: text)
        let y = contentStack.frame.height
        row.frame.origin.y = y
        contentStack.addSubview(row)
        contentStack.frame.size.height = y + row.frame.height
        scrollToBottom()
        counterLabel.stringValue = "\(messages.count) actions"
    }

    func rebuildStack() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        contentStack.frame.size.height = 0
        for (i, msg) in messages.enumerated() {
            let row = makeRow(index: i + 1, text: msg)
            let y = contentStack.frame.height
            row.frame.origin.y = y
            contentStack.addSubview(row)
            contentStack.frame.size.height = y + row.frame.height
        }
        counterLabel.stringValue = messages.isEmpty ? "" : "\(messages.count) actions"
        scrollToBottom()
    }

    func scrollToBottom() {
        let docH = contentStack.frame.height
        let visH = scrollView.frame.height
        if docH > visH {
            contentStack.scroll(NSPoint(x: 0, y: docH - visH))
        }
    }

    // MARK: Show / hide (with animation)

    func orbSeedFrame() -> NSRect {
        let f = orbPanel.frame
        return NSRect(x: f.minX - 2, y: f.midY - 2, width: 4, height: 4)
    }

    func destFrame() -> NSRect {
        let orbF = orbPanel.frame
        let W = AppDelegate.panelW, H = AppDelegate.panelH
        return NSRect(
            x: orbF.minX - W - 12,
            y: orbF.midY - H / 2,
            width: W, height: H)
    }

    @objc func toggleInfo() {
        infoVisible ? hideInfo() : showInfo()
    }

    func showInfo() {
        rebuildStack()

        if !infoVisible {
            infoPanel.setFrame(orbSeedFrame(), display: false)
            infoPanel.alphaValue = 0
            infoPanel.orderFront(nil)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.5, 0.64, 1)
            self.infoPanel.animator().setFrame(self.destFrame(), display: true)
            self.infoPanel.animator().alphaValue = 1
        }
        infoVisible = true
    }

    @objc func hideInfo() {
        guard infoVisible else { return }
        infoVisible = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 0.6)
            self.infoPanel.animator().setFrame(self.orbSeedFrame(), display: true)
            self.infoPanel.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                self.infoPanel.orderOut(nil)
                self.infoPanel.alphaValue = 1
            }
        })
    }

    // MARK: Receive message from hook

    func show(_ message: String) {
        DispatchQueue.main.async {
            self.messages.append(message)
            self.orbView.pulse()
            if self.infoVisible {
                self.appendRowToStack(message)
            }
        }
    }

    // MARK: HTTP server

    func startServer() {
        Thread.detachNewThread {
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port   = CFSwapInt16HostToBig(7891)
            addr.sin_addr.s_addr = INADDR_ANY

            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Darwin.listen(sock, 5)

            while true {
                let client = Darwin.accept(sock, nil, nil)
                guard client >= 0 else { continue }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.recv(client, &buf, buf.count, 0)
                if n > 0,
                   let req  = String(bytes: buf[0..<n], encoding: .utf8),
                   let sep  = req.range(of: "\r\n\r\n"),
                   let data = String(req[sep.upperBound...]).data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let msg  = json["message"] {
                    self.show(msg)
                }
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                _ = resp.withCString { Darwin.send(client, $0, Int(strlen($0)), 0) }
                Darwin.close(client)
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
