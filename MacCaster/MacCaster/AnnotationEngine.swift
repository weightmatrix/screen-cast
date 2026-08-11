import Foundation
import Combine
import AppKit
import CoreGraphics

final class AnnotationEngine: ObservableObject {
    enum Tool { case none, pen, eraser }

    @Published var tool: Tool = .none
    var isActive: Bool { toolbarWindow != nil }

    private var strokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []
    private var drawingWindow: NSWindow?
    private var toolbarWindow: NSWindow?
    private var monitor: Any?
    private var penBtn: NSButton?
    private var eraserBtn: NSButton?
    private var isShuttingDown = false

    func showToolbar() {
        guard toolbarWindow == nil else { return }
        isShuttingDown = false
        DiagLog.log("Annotation", "showToolbar")
        startGlobalMonitor()
        buildToolbar()
        buildDrawingWindow()
    }

    func hideToolbar() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        DiagLog.log("Annotation", "hideToolbar begin")
        stopGlobalMonitor()
        if let dw = drawingWindow {
            DiagLog.log("Annotation", "closing drawingWindow")
            dw.orderOut(nil)
            dw.close()
            drawingWindow = nil
            DiagLog.log("Annotation", "drawingWindow closed")
        }
        if let tw = toolbarWindow {
            DiagLog.log("Annotation", "closing toolbarWindow")
            tw.orderOut(nil)
            tw.close()
            toolbarWindow = nil
            DiagLog.log("Annotation", "toolbarWindow closed")
        }
        tool = .none
        strokes.removeAll()
        currentStroke.removeAll()
        DiagLog.log("Annotation", "hideToolbar end")
    }

    private func buildToolbar() {
        let w = NSWindow(
            contentRect: NSRect(x: 200, y: 100, width: 156, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.isReleasedWhenClosed = false

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: 156, height: 48))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 22
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor

        let pen = makeToolButton(symbol: "pencil", action: #selector(togglePen), frame: NSRect(x: 10, y: 8, width: 40, height: 32))
        pen.toolTip = "画笔"
        self.penBtn = pen

        let div1 = makeDivider(x: 54)
        pill.addSubview(div1)

        let eraser = makeToolButton(symbol: "eraser", action: #selector(toggleEraser), frame: NSRect(x: 60, y: 8, width: 40, height: 32))
        eraser.toolTip = "橡皮擦"
        self.eraserBtn = eraser

        let div2 = makeDivider(x: 104)
        pill.addSubview(div2)

        let clear = makeToolButton(symbol: "trash", action: #selector(clearAll), frame: NSRect(x: 110, y: 8, width: 40, height: 32))
        clear.toolTip = "清空批注"

        pill.addSubview(pen)
        pill.addSubview(eraser)
        pill.addSubview(clear)

        w.contentView?.addSubview(pill)
        w.orderFront(nil)
        toolbarWindow = w
        updateButtonStates()
        DiagLog.log("Annotation", "toolbar built")
    }

    private func buildDrawingWindow() {
        guard drawingWindow == nil, let screen = NSScreen.main else {
            DiagLog.log("Annotation", "buildDrawingWindow skip: dw=\(drawingWindow != nil) screen=\(NSScreen.main != nil)")
            return
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let drawView = AnnotationView(frame: screen.frame)
        drawView.drawCallback = { [weak self] ctx, rect in self?.drawStrokes(in: ctx, rect: rect) }
        w.contentView = drawView
        w.orderFront(nil)
        drawingWindow = w
        DiagLog.log("Annotation", "drawingWindow built")
    }

    private func updateButtonStates() {
        penBtn?.layer?.backgroundColor = (tool == .pen ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.2)).cgColor
        eraserBtn?.layer?.backgroundColor = (tool == .eraser ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.2)).cgColor
    }

    @objc private func togglePen() {
        tool = (tool == .pen) ? .none : .pen
        updateButtonStates()
        DiagLog.log("Annotation", "togglePen → \(tool)")
    }

    @objc private func toggleEraser() {
        tool = (tool == .eraser) ? .none : .eraser
        updateButtonStates()
        DiagLog.log("Annotation", "toggleEraser → \(tool)")
    }

    @objc func clearAll() {
        strokes.removeAll()
        currentStroke.removeAll()
        drawingWindow?.contentView?.needsDisplay = true
        DiagLog.log("Annotation", "clearAll strokes=\(strokes.count)")
    }

    private func startGlobalMonitor() {
        DiagLog.log("Annotation", "startGlobalMonitor")
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, !self.isShuttingDown, self.tool != .none else { return }
            let point = NSEvent.mouseLocation

            switch event.type {
            case .leftMouseDown:
                self.currentStroke = [point]
            case .leftMouseDragged:
                self.currentStroke.append(point)
                if self.tool == .pen {
                    self.strokes.append(self.currentStroke)
                    self.currentStroke = [point]
                }
                self.drawingWindow?.contentView?.needsDisplay = true
            case .leftMouseUp:
                if !self.currentStroke.isEmpty { self.strokes.append(self.currentStroke); self.currentStroke = [] }
                if self.tool == .eraser { self.eraseNear(point) }
                self.drawingWindow?.contentView?.needsDisplay = true
            default: break
            }
        }
    }

    private func stopGlobalMonitor() {
        DiagLog.log("Annotation", "stopGlobalMonitor")
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func eraseNear(_ point: CGPoint) {
        strokes.removeAll { stroke in
            stroke.contains { abs($0.x - point.x) < 20 && abs($0.y - point.y) < 20 }
        }
    }

    func drawStrokes(in ctx: CGContext, rect: CGRect) {
        guard !strokes.isEmpty else { return }
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.first else { continue }
            ctx.beginPath()
            ctx.move(to: first)
            for p in stroke.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
    }

    private func makeToolButton(symbol: String, action: Selector, frame: NSRect) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.title = ""
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 16
        btn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        btn.image = img?.withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeDivider(x: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: 12, width: 1, height: 24))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        return v
    }
}

private final class AnnotationView: NSView {
    var drawCallback: ((CGContext, CGRect) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCallback?(ctx, bounds)
    }
}
