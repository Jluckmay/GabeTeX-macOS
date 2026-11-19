import SwiftUI
import AppKit
import TeXToolchain
import VimKit
import EditorKit

/// Posts polite or high-priority VoiceOver announcements via `NSAccessibility`.
enum AccessibilityAnnouncer {
    static func post(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: AnyObject? = NSApp?.mainWindow ?? NSApp
        guard !trimmed.isEmpty, let element = target else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: priority.rawValue,
            ]
        )
    }
}

/// Compile state, issue counts, engine, distribution, Vim mode and caret position as glass capsules.
struct StatusBar: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(ToolchainModel.self) private var toolchain

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                CompileStateCapsule()
                IssueCountsCapsule()
                if let message = workspace.statusMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                if settings.vimMode { VimStatusCapsule(editor: workspace.editor) }
                if settings.useTectonicWasm {
                    capsule {
                        Text("Tectonic WASM")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Distribution")
                    .accessibilityValue(Text("Tectonic WASM"))
                } else {
                    capsule {
                        Text(workspace.effectiveEngine.displayName)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Engine")
                    .accessibilityValue(Text(workspace.effectiveEngine.displayName))
                    if let distribution = toolchain.distribution {
                        capsule {
                            Text(distribution.name)
                        }
                        .help(distribution.versionDescription ?? distribution.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Distribution")
                        .accessibilityValue(Text(distribution.name))
                    }
                }
                if let format = workspace.currentFile.flatMap({ workspace.formats[$0] }) {
                    capsule {
                        Text(verbatim: format.statusName)
                    }
                    .help("Text encoding of the current file")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Text encoding")
                    .accessibilityValue(Text(verbatim: format.statusName))
                }
                if workspace.mainFile != nil { StatisticsCapsule() }
                CursorCapsule(editor: workspace.editor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .animation(.smooth(duration: 0.2), value: workspace.statusMessage)
        .onChange(of: workspace.statusMessage) { _, message in
            if let message, !message.isEmpty {
                AccessibilityAnnouncer.post(message, priority: .medium)
            }
        }
        .accessibilityElement(children: .contain)
        // Keeps the word and page counts (capsule, popover, outline) up to date while the window is open.
        .task { await workspace.runStatisticsUpdates() }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct CompileStateCapsule: View {
    @Environment(ProjectWorkspace.self) private var workspace
    @LocalState private var lastCompileWasBuild = false
    @LocalState private var lastOutcomeHadError = false

    var body: some View {
        HStack(spacing: 6) {
            switch workspace.compileState {
            case .compiling:
                ProgressView().controlSize(.mini)
                Text("Compiling…")
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(durationText ?? String(localized: "Compiled"))
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Compiled with errors")
            case .toolError:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Cannot compile")
            case .idle:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if workspace.hasCompiled { Text("Stopped") } else { Text("Ready") }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular, in: .capsule)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compile status")
        .accessibilityValue(Text(verbatim: statusSummary))
        .onChange(of: workspace.compileState) { _, newState in
            announceStateChange(newState)
        }
    }

    private var statusSummary: String {
        switch workspace.compileState {
        case .compiling:
            return String(localized: "Compiling…")
        case .succeeded:
            return durationText ?? String(localized: "Compiled")
        case .failed:
            return String(localized: "Compiled with errors")
        case .toolError:
            return String(localized: "Cannot compile")
        case .idle:
            return workspace.hasCompiled ? String(localized: "Stopped") : String(localized: "Ready")
        }
    }

    private func announceStateChange(_ newState: ProjectWorkspace.CompileState) {
        switch newState {
        case .compiling(.build):
            lastCompileWasBuild = true
            AccessibilityAnnouncer.post(String(localized: "Compiling…"), priority: .medium)
        case .compiling(.live):
            lastCompileWasBuild = false
        case .succeeded:
            if lastCompileWasBuild || lastOutcomeHadError {
                AccessibilityAnnouncer.post(durationText ?? String(localized: "Compiled"), priority: .medium)
            }
            lastOutcomeHadError = false
            lastCompileWasBuild = false
        case .failed:
            if lastCompileWasBuild || !lastOutcomeHadError {
                let summary = String(localized: "Compiled with errors")
                let counts = String(localized: "\(workspace.errorCount) errors, \(workspace.warningCount) warnings")
                AccessibilityAnnouncer.post("\(summary). \(counts)", priority: .high)
            }
            lastOutcomeHadError = true
            lastCompileWasBuild = false
        case .toolError(let message):
            let prefix = String(localized: "Cannot compile")
            AccessibilityAnnouncer.post("\(prefix): \(message)", priority: .high)
            lastOutcomeHadError = true
            lastCompileWasBuild = false
        case .idle:
            lastCompileWasBuild = false
        }
    }

    private var durationText: String? {
        guard let duration = workspace.lastCompileDuration else { return nil }
        return String(localized: "Compiled in \(duration.formatted(.number.precision(.fractionLength(1)))) s")
    }

    private var helpText: Text {
        if case .toolError(let message) = workspace.compileState { return Text(message) }
        return Text("Compile status")
    }
}

private struct IssueCountsCapsule: View {
    @Environment(ProjectWorkspace.self) private var workspace

    var body: some View {
        Button {
            withAnimation(.smooth) { workspace.showIssues.toggle() }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(workspace.errorCount > 0 ? .red : .secondary)
                        .accessibilityHidden(true)
                    Text("\(workspace.errorCount)").monospacedDigit()
                }
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(workspace.warningCount > 0 ? .orange : .secondary)
                        .accessibilityHidden(true)
                    Text("\(workspace.warningCount)").monospacedDigit()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Show or hide the Issues panel (⇧⌘M)")
        .accessibilityLabel("Issues")
        .accessibilityValue(Text("\(workspace.errorCount) errors, \(workspace.warningCount) warnings"))
    }
}

/// Reads only the caret position, so moving the caret re-renders just this capsule.
private struct CursorCapsule: View {
    let editor: EditorController

    var body: some View {
        Text("Ln \(editor.cursor.line), Col \(editor.cursor.column)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel("Cursor position")
            .accessibilityValue(Text("Ln \(editor.cursor.line), Col \(editor.cursor.column)"))
    }
}

private struct VimStatusCapsule: View {
    let editor: EditorController

    var body: some View {
        HStack(spacing: 6) {
            if let mode = editor.vimMode {
                Text(verbatim: mode.label).fontWeight(.semibold)
            }
            if let command = editor.vimCommandLine {
                Text(verbatim: command).font(.system(size: 11, design: .monospaced))
            } else if !editor.vimPendingKeys.isEmpty {
                Text(verbatim: editor.vimPendingKeys).font(.system(size: 11, design: .monospaced))
            } else if let message = editor.vimMessage, !message.isEmpty {
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: 380)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vim mode")
        .accessibilityValue(Text(verbatim: vimStatusSummary))
    }

    private var vimStatusSummary: String {
        var parts: [String] = []
        if let mode = editor.vimMode { parts.append(mode.label) }
        if let command = editor.vimCommandLine {
            parts.append(command)
        } else if !editor.vimPendingKeys.isEmpty {
            parts.append(editor.vimPendingKeys)
        } else if let message = editor.vimMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: ", ")
    }
}
