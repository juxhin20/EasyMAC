import AppKit
import SwiftUI

struct SidebarView: View {
    let state: AppState
    let model: SidebarModel

    private var settings: Settings { state.settings }
    private var metrics: SidebarMetrics {
        SidebarMetrics(thumbWidth: settings.thumbnailSize.width, showTitles: settings.showTitles, showFooter: settings.showFooter,
                       spaceCount: settings.showSpaces ? state.spaces.spaces.count : 0)
    }
    private var accent: Color { Color(nsColor: settings.sidebarAccent.nsColor) }

    var body: some View {
        let windows = SidebarModel.displayed(state.windows.windows, max: settings.maxVisible)
        VStack(spacing: 0) {
            Color.clear.frame(height: SidebarMetrics.headerTop)
            chips
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: metrics.thumbWidth * 0.6, height: 1)
                .frame(height: SidebarMetrics.dividerBlock)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: SidebarMetrics.spacing) {
                    if windows.isEmpty {
                        emptyState
                    }
                    ForEach(windows) { window in
                        cell(window)
                    }
                }
                .padding(.vertical, SidebarMetrics.spacing / 2)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            if metrics.spaceCount > 0 {
                spacesRow
            }
            if settings.showFooter {
                footer
            } else {
                Color.clear.frame(height: SidebarMetrics.padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: SidebarMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .coordinateSpace(name: "sidebar")
        .onPreferenceChange(CellFramesKey.self) { frames in
            MainActor.assumeIsolated {
                model.cellFrames = frames
                model.updateHover()
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: windows.map(\.windowID))
    }

    // MARK: - Pieces

    private var chips: some View {
        let columns = Array(repeating: GridItem(.fixed(SidebarMetrics.chip), spacing: SidebarMetrics.chipSpacing), count: metrics.chipsPerRow)
        return LazyVGrid(columns: columns, spacing: SidebarMetrics.chipSpacing) {
            ForEach(state.workspaces.workspaces) { workspace in
                WorkspaceChip(workspace: workspace,
                              isTargeted: model.dropTargetWorkspace == workspace.id,
                              isRestoring: state.workspaces.restoringID == workspace.id)
                    .onTapGesture { state.restoreWorkspace(workspace.id) }
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.compactMap { UInt32($0) }
                        for id in ids { state.addWindow(id, toWorkspace: workspace.id) }
                        return !ids.isEmpty
                    } isTargeted: { targeted in
                        model.dropTargetWorkspace = targeted ? workspace.id : (model.dropTargetWorkspace == workspace.id ? nil : model.dropTargetWorkspace)
                    }
                    .contextMenu { chipMenu(workspace) }
            }
            Button {
                state.saveCurrentAsWorkspace()
            } label: {
                ZStack {
                    Circle().strokeBorder(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
                .frame(width: SidebarMetrics.chip, height: SidebarMetrics.chip)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Save current windows as a workspace")
        }
        .frame(width: metrics.thumbWidth)
    }

    @ViewBuilder
    private func chipMenu(_ workspace: Workspace) -> some View {
        Button("Restore “\(workspace.name)”") { state.restoreWorkspace(workspace.id) }
        Button("Update with Current Windows") { state.updateWorkspaceWithCurrentWindows(workspace.id) }
        Button("Edit…") { state.openSettings(.workspaces, workspace: workspace.id) }
        Divider()
        Button("Delete", role: .destructive) { state.workspaces.delete(workspace.id) }
    }

    private func cell(_ window: WindowInfo) -> some View {
        ThumbnailCell(
            window: window,
            box: settings.showThumbnails ? state.thumbnails.box(window.windowID) : nil,
            metrics: metrics,
            isHovered: model.hoveredID == window.windowID,
            isSelected: model.selectionID == window.windowID,
            accent: accent
        )
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CellFramesKey.self, value: [window.windowID: proxy.frame(in: .named("sidebar"))])
        })
        .onTapGesture { state.focus(window) }
        .draggable(String(window.windowID)) {
            ThumbnailCell(window: window, box: state.thumbnails.box(window.windowID), metrics: metrics,
                          isHovered: false, isSelected: false, accent: accent)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.compactMap({ UInt32($0) }).first, id != window.windowID else { return false }
            // Dropping onto a pinned window reorders pins; onto any other window pins above it.
            if !window.isPinned { state.windows.togglePin(window.windowID) }
            state.windows.movePinned(id, before: window.windowID)
            return true
        }
        .contextMenu { WindowContextMenu(state: state, window: window) }
        .transition(.asymmetric(insertion: .scale(scale: 0.8).combined(with: .opacity), removal: .opacity))
    }

    /// Small numbered desktops; the current one is filled with the accent. Click to switch.
    private var spacesRow: some View {
        let columns = Array(repeating: GridItem(.fixed(SidebarMetrics.chip), spacing: SidebarMetrics.chipSpacing), count: metrics.chipsPerRow)
        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: metrics.thumbWidth * 0.6, height: 1)
                .frame(height: SidebarMetrics.dividerBlock)
            LazyVGrid(columns: columns, spacing: SidebarMetrics.chipSpacing) {
                ForEach(state.spaces.spaces) { space in
                    let current = space.id == state.spaces.currentID
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(current ? accent : Color.primary.opacity(0.10))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(current ? 0 : 0.18), lineWidth: 0.5)
                        if space.isFullscreen {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 7, weight: .bold))
                        } else {
                            Text("\(space.index)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(current ? Color.white : Color.secondary)
                    .frame(width: SidebarMetrics.chip, height: SidebarMetrics.space)
                    .contentShape(Rectangle())
                    .onTapGesture { state.spaces.switchTo(space) }
                    .help(space.isFullscreen ? "Fullscreen app" : "Desktop \(space.index)")
                    .animation(.easeOut(duration: 0.15), value: current)
                }
            }
            .frame(width: metrics.thumbWidth)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 16)).foregroundStyle(.secondary)
            Text("No windows").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: metrics.thumbWidth, height: metrics.cellHeight)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("EasyMAC")
                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Button {
                state.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("EasyMAC Settings")
        }
        .padding(.horizontal, SidebarMetrics.padding + 2)
        .frame(height: SidebarMetrics.footer)
    }
}

struct WindowContextMenu: View {
    let state: AppState
    let window: WindowInfo

    var body: some View {
        Button("Focus") { state.focus(window) }
        Menu("Add to Workspace") {
            ForEach(state.workspaces.workspaces) { workspace in
                Button(workspace.name) { state.addWindow(window.windowID, toWorkspace: workspace.id) }
            }
            if !state.workspaces.workspaces.isEmpty { Divider() }
            Button("New Workspace…") { state.createWorkspace(with: [window]) }
        }
        Button(window.isPinned ? "Unpin" : "Pin to Top") { state.windows.togglePin(window.windowID) }
        Divider()
        Button(window.isMinimized ? "Restore" : "Minimize") { state.toggleMinimize(window) }
        Button("Close Window") { state.close(window) }
        Divider()
        Button("Hide \(window.appName)") { state.hideApp(window) }
        Button("Quit \(window.appName)") { state.quitApp(window) }
    }
}
