import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class HoverPreviewModel {
    var window: WindowInfo?
}

struct HoverPreviewView: View {
    let model: HoverPreviewModel
    let thumbnails: ThumbnailService

    var body: some View {
        if let window = model.window {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
                    if let image = (thumbnails.hoverImageID == window.windowID ? thumbnails.hoverImage : nil) ?? thumbnails.thumbnails[window.windowID] {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else if let icon = AppIconCache.icon(pid: window.pid) {
                        Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 8) {
                    if let icon = AppIconCache.icon(pid: window.pid) {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(window.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text(window.appName)
                            if let state = window.stateLabel {
                                Text("·")
                                Text(state)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
        }
    }
}

/// Large preview shown beside the strip while hovering a thumbnail.
@MainActor
final class HoverPreviewController {
    private let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), ignoresMouse: true)
    private let model = HoverPreviewModel()
    private let thumbnails: ThumbnailService
    private var style: PanelStyle?
    private(set) var isVisible = false

    init(thumbnails: ThumbnailService) {
        self.thumbnails = thumbnails
    }

    private func ensureContent() {
        let style = Settings.shared.panelStyle
        guard style != self.style else { return }
        self.style = style
        let host = NSHostingView(rootView: AnyView(HoverPreviewView(model: model, thumbnails: thumbnails)))
        panel.contentView = PanelBackground.make(style: style, cornerRadius: 14, content: host)
    }

    /// - Parameters:
    ///   - anchor: the hovered cell, in screen (AppKit) coordinates.
    ///   - stripFrame: the sidebar panel frame; the preview sits on its open side.
    func show(_ window: WindowInfo, anchor: CGRect, stripFrame: CGRect, edge: SidebarEdge, screen: NSScreen) {
        ensureContent()
        model.window = window
        let width: CGFloat = 480
        let aspect = window.frame.width > 0 ? window.frame.height / window.frame.width : 0.62
        let imageHeight = min(max(width * aspect, 180), 420)
        let size = CGSize(width: width, height: imageHeight + 58)
        let visible = screen.visibleFrame
        let x = edge == .left ? stripFrame.maxX + 10 : stripFrame.minX - 10 - size.width
        var y = anchor.midY - size.height / 2
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral

        if isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame.offsetBy(dx: edge == .left ? -8 : 8, dy: 0), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
            isVisible = true
        }
        panel.invalidateShadow()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.model.window = nil
            }
        })
    }

    func styleChanged() {
        style = nil
    }
}
