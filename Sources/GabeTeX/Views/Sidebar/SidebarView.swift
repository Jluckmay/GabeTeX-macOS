import SwiftUI

/// Sidebar: [Files | Outline] segmented control above the selected list.
struct SidebarView: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var lastTabMode: ProjectWorkspace.SidebarMode = .files

    var body: some View {
        @Bindable var workspace = workspace
        Group {
            switch workspace.sidebarMode {
            case .files: FileTreeView()
            case .outline: OutlineSidebarView()
            case .symbols: MathSymbolsSidebarView()
            }
        }
        .onChange(of: workspace.sidebarMode) { _, mode in
            if mode != .symbols { lastTabMode = mode }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                symbolsButton
                Picker("Sidebar", selection: segmentedSelection) {
                    Text("Files").tag(Optional(ProjectWorkspace.SidebarMode.files))
                    Text("Outline").tag(Optional(ProjectWorkspace.SidebarMode.outline))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var symbolsButton: some View {
        let active = workspace.sidebarMode == .symbols
        let button = Button {
            workspace.sidebarMode = active ? lastTabMode : .symbols
        } label: {
            Image(systemName: "sum")
        }
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help("Math Symbols")
        .accessibilityLabel("Math Symbols")

        if active {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var segmentedSelection: Binding<ProjectWorkspace.SidebarMode?> {
        Binding(
            get: { workspace.sidebarMode == .symbols ? nil : workspace.sidebarMode },
            set: { newValue in
                if let newValue {
                    workspace.sidebarMode = newValue
                }
            }
        )
    }
}
