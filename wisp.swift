import Cocoa

// MARK: - Helpers

class FlippedView: NSView {
    override var isFlipped: Bool { true }
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

    // Header
    var counterLabel: NSTextField!

    // Tabs
    var tabBar:     NSView!
    var tabButtons: [NSButton] = []
    var activeTab   = -1   // -1 = All, 0+ = session index

    // History
    var scrollView:   NSScrollView!
    var contentStack: FlippedView!
    var messages: [(text: String, sessionIdx: Int)] = []
    var sessionMap: [String: Int] = [:]

    var infoVisible = false
    var autoDismissTimer: Timer?

    static let sessionColors: [NSColor] = [
        NSColor(red: 0.65, green: 0.5,  blue: 1.0,  alpha: 1),  // purple
        NSColor(red: 0.3,  green: 0.85, blue: 0.85, alpha: 1),  // teal
        NSColor(red: 1.0,  green: 0.65, blue: 0.2,  alpha: 1),  // orange
        NSColor(red: 0.4,  green: 0.9,  blue: 0.5,  alpha: 1),  // green
    ]

    static let panelW:  CGFloat = 300
    static let panelH:  CGFloat = 340
    static let headerH: CGFloat = 36
    static let tabH:    CGFloat = 32

    var scrollH: CGFloat { AppDelegate.panelH - AppDelegate.headerH - 1 - AppDelegate.tabH - 1 }

    func applicationDidFinishLaunching(_: Notification) {
        setupOrb()
        setupInfoPanel()
        startServer()
    }

    // MARK: Orb

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

    // MARK: Info panel

    func setupInfoPanel() {
        let W = AppDelegate.panelW, H = AppDelegate.panelH
        let hH = AppDelegate.headerH, tH = AppDelegate.tabH

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

        // ── Header ────────────────────────────────────────────────────────────
        let headerBg = NSView(frame: NSRect(x: 0, y: H - hH, width: W, height: hH))
        headerBg.wantsLayer = true
        headerBg.layer?.backgroundColor = NSColor(red: 0.12, green: 0.08, blue: 0.22, alpha: 1).cgColor
        cv.addSubview(headerBg)

        let title = NSTextField(labelWithString: "✦  Wisp")
        title.textColor = NSColor(red: 0.7, green: 0.55, blue: 1.0, alpha: 1)
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.frame = NSRect(x: 14, y: H - hH + (hH - 15) / 2, width: 80, height: 15)
        cv.addSubview(title)

        counterLabel = NSTextField(labelWithString: "")
        counterLabel.textColor = NSColor(white: 1, alpha: 0.3)
        counterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        counterLabel.alignment = .right
        counterLabel.frame = NSRect(x: W - 80, y: H - hH + (hH - 13) / 2, width: 66, height: 13)
        cv.addSubview(counterLabel)

        // Divider below header
        let div1 = NSView(frame: NSRect(x: 0, y: H - hH - 1, width: W, height: 1))
        div1.wantsLayer = true
        div1.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        cv.addSubview(div1)

        // ── Tab bar ───────────────────────────────────────────────────────────
        tabBar = NSView(frame: NSRect(x: 0, y: H - hH - 1 - tH, width: W, height: tH))
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor(red: 0.09, green: 0.07, blue: 0.18, alpha: 1).cgColor
        cv.addSubview(tabBar)

        // "All" tab — always present
        addTabButton(label: "All", tag: -1)

        // Divider below tab bar
        let div2 = NSView(frame: NSRect(x: 0, y: H - hH - 1 - tH - 1, width: W, height: 1))
        div2.wantsLayer = true
        div2.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        cv.addSubview(div2)

        // ── Scroll area ───────────────────────────────────────────────────────
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: scrollH))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScroller?.controlSize = .mini

        contentStack = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 0))
        scrollView.documentView = contentStack
        cv.addSubview(scrollView)

        // Dismiss by clicking the orb again (toggleInfo) — no click-away here
        // so tab clicks don't accidentally close the panel
    }

    // MARK: Tabs

    func addTabButton(label: String, tag: Int) {
        let btn = NSButton(title: label, target: self, action: #selector(tabClicked(_:)))
        btn.isBordered = false
        btn.tag = tag
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        btn.contentTintColor = tag == activeTab
            ? NSColor(white: 1, alpha: 0.9)
            : NSColor(white: 1, alpha: 0.3)

        // Measure width
        btn.sizeToFit()
        let w = max(btn.frame.width + 16, 40)

        // Position after existing buttons
        let x = tabButtons.reduce(CGFloat(10)) { $0 + $1.frame.width + 8 }
        btn.frame = NSRect(x: x, y: (AppDelegate.tabH - 20) / 2, width: w, height: 20)

        tabBar.addSubview(btn)
        tabButtons.append(btn)
        refreshTabAppearance()
    }

    @objc func tabClicked(_ sender: NSButton) {
        activeTab = sender.tag
        refreshTabAppearance()
        rebuildStack()
    }

    func refreshTabAppearance() {
        for btn in tabButtons {
            let isActive = btn.tag == activeTab
            if isActive {
                let color = btn.tag == -1
                    ? NSColor(white: 1, alpha: 0.9)
                    : AppDelegate.sessionColors[btn.tag % AppDelegate.sessionColors.count]
                btn.contentTintColor = color
            } else {
                btn.contentTintColor = NSColor(white: 1, alpha: 0.28)
            }
        }
    }

    // MARK: History rows

    func makeRow(index: Int, text: String, sessionIdx: Int) -> NSView {
        let dotW:  CGFloat = 8
        let numW:  CGFloat = 28
        let pad:   CGFloat = 10
        let textX  = 14 + dotW + 6 + numW
        let textW  = AppDelegate.panelW - textX - 10
        let color  = AppDelegate.sessionColors[sessionIdx % AppDelegate.sessionColors.count]

        let tmp = NSTextField(wrappingLabelWithString: text)
        tmp.font = NSFont.systemFont(ofSize: 12)
        let textH = max(16, ceil(
            tmp.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 9999)).height ?? 16))
        let rowH = textH + pad * 2

        let row = NSView(frame: NSRect(x: 0, y: 0, width: AppDelegate.panelW, height: rowH))

        if index > 1 {
            let sep = NSView(frame: NSRect(x: 14, y: 0, width: AppDelegate.panelW - 28, height: 0.5))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            row.addSubview(sep)
        }

        let dot = NSView(frame: NSRect(x: 14, y: (rowH - dotW) / 2, width: dotW, height: dotW))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotW / 2
        dot.layer?.backgroundColor = color.withAlphaComponent(0.8).cgColor
        row.addSubview(dot)

        let numLabel = NSTextField(labelWithString: "#\(index)")
        numLabel.textColor = color.withAlphaComponent(0.5)
        numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        numLabel.frame = NSRect(x: 14 + dotW + 6, y: pad, width: numW - 4, height: 13)
        row.addSubview(numLabel)

        let tf = NSTextField(wrappingLabelWithString: text)
        tf.textColor = NSColor(white: 0.88, alpha: 1)
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.frame = NSRect(x: textX, y: pad, width: textW, height: textH)
        row.addSubview(tf)

        return row
    }

    func rebuildStack() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        contentStack.frame.size.height = 0

        // Filter by active tab (-1 = all)
        let filtered = activeTab == -1
            ? messages
            : messages.filter { $0.sessionIdx == activeTab }

        for (i, entry) in filtered.enumerated() {
            let row = makeRow(index: i + 1, text: entry.text, sessionIdx: entry.sessionIdx)
            let y = contentStack.frame.height
            row.frame.origin.y = y
            contentStack.addSubview(row)
            contentStack.frame.size.height = y + row.frame.height
        }
        updateCounter()
        scrollToBottom()
    }

    func updateCounter() {
        let total = messages.count
        let chatCount = sessionMap.count
        counterLabel.stringValue = total == 0 ? "" : (chatCount > 1
            ? "\(total) · \(chatCount) chats"
            : "\(total) actions")
    }

    func scrollToBottom() {
        let docH = contentStack.frame.height
        let visH = scrollView.frame.height
        if docH > visH {
            contentStack.scroll(NSPoint(x: 0, y: docH - visH))
        }
    }

    // MARK: Animate open / close

    func orbSeedFrame() -> NSRect {
        let f = orbPanel.frame
        return NSRect(x: f.minX - 2, y: f.midY - 2, width: 4, height: 4)
    }

    func destFrame() -> NSRect {
        let orbF = orbPanel.frame
        let W = AppDelegate.panelW, H = AppDelegate.panelH
        return NSRect(x: orbF.minX - W - 12, y: orbF.midY - H / 2, width: W, height: H)
    }

    @objc func toggleInfo() { infoVisible ? hideInfo() : showInfo() }

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
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
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

    // MARK: Receive from hook

    func show(_ message: String, session: String, name: String) {
        DispatchQueue.main.async {
            let isNew = self.sessionMap[session] == nil
            if isNew {
                let idx = self.sessionMap.count
                self.sessionMap[session] = idx
                self.addTabButton(label: name, tag: idx)
            }

            let idx   = self.sessionMap[session]!
            let entry = (text: message, sessionIdx: idx)
            self.messages.append(entry)
            self.orbView.pulse()
            self.updateCounter()

            // Auto-open so the description is visible before the user clicks Allow
            let wasVisible = self.infoVisible

            // Stay on whatever tab the user is on — don't hijack their view
            // New message appears if it matches the current tab, or always in All
            self.showInfo()

            if !wasVisible {
                // Auto-dismiss after 12 s — long enough to read, short enough not to pile up
                self.autoDismissTimer?.invalidate()
                self.autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
                    self?.hideInfo()
                }
            } else {
                // Panel already open — reset the timer so it stays visible for another 12 s
                self.autoDismissTimer?.invalidate()
                self.autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
                    self?.hideInfo()
                }
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

            let bindResult = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                // Port already taken — another Wisp is running, exit silently
                exit(0)
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
                    self.show(msg, session: json["session"] ?? "0", name: json["name"] ?? "Claude")
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
