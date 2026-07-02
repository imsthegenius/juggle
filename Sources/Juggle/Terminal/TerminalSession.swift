import AppKit
import GhosttyTerminal
import QuartzCore

/// One live terminal: a real Ghostty surface running a shell via the `.exec`
/// backend (libghostty owns the PTY). Acts as the surface delegate, translating
/// engine signals into `AttentionState` changes the window can render.
@MainActor
final class TerminalSession: TerminalSurfaceTitleDelegate,
                             TerminalSurfaceGridResizeDelegate,
                             TerminalSurfaceBellDelegate,
                             TerminalSurfaceCommandFinishedDelegate,
                             TerminalSurfaceDesktopNotificationDelegate,
                             TerminalSurfaceProgressReportDelegate,
                             TerminalSurfacePwdDelegate,
                             TerminalSurfaceFocusDelegate,
                             TerminalSurfaceCloseDelegate {
    let context: SessionContext
    let view: NSView

    var onAttentionChange: ((AttentionState) -> Void)?
    var onTitleChange: ((String) -> Void)?

    private let terminalView: AppTerminalView
    private let controller: TerminalController
    private let detector = StateDetector()
    private var latestGridMetrics: TerminalGridMetrics?

    init(context: SessionContext, controllers: RepoControllerRegistry) {
        self.context = context
        self.controller = controllers.controller(forKey: context.projectId)

        let terminalView = AppTerminalView(frame: .zero)
        terminalView.controller = controller
        terminalView.wantsLayer = true
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: context.cwd
        )
        self.terminalView = terminalView
        self.view = terminalView

        terminalView.delegate = self
        applyAppearance(context)
        detector.onChange = { [weak self] state in
            self?.onAttentionChange?(state)
        }
    }

    var attentionState: AttentionState { detector.state }

    func clearAttention() {
        detector.clear()
    }

    func applyAppearance(_ context: SessionContext) {
        terminalView.layer?.backgroundColor = TerminalTheming.backgroundColor(named: context.terminalThemeName).cgColor
    }

    func diagnosticReport(window: NSWindow?) -> String {
        var lines: [String] = []
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 0
        lines.append("terminal.view.bounds=\(format(terminalView.bounds))")
        lines.append("terminal.view.frame=\(format(terminalView.frame))")
        lines.append("window.backingScaleFactor=\(String(format: "%.2f", scale))")
        lines.append("expected.pixelSize=\(String(format: "%.0f", terminalView.bounds.width * scale))x\(String(format: "%.0f", terminalView.bounds.height * scale))")
        if let metrics = latestGridMetrics {
            lines.append("ghostty.grid=\(metrics.columns)x\(metrics.rows)")
            lines.append("ghostty.surfacePixels=\(metrics.widthPixels)x\(metrics.heightPixels)")
            lines.append("ghostty.cellPixels=\(metrics.cellWidthPixels)x\(metrics.cellHeightPixels)")
        } else {
            lines.append("ghostty.grid=nil")
        }
        lines.append("ghostty.renderedConfig<<EOF")
        lines.append(controller.renderedConfig.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("EOF")
        if let layer = terminalView.layer {
            lines.append(contentsOf: describe(layer: layer, label: "rootLayer", depth: 0))
        } else {
            lines.append("rootLayer=nil")
        }
        return lines.joined(separator: "\n")
    }

    private func describe(layer: CALayer, label: String, depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = [
            "\(indent)\(label).type=\(String(describing: type(of: layer)))",
            "\(indent)\(label).frame=\(format(layer.frame))",
            "\(indent)\(label).bounds=\(format(layer.bounds))",
            "\(indent)\(label).contentsScale=\(String(format: "%.2f", layer.contentsScale))",
            "\(indent)\(label).contentsGravity=\(layer.contentsGravity.rawValue)",
            "\(indent)\(label).minificationFilter=\(layer.minificationFilter.rawValue)",
            "\(indent)\(label).magnificationFilter=\(layer.magnificationFilter.rawValue)",
        ]
        if let metal = layer as? CAMetalLayer {
            lines.append("\(indent)\(label).drawableSize=\(String(format: "%.0f", metal.drawableSize.width))x\(String(format: "%.0f", metal.drawableSize.height))")
        }
        for (index, sublayer) in (layer.sublayers ?? []).enumerated() {
            lines.append(contentsOf: describe(layer: sublayer, label: "\(label).sublayer[\(index)]", depth: depth + 1))
        }
        return lines
    }

    private func format(_ rect: CGRect) -> String {
        "\(String(format: "%.1f", rect.origin.x)),\(String(format: "%.1f", rect.origin.y)) \(String(format: "%.1f", rect.width))x\(String(format: "%.1f", rect.height))"
    }

    // MARK: - TerminalSurfaceViewDelegate family

    func terminalDidResize(_ size: TerminalGridMetrics) {
        latestGridMetrics = size
    }

    func terminalDidChangeTitle(_ title: String) { onTitleChange?(title) }
    func terminalDidRingBell() { detector.ingest(.bell) }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        detector.ingest(.commandFinished(exitCode: exitCode, durationNanos: durationNanos))
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        detector.ingest(.desktopNotification(title: title, body: body))
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        if case .error = state { detector.ingest(.progressError) }
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {}
    func terminalDidChangeFocus(_ focused: Bool) { if focused { detector.ingest(.focused) } }
    func terminalDidClose(processAlive: Bool) {}
}
