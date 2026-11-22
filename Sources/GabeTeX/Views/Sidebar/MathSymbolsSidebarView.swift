import SwiftUI
import EditorKit

/// Categorized LaTeX math symbols palette in the left sidebar with click and drag-and-drop insertion.
struct MathSymbolsSidebarView: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @LocalState private var searchText = ""
    @LocalState private var collapsed: Set<String> = []
    @LocalState private var hovered: MathSymbol?

    private let columns = [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 4)]

    var body: some View {
        let categories = MathSymbolsCatalog.filtered(query: searchText)
        let searching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let accent = settings.accentSwiftUIColor

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(categories) { category in
                    CategorySection(
                        category: category,
                        accentColor: accent,
                        isExpanded: searching || !collapsed.contains(category.id),
                        toggle: {
                            guard !searching else { return }
                            if collapsed.contains(category.id) {
                                collapsed.remove(category.id)
                            } else {
                                collapsed.insert(category.id)
                            }
                        },
                        columns: columns,
                        onHoverSymbol: { hovered = $0 },
                        onInsert: insert
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .overlay {
            if categories.isEmpty {
                ContentUnavailableView {
                    Label("No matching symbols", systemImage: "sum")
                } description: {
                    Text("Try another LaTeX command or symbol name.")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search math symbols…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PreviewFooter(symbol: hovered, accentColor: accent)
        }
    }

    private func insert(_ symbol: MathSymbol) {
        hovered = symbol
        workspace.editor.insertMathSymbol(symbol.insertionText, package: symbol.pkg, textMode: symbol.textMode)
    }
}

private struct CategorySection: View {
    let category: MathSymbolCategory
    let accentColor: Color
    let isExpanded: Bool
    let toggle: () -> Void
    let columns: [GridItem]
    let onHoverSymbol: (MathSymbol) -> Void
    let onInsert: (MathSymbol) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(category.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 18)
                    Text(LocalizedStringKey(category.titleKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(category.symbols.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(category.symbols) { symbol in
                        SymbolTile(symbol: symbol, accentColor: accentColor, onHoverSymbol: onHoverSymbol, onInsert: onInsert)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }
}

private func isQuoteDisplay(_ display: String) -> Bool {
    display.contains { "“”‘’".contains($0) }
}

private struct SymbolTile: View {
    let symbol: MathSymbol
    let accentColor: Color
    let onHoverSymbol: (MathSymbol) -> Void
    let onInsert: (MathSymbol) -> Void

    var body: some View {
        Button {
            onInsert(symbol)
        } label: {
            Text(symbol.display)
                .font(
                    isQuoteDisplay(symbol.display)
                        ? .system(size: 21, design: .serif)
                        : (symbol.display.count >= 3 ? .caption.monospaced() : .body)
                )
                .padding(.top, isQuoteDisplay(symbol.display) ? 5 : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { onHoverSymbol(symbol) }
        }
        .onDrag {
            let provider = NSItemProvider(object: symbol.code as NSString)
            let payload = MathSymbolDragPayload(snippet: symbol.insertionText, pkg: symbol.pkg, textMode: symbol.textMode)
            let data = (try? JSONEncoder().encode(payload)) ?? Data(symbol.insertionText.utf8)
            provider.registerDataRepresentation(
                forTypeIdentifier: LaTeXTextView.mathSymbolPasteboardType.rawValue,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        } preview: {
            HStack(spacing: 6) {
                Text(symbol.display)
                    .font(isQuoteDisplay(symbol.display) ? .system(size: 20, design: .serif) : .body)
                Text(symbol.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        }
        .help(tooltipText)
        .accessibilityLabel("\(symbol.name) (\(symbol.code))")
    }

    private var tooltipText: String {
        if let pkg = symbol.pkg {
            return "\(symbol.code) — \(symbol.name) (\\usepackage{\(pkg)})"
        }
        return "\(symbol.code) — \(symbol.name)"
    }
}

private struct PreviewFooter: View {
    let symbol: MathSymbol?
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(symbol?.display ?? "α")
                .font(isQuoteDisplay(symbol?.display ?? "") ? .system(size: 21, design: .serif) : .title3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, isQuoteDisplay(symbol?.display ?? "") ? 4 : 0)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(symbol?.code ?? "\\alpha")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                    if let pkg = symbol?.pkg {
                        Text("\\usepackage{\(pkg)}")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let symbol {
                    Text(symbol.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Click to insert at cursor or drag into the editor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
