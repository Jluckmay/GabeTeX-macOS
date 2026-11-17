import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Zotero local API models & client

nonisolated struct ZoteroCreator: Codable, Sendable, Hashable {
    var creatorType: String
    var firstName: String?
    var lastName: String?
}

nonisolated struct ZoteroItem: Codable, Sendable, Identifiable, Hashable {
    var key: String
    var itemType: String
    var title: String?
    var creators: [ZoteroCreator]?
    var date: String?
    var collections: [String]?

    var id: String { key }
}

nonisolated struct ZoteroCollection: Codable, Sendable, Identifiable, Hashable {
    var key: String
    var name: String
    var parentCollection: String?

    var id: String { key }
}

nonisolated struct ZoteroExportResult: Sendable {
    var ok: Bool
    var bibtex: String
    var error: String?
}

nonisolated enum ZoteroClient {
    private static let baseURL = "http://localhost:23119"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func status() async -> Bool {
        guard let url = URL(string: "\(baseURL)/") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static func collections() async throws -> [ZoteroCollection] {
        try await fetchJSON(path: "/collections")
    }

    static func items(collectionKey: String?) async throws -> [ZoteroItem] {
        if let collectionKey {
            guard isValidKey(collectionKey) else {
                throw ZoteroError.message("Invalid Zotero collection key: \(collectionKey)")
            }
            return try await fetchJSON(path: "/collections/\(collectionKey)/items")
        }
        return try await fetchJSON(path: "/items")
    }

    static func exportBib(keys: [String]) async throws -> ZoteroExportResult {
        for key in keys where !isValidKey(key) {
            throw ZoteroError.message("Invalid Zotero item key: \(key)")
        }
        var bibtex = ""
        var errors: [String] = []

        for key in keys {
            guard let url = URL(string: "\(baseURL)/items/\(key)/export?format=bibtex") else {
                errors.append("\(key): invalid URL")
                continue
            }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    errors.append("\(key): invalid response")
                    continue
                }
                if (200..<300).contains(http.statusCode) {
                    if let text = String(data: data, encoding: .utf8) {
                        bibtex += text
                        if !bibtex.hasSuffix("\n") { bibtex += "\n" }
                    } else {
                        errors.append("\(key): could not decode response")
                    }
                } else {
                    errors.append("\(key): HTTP \(http.statusCode)")
                }
            } catch {
                errors.append("\(key): \(error.localizedDescription)")
            }
        }

        if errors.isEmpty {
            return ZoteroExportResult(ok: true, bibtex: bibtex, error: nil)
        } else if bibtex.isEmpty {
            return ZoteroExportResult(ok: false, bibtex: "", error: errors.joined(separator: "; "))
        } else {
            return ZoteroExportResult(ok: true, bibtex: bibtex, error: errors.joined(separator: "; "))
        }
    }

    private static func fetchJSON<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw ZoteroError.message("Invalid Zotero URL")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ZoteroError.message("Could not reach Zotero at \(url.absoluteString) (HTTP \(status))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private enum ZoteroError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }
}

// MARK: - Settings Pane

/// Zotero local API browser and BibTeX exporter.
struct ZoteroSettingsView: View {
    @LocalState private var isConnected = false
    @LocalState private var isLoading = false
    @LocalState private var collections: [ZoteroCollection] = []
    @LocalState private var items: [ZoteroItem] = []
    @LocalState private var selectedCollectionKey: String?
    @LocalState private var selectedKeys: Set<String> = []
    @LocalState private var bibtexText = ""
    @LocalState private var errorTitle: String?
    @LocalState private var errorMessage: String?

    var body: some View {
        Form {
            statusSection
            if isConnected {
                collectionsSection
                itemsSection
                exportSection
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .alert(errorTitle ?? "", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil; errorTitle = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Zotero status") {
                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not connected", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            if isConnected {
                Text("Zotero local API is reachable at http://localhost:23119.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Make sure Zotero is running and the local API is enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let docsURL = URL(string: "https://www.zotero.org/support/kb/web_api/") {
                Link("Zotero Web API docs", destination: docsURL)
            }
        } header: {
            HStack {
                Text("Zotero")
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.link)
                .disabled(isLoading)
            }
        } footer: {
            Text("Connect to Zotero’s local API to browse your library and export citations as BibTeX. Save the .bib file in your project and reference it with \\bibliography{zotero} or \\addbibresource{zotero.bib}.")
        }
    }

    private var collectionsSection: some View {
        Section("Collections") {
            if collections.isEmpty {
                Text("No collections found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(collections) { collection in
                    Button {
                        Task { await loadItems(collectionKey: collection.key) }
                    } label: {
                        HStack {
                            Text(collection.name)
                            Spacer()
                            if selectedCollectionKey == collection.key {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var itemsSection: some View {
        Section("Items") {
            if items.isEmpty {
                Text("No items found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Toggle(isOn: Binding(
                        get: { selectedKeys.contains(item.key) },
                        set: { selected in
                            if selected { selectedKeys.insert(item.key) }
                            else { selectedKeys.remove(item.key) }
                        }
                    )) {
                        Text(itemSummary(item))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            LabeledContent("Selected items") {
                Text("\(selectedKeys.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Export to BibTeX") {
                    Task { await exportSelected() }
                }
                .disabled(selectedKeys.isEmpty || isLoading)
                Button("Save zotero.bib…") {
                    saveBibTeX()
                }
                .disabled(bibtexText.isEmpty)
            }
            ScrollView {
                if bibtexText.isEmpty {
                    Text("No BibTeX exported yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    Text(verbatim: bibtexText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .frame(minHeight: 110, maxHeight: 180)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func itemSummary(_ item: ZoteroItem) -> String {
        let authors = (item.creators ?? [])
            .filter { $0.creatorType == "author" }
            .map { [$0.firstName, $0.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let parts = [authors, item.date, item.title].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? item.key : "\(item.key) — \(parts.joined(separator: " — "))"
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let ok = await ZoteroClient.status()
        isConnected = ok
        guard ok else {
            collections = []
            items = []
            selectedCollectionKey = nil
            selectedKeys.removeAll()
            return
        }
        do {
            collections = try await ZoteroClient.collections()
        } catch {
            errorTitle = String(localized: "Error")
            errorMessage = error.localizedDescription
        }
    }

    private func loadItems(collectionKey: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await ZoteroClient.items(collectionKey: collectionKey)
            selectedCollectionKey = collectionKey
            selectedKeys.removeAll()
        } catch {
            errorTitle = String(localized: "Error")
            errorMessage = error.localizedDescription
        }
    }

    private func exportSelected() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await ZoteroClient.exportBib(keys: Array(selectedKeys).sorted())
            if result.ok {
                bibtexText = result.bibtex
            } else {
                errorTitle = String(localized: "Export failed")
                errorMessage = result.error ?? String(localized: "Unknown error")
            }
        } catch {
            errorTitle = String(localized: "Error")
            errorMessage = error.localizedDescription
        }
    }

    private func saveBibTeX() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "zotero.bib"
        panel.canCreateDirectories = true
        if let bibType = UTType(filenameExtension: "bib") {
            panel.allowedContentTypes = [bibType, .plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try bibtexText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorTitle = String(localized: "Error")
                errorMessage = error.localizedDescription
            }
        }
    }
}
