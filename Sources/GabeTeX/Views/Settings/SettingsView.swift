import SwiftUI

/// The Settings window: General, Editor, Shortcuts, TeX and Zotero. The selected pane is remembered (and set by
/// GabeTeX ▸ Keyboard Shortcuts…).
struct SettingsView: View {
    enum Pane: String {
        case general, editor, shortcuts, tex, zotero
    }

    /// UserDefaults key of the selected pane.
    static let paneKey = "settings.selectedPane"

    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettingsView()
            }
            Tab("Editor", systemImage: "character.cursor.ibeam", value: Pane.editor) {
                EditorSettingsView()
            }
            Tab("Shortcuts", systemImage: "keyboard", value: Pane.shortcuts) {
                ShortcutsSettingsView()
            }
            Tab("TeX", systemImage: "function", value: Pane.tex) {
                TeXSettingsView()
            }
            Tab("Zotero", systemImage: "book", value: Pane.zotero) {
                ZoteroSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 600)
    }
}
