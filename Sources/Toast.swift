import AppKit

/// A small pop-up under the menu-bar icon. Used instead of system notifications,
/// which macOS doesn't allow for a self-built (unsigned) app. Click it to dismiss.
final class Toast: NSObject {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, body: String, near button: NSStatusBarButton?, seconds: TimeInterval = 7) {
        dismiss(animated: false)
        let width: CGFloat = 340

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .boldSystemFont(ofSize: 13)
        let bodyField = NSTextField(wrappingLabelWithString: body)
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.textColor = .secondaryLabelColor
        bodyField.preferredMaxLayoutWidth = width - 32
        let stack = NSStackView(views: [titleField, bodyField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        let height = ceil(stack.fittingSize.height)
        container.setFrameSize(NSSize(width: width, height: height))
        container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        let screen = button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: visible.maxX - width - 12, y: visible.maxY - height - 8)
        if let f = button?.window?.frame {
            origin.x = min(max(f.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
            origin.y = f.minY - height - 6
        }

        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = container
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p

        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func clicked() { dismiss(animated: true) }

    func dismiss(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        guard let p = panel else { return }
        panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        } else {
            p.orderOut(nil)
        }
    }
}
