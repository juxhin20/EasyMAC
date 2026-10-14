import AppKit
import SwiftUI

struct ThumbnailCell: View {
    let window: WindowInfo
    let image: NSImage?
    let metrics: SidebarMetrics
    let isHovered: Bool
    let isSelected: Bool
    let accent: Color

    private var icon: NSImage? { AppIconCache.icon(pid: window.pid) }

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
            if metrics.showTitles {
                Text(window.displayTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.thumbWidth, height: 12)
            }
        }
        .frame(width: metrics.thumbWidth, height: metrics.cellHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.appName): \(window.displayTitle)")
        .accessibilityAddTraits(.isButton)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.22))

            if let image, !window.isOffscreen || image.size.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.thumbHeight * 0.55, height: metrics.thumbHeight * 0.55)
            }
        }
        .frame(width: metrics.thumbWidth, height: metrics.thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if image != nil, let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if window.isOffscreen {
                Image(systemName: window.isMinimized ? "arrow.down.right.and.arrow.up.left" : "eye.slash")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .padding(3)
            }
        }
        .overlay(alignment: .topLeading) {
            if window.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(accent))
                    .padding(3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ringColor, lineWidth: ringWidth)
        }
        .opacity(window.isOffscreen ? 0.55 : 1)
        .saturation(window.isOffscreen ? 0.4 : 1)
        .scaleEffect(isHovered ? 1.045 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 6 : 2, y: isHovered ? 3 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var ringColor: Color {
        if isSelected { return accent }
        if window.isActive { return accent.opacity(0.9) }
        if isHovered { return Color.white.opacity(0.45) }
        return Color.white.opacity(0.08)
    }

    private var ringWidth: CGFloat {
        if isSelected { return 3 }
        if window.isActive { return 2 }
        return isHovered ? 1.5 : 0.5
    }
}

struct WorkspaceChip: View {
    let workspace: Workspace
    let isTargeted: Bool
    let isRestoring: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: workspace.colorHex).gradient)
            Text(workspace.initials)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
            if isRestoring {
                Circle().strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        .frame(width: SidebarMetrics.chip, height: SidebarMetrics.chip)
        .scaleEffect(isTargeted ? 1.25 : 1)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isTargeted)
        .help(workspace.hotkeyIndex.map { "\(workspace.name)  ⌥\($0)" } ?? workspace.name)
    }
}
