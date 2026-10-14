import AppKit
import SwiftUI

struct WorkspaceEditorView: View {
    let state: AppState
    @Bindable var nav: SettingsNavigation

    private var manager: WorkspaceManager { state.workspaces }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $nav.selectedWorkspace) {
                    ForEach(manager.workspaces) { workspace in
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: workspace.colorHex).gradient).frame(width: 12, height: 12)
                            Text(workspace.name).lineLimit(1)
                            Spacer()
                            if let slot = workspace.hotkeyIndex, let text = HotkeyController.workspaceShortcutText(slot) {
                                Text(text).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                            }
                        }
                        .tag(workspace.id)
                    }
                    .onMove { manager.move(from: $0, to: $1) }
                }
                Divider()
                HStack(spacing: 2) {
                    Button {
                        state.saveCurrentAsWorkspace()
                    } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("Save current windows as a new workspace")
                    Button {
                        if let id = nav.selectedWorkspace { manager.delete(id); nav.selectedWorkspace = nil }
                    } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                    .disabled(nav.selectedWorkspace == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let id = nav.selectedWorkspace, let workspace = manager.workspace(id) {
                    WorkspaceDetail(state: state, workspace: workspace)
                        .id(workspace.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(manager.workspaces.isEmpty ? "No workspaces yet" : "Select a workspace").font(.headline)
                        Text("Arrange your windows for a project, then click + (or press ⌥⇧W).\nRestore the whole layout with one click or ⌥1…⌥9.")
                            .multilineTextAlignment(.center).font(.caption).foregroundStyle(.secondary)
                        Button("Save Current Windows") { state.saveCurrentAsWorkspace() }
                            .buttonStyle(.borderedProminent).tint(Brand.red)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if nav.selectedWorkspace == nil { nav.selectedWorkspace = manager.workspaces.first?.id }
        }
    }
}

private struct WorkspaceDetail: View {
    let state: AppState
    @State var workspace: Workspace

    private var manager: WorkspaceManager { state.workspaces }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $workspace.name)
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        ForEach(Workspace.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex).gradient)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: workspace.colorHex == hex ? 2 : 0).padding(-3))
                                .onTapGesture { workspace.colorHex = hex }
                        }
                    }
                }
                Picker("Hotkey slot", selection: $workspace.hotkeyIndex) {
                    Text("None").tag(Int?.none)
                    ForEach(1...9, id: \.self) { slot in
                        Text(HotkeyController.workspaceShortcutText(slot).map { "\(slot)  —  \($0)" } ?? "\(slot)").tag(Int?.some(slot))
                    }
                }
                Picker("On restore", selection: $workspace.layout) {
                    Text("Use saved positions").tag(LayoutPreset?.none)
                    ForEach(LayoutPreset.allCases) { preset in
                        Label("Tile: \(preset.title)", systemImage: preset.symbol).tag(LayoutPreset?.some(preset))
                    }
                }
            }

            Section {
                if workspace.items.isEmpty {
                    Text("No windows. Use “Update from Current Windows” or drag a thumbnail onto this workspace's chip in the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                List {
                    ForEach($workspace.items) { $item in
                        ItemRow(item: $item) {
                            workspace.items.removeAll { $0.id == item.id }
                        }
                    }
                    .onMove { workspace.items.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: CGFloat(max(workspace.items.count, 1)) * 58)
            } header: {
                Text("Windows (\(workspace.items.count)) — first one ends up focused")
            }

            Section {
                HStack {
                    Button("Restore Now") { state.restoreWorkspace(workspace.id) }
                        .buttonStyle(.borderedProminent).tint(Brand.red)
                    Button("Update from Current Windows") { state.updateWorkspaceWithCurrentWindows(workspace.id) }
                    Spacer()
                    Button("Delete", role: .destructive) { manager.delete(workspace.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: workspace) { manager.update(workspace) }
        .onChange(of: manager.workspace(workspace.id)) { _, latest in
            // Picks up edits made elsewhere (sidebar drops, "Update from current").
            if let latest, latest != workspace { workspace = latest }
        }
    }
}

private struct ItemRow: View {
    @Binding var item: WorkspaceItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = AppIconCache.icon(bundleID: item.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.appName ?? item.bundleID).font(.system(size: 13, weight: .medium))
                TextField("Title contains (optional)", text: Binding(
                    get: { item.titleContains ?? "" },
                    set: { item.titleContains = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            }
            FramePreview(rect: item.relativeFrame)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

/// Where the window sits on its screen.
private struct FramePreview: View {
    let rect: CGRect

    var body: some View {
        let size = CGSize(width: 48, height: 30)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 2)
                .fill(Brand.red.opacity(0.8))
                .frame(width: max(rect.width * size.width, 3), height: max(rect.height * size.height, 3))
                .offset(x: rect.minX * size.width, y: rect.minY * size.height)
        }
        .frame(width: size.width, height: size.height)
    }
}
