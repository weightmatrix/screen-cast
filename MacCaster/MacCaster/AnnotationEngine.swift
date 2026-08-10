import Foundation
import Combine
import AppKit
import CoreGraphics

final class AnnotationEngine: ObservableObject {
    enum Tool { case none, pen, eraser }

    @Published var tool: Tool = .none
    var isActive: Bool { tool != .none }

    private var strokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []
    private var drawingWindow: NSWindow?
    private var toolbarWindow: NSWindow?
    private var monitor: Any?

    func showToolbar() {
        if toolbarWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 140, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            w.level = .floating
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(0.7)
            w.hasShadow = true
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            let content = NSView(frame: w.contentView!.bounds)
            let penBtn = makeButton(title: "✏️", action: #selector(togglePen), x: 8, y: 6)
            penBtn.toolTip = "笔：点按开始，再按关闭批注"
            let eraserBtn = makeButton(title: "🧹", action: #selector(toggleEraser), x: 50, y: 6)
            eraserBtn.toolTip = "橡皮：点按开始，再按关闭批注"
            let clearBtn = makeButton(title: "×", action: #selector(clearAll), x: 92, y: 6)
            clearBtn.toolTip = "清空批注"

            content.addSubview(penBtn)
            content.addSubview(eraserBtn)
            content.addSubview(clearBtn)
            w.contentView = content
            w.orderFront(nil)
            toolbarWindow = w

            startGlobalMonitor()
        }
    }

    func hideToolbar() {
        toolbarWindow?.close()
        toolbarWindow = nil
        drawingWindow?.close()
        drawingWindow = nil
        stopGlobalMonitor()
    }

    @objc private func togglePen() {
        if tool == .pen { tool = .none } else { tool = .pen }
        updateDrawingWindow()
    }

    @objc private func toggleEraser() {
        if tool == .eraser { tool = .none } else { tool = .eraser }
        updateDrawingWindow()
    }

    @objc func clearAll() {
        strokes.removeAll()
        currentStroke.removeAll()
        drawingWindow?.contentView?.needsDisplay = true
    }

    private func updateDrawingWindow() {
        if tool != .none {
            ensureDrawingWindow()
            drawingWindow?.ignoresMouseEvents = false
        } else {
            drawingWindow?.ignoresMouseEvents = true
        }
    }

    func ensureDrawingWindow() {
        guard drawingWindow == nil, let screen = NSScreen.main else { return }
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = false
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let drawView = AnnotationView(frame: screen.frame)
        drawView.drawCallback = { [weak self] ctx, rect in
            self?.drawStrokes(in: ctx, rect: rect)
        }
        w.contentView = drawView
        w.orderFront(nil)
        drawingWindow = w
    }

    private func startGlobalMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.tool != .none else { return }
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
                if !self.currentStroke.isEmpty {
                    self.strokes.append(self.currentStroke)
                    self.currentStroke = []
                }
                if self.tool == .eraser {
                    self.eraseNear(point)
                }
                self.drawingWindow?.contentView?.needsDisplay = true
            default: break
            }
        }
    }

    private func stopGlobalMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func eraseNear(_ point: CGPoint) {
        strokes.removeAll { stroke in
            stroke.contains { abs($0.x - point.x) < 16 && abs($0.y - point.y) < 16 }
        }
    }

    func drawStrokes(in ctx: CGContext, rect: CGRect) {
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(3)
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

    private func makeButton(title: String, action: Selector, x: CGFloat, y: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: y, width: 36, height: 32))
        btn.title = title
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.font = NSFont.systemFont(ofSize: 16)
        btn.target = self
        btn.action = action
        return btn
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
