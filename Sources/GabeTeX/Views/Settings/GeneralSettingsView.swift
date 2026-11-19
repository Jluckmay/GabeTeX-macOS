import SwiftUI
import AppKit
import PreviewKit
import TeXToolchain

/// Compilation behaviour: engine, live compile, saving, checks, and appearance.
struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @LocalState private var hexInput = AppSettings.shared.accentColor

    private static let accentPresets: [(hex: String, title: LocalizedStringKey)] = [
        ("#0a84ff", "Blue"),
        ("#af52de", "Purple"),
        ("#ff2d55", "Pink"),
        ("#ff3b30", "Red"),
        ("#ff9500", "Orange"),
        ("#ffcc00", "Yellow"),
        ("#34c759", "Green"),
        ("#30b0c7", "Teal"),
        ("#8e8e93", "Graphite"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Default engine", selection: $settings.defaultEngine) {
                    ForEach(TeXEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Toggle("Compile while typing", isOn: $settings.liveCompile)
                LabeledContent("Wait after typing") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.liveDelay, in: 0.5...5, step: 0.5) {
                            Text("Wait after typing")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text("\(settings.liveDelay.formatted(.number.precision(.fractionLength(1)))) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!settings.liveCompile)
                Toggle("Compile when saving", isOn: $settings.compileOnSave)
            } header: {
                Text("Compilation")
            } footer: {
                Text("Live compiling uses a private copy of your project, so unsaved text is checked without touching your files. A “% !TEX program = …” comment in the main file overrides the engine.")
            }

            Section {
                Toggle("Save automatically", isOn: $settings.autoSave)
                LabeledContent("Auto-save interval") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.autoSaveInterval, in: 0.2...180, step: 0.2) {
                            Text("Auto-save interval")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        intervalText(settings.autoSaveInterval)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                .disabled(!settings.autoSave)
            } header: {
                Text("Auto-save")
            } footer: {
                Text("Automatically saves open files with unsaved changes at regular intervals.")
            }

            Section {
                Toggle("Check style with chktex", isOn: $settings.chktexEnabled)
            } header: {
                Text("Checks")
            } footer: {
                Text("Structure problems such as unbalanced braces are always reported while you type.")
            }

            Section {
                Picker("Jump to source from PDF", selection: $settings.pdfSyncTrigger) {
                    Text("Double-click").tag(PDFSyncTrigger.doubleClick)
                    Text("⌘-click").tag(PDFSyncTrigger.commandClick)
                }
                Toggle("Show the PDF position after each build", isOn: $settings.syncAfterBuild)
                Toggle("Follow cursor in PDF", isOn: $settings.followCursorInPDF)
            } header: {
                Text("PDF Preview")
            } footer: {
                Text("Clicking text in the PDF takes you to the same word in the source, and ⇧⌘J (Build ▸ Show in PDF) or ⌘-click in the editor shows where a word is in the PDF. “Follow cursor” keeps the PDF scrolled to the cursor once it rests.")
            }

            Section {
                LabeledContent("Accent Color") {
                    HStack(spacing: 6) {
                        ForEach(Self.accentPresets, id: \.hex) { preset in
                            let selected = settings.accentColor.caseInsensitiveCompare(preset.hex) == .orderedSame
                            let color = presetColor(preset.hex)
                            Button {
                                settings.accentColor = preset.hex
                                hexInput = preset.hex
                            } label: {
                                Circle()
                                    .fill(color)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.primary.opacity(selected ? 0.85 : 0.18), lineWidth: selected ? 2 : 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(preset.title)
                            .accessibilityLabel(preset.title)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom color")
                            .accessibilityLabel("Custom color")
                        TextField("#0a84ff", text: $hexInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 74)
                            .help("Hex color")
                            .accessibilityLabel("Hex color")
                            .onSubmit { commitHexInput() }
                            .onChange(of: hexInput) { _, newValue in
                                if let norm = AppSettings.normalizedHex(newValue),
                                   norm != settings.accentColor {
                                    settings.accentColor = norm
                                }
                            }
                            .onChange(of: settings.accentColor) { _, newValue in
                                if hexInput != newValue { hexInput = newValue }
                            }
                    }
                }
                Picker("Theme", selection: $settings.theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Language", selection: $settings.language) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Português (Brasil)").tag("pt-BR")
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Changing the language takes full effect after restarting GabeTeX.")
            }
        }
        .formStyle(.grouped)
    }

    private func presetColor(_ hex: String) -> Color {
        guard let rgb = AppSettings.parseHex(hex) else { return .accentColor }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { settings.accentSwiftUIColor },
            set: { newColor in
                guard let srgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                let r = max(0, min(255, Int((srgb.redComponent * 255).rounded())))
                let g = max(0, min(255, Int((srgb.greenComponent * 255).rounded())))
                let b = max(0, min(255, Int((srgb.blueComponent * 255).rounded())))
                let hex = String(format: "#%02x%02x%02x", r, g, b)
                if settings.accentColor != hex { settings.accentColor = hex }
                hexInput = hex
            }
        )
    }

    private func commitHexInput() {
        if let norm = AppSettings.normalizedHex(hexInput) {
            settings.accentColor = norm
            hexInput = norm
        } else {
            hexInput = settings.accentColor
        }
    }

    @ViewBuilder
    private func intervalText(_ seconds: Double) -> some View {
        if seconds < 1 {
            Text("\(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        } else if seconds < 60 {
            if abs(seconds.rounded() - seconds) < 0.05 {
                Text("\(String(Int(seconds.rounded()))) s")
            } else {
                Text("\(seconds.formatted(.number.precision(.fractionLength(1)))) s")
            }
        } else {
            let total = Int(seconds.rounded())
            let min = total / 60
            let sec = total % 60
            if sec == 0 {
                if min == 1 {
                    Text("1 minute")
                } else {
                    Text("\(String(min)) minutes")
                }
            } else {
                Text("\(String(min)) min \(String(sec)) s")
            }
        }
    }
}
