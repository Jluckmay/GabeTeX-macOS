import SwiftUI
import AppKit
import CoreText
import Observation
import EditorKit
import PreviewKit
import TeXToolchain

/// App-wide preferences, persisted in `UserDefaults`. Views read only the properties they need, so
/// changing one setting re-renders only the views that depend on it.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let defaultEngine = "settings.defaultEngine"
        static let liveCompile = "settings.liveCompile"
        static let liveDelay = "settings.liveDelay"
        static let compileOnSave = "settings.compileOnSave"
        static let autoSave = "settings.autoSave"
        static let autoSaveInterval = "settings.autoSaveInterval"
        static let chktexEnabled = "settings.chktexEnabled"
        static let syncAfterBuild = "settings.syncAfterBuild"
        static let pdfSyncTrigger = "settings.pdfSyncTrigger"
        static let followCursorInPDF = "settings.followCursorInPDF"
        static let customBinDirectory = "settings.customBinDirectory"
        static let theme = "settings.theme"
        static let accentColor = "settings.accentColor"
        static let language = "settings.language"
        static let useTectonicWasm = "settings.useTectonicWasm"
        static let fontName = "settings.editor.fontName"
        static let fontSize = "settings.editor.fontSize"
        static let lineHeight = "settings.editor.lineHeight"
        static let showLineNumbers = "settings.editor.showLineNumbers"
        static let wrapLines = "settings.editor.wrapLines"
        static let highlightCurrentLine = "settings.editor.highlightCurrentLine"
        static let vimMode = "settings.editor.vimMode"
        static let autoPair = "settings.editor.autoPair"
        static let autoCloseEnvironments = "settings.editor.autoCloseEnvironments"
        static let autoCompletion = "settings.editor.autoCompletion"
        static let indentWidth = "settings.editor.indentWidth"
        static let insertSpaces = "settings.editor.insertSpaces"
        static let spellChecking = "settings.editor.spellChecking"
        static let spellCheckingLanguages = "settings.editor.spellCheckingLanguages"
        static let tabCompletes = "settings.editor.tabCompletes"
        static let completionAcceptKeys = "settings.editor.completionAcceptKeys"
        static let showPreview = "ui.showPreview"
        static let showIssues = "ui.showIssues"
    }

    // MARK: General

    var defaultEngine: TeXEngine { didSet { defaults.set(defaultEngine.rawValue, forKey: Key.defaultEngine) } }
    var liveCompile: Bool { didSet { defaults.set(liveCompile, forKey: Key.liveCompile) } }
    /// Seconds of inactivity before a live compile starts (0.5 … 5).
    var liveDelay: Double { didSet { defaults.set(liveDelay, forKey: Key.liveDelay) } }
    var compileOnSave: Bool { didSet { defaults.set(compileOnSave, forKey: Key.compileOnSave) } }
    var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Key.autoSave) } }
    /// Seconds between automatic saves when `autoSave` is enabled (0.2 … 180).
    var autoSaveInterval: Double {
        didSet {
            let clamped = min(180, max(0.2, autoSaveInterval))
            if clamped != autoSaveInterval { autoSaveInterval = clamped; return }
            defaults.set(autoSaveInterval, forKey: Key.autoSaveInterval)
        }
    }
    var chktexEnabled: Bool { didSet { defaults.set(chktexEnabled, forKey: Key.chktexEnabled) } }
    var syncAfterBuild: Bool { didSet { defaults.set(syncAfterBuild, forKey: Key.syncAfterBuild) } }
    /// The gesture in the PDF that jumps to the source: double-click (default) or ⌘-click.
    var pdfSyncTrigger: PDFSyncTrigger { didSet { defaults.set(pdfSyncTrigger.rawValue, forKey: Key.pdfSyncTrigger) } }
    /// Scroll the PDF to the caret’s position when the caret rests (off by default).
    var followCursorInPDF: Bool { didSet { defaults.set(followCursorInPDF, forKey: Key.followCursorInPDF) } }
    /// Custom TeX `bin` directory ("" = detect automatically).
    var customBinDirectory: String { didSet { defaults.set(customBinDirectory, forKey: Key.customBinDirectory) } }
    /// Theme override: `"system"`, `"light"`, or `"dark"`.
    var theme: String { didSet { defaults.set(theme, forKey: Key.theme); applyTheme() } }
    /// Accent color hex string (`"#RRGGBB"`).
    var accentColor: String { didSet { defaults.set(accentColor, forKey: Key.accentColor); applyAccentColor() } }
    /// Interface language override: `"system"`, `"en"`, or `"pt-BR"`.
    var language: String { didSet { defaults.set(language, forKey: Key.language); applyLanguage() } }
    /// Fallback Tectonic WASM compilation when no native TeX distribution is installed.
    var useTectonicWasm: Bool { didSet { defaults.set(useTectonicWasm, forKey: Key.useTectonicWasm) } }

    // MARK: Editor

    /// PostScript name of the editor font; "" = system monospaced (SF Mono).
    var fontName: String { didSet { defaults.set(fontName, forKey: Key.fontName) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: Key.lineHeight) } }
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) } }
    var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: Key.wrapLines) } }
    var highlightCurrentLine: Bool { didSet { defaults.set(highlightCurrentLine, forKey: Key.highlightCurrentLine) } }
    var vimMode: Bool { didSet { defaults.set(vimMode, forKey: Key.vimMode) } }
    var autoPairBrackets: Bool { didSet { defaults.set(autoPairBrackets, forKey: Key.autoPair) } }
    var autoCloseEnvironments: Bool { didSet { defaults.set(autoCloseEnvironments, forKey: Key.autoCloseEnvironments) } }
    var autoCompletion: Bool { didSet { defaults.set(autoCompletion, forKey: Key.autoCompletion) } }
    var indentWidth: Int { didSet { defaults.set(indentWidth, forKey: Key.indentWidth) } }
    var insertSpaces: Bool { didSet { defaults.set(insertSpaces, forKey: Key.insertSpaces) } }
    var spellChecking: Bool { didSet { defaults.set(spellChecking, forKey: Key.spellChecking) } }
    var spellCheckingLanguages: [String] { didSet { defaults.set(spellCheckingLanguages, forKey: Key.spellCheckingLanguages) } }
    /// Tab right after a completable prefix completes (on by default; Gabe's choice).
    var tabCompletes: Bool { didSet { defaults.set(tabCompletes, forKey: Key.tabCompletes) } }
    /// Which keys accept a suggestion of the completion popup.
    var completionAcceptKeys: CompletionAcceptKeys {
        didSet { defaults.set(completionAcceptKeys.rawValue, forKey: Key.completionAcceptKeys) }
    }

    // MARK: Window layout (shared by all project windows)

    var showPreview: Bool { didSet { defaults.set(showPreview, forKey: Key.showPreview) } }
    var showIssues: Bool { didSet { defaults.set(showIssues, forKey: Key.showIssues) } }

    /// Dynamic app icon rendered with the active `accentColor`.
    var appIconImage: NSImage

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }

        defaultEngine = TeXEngine(rawValue: d.string(forKey: Key.defaultEngine) ?? "") ?? .pdflatex
        liveCompile = bool(Key.liveCompile, true)
        liveDelay = min(5, max(0.5, double(Key.liveDelay, 1.0)))
        compileOnSave = bool(Key.compileOnSave, true)
        autoSave = bool(Key.autoSave, false)
        autoSaveInterval = min(180, max(0.2, double(Key.autoSaveInterval, 30.0)))
        chktexEnabled = bool(Key.chktexEnabled, true)
        syncAfterBuild = bool(Key.syncAfterBuild, false)
        pdfSyncTrigger = PDFSyncTrigger(rawValue: d.string(forKey: Key.pdfSyncTrigger) ?? "") ?? .doubleClick
        followCursorInPDF = bool(Key.followCursorInPDF, false)
        customBinDirectory = d.string(forKey: Key.customBinDirectory) ?? ""
        let storedTheme = d.string(forKey: Key.theme) ?? "system"
        theme = ["system", "light", "dark"].contains(storedTheme) ? storedTheme : "system"
        accentColor = Self.normalizedHex(d.string(forKey: Key.accentColor) ?? "") ?? "#0a84ff"
        let storedLanguage = d.string(forKey: Key.language) ?? "system"
        language = ["system", "en", "pt-BR"].contains(storedLanguage) ? storedLanguage : "system"
        useTectonicWasm = bool(Key.useTectonicWasm, false)

        fontName = d.string(forKey: Key.fontName) ?? ""
        fontSize = min(40, max(8, double(Key.fontSize, 13)))
        lineHeight = min(2.2, max(1.0, double(Key.lineHeight, 1.25)))
        showLineNumbers = bool(Key.showLineNumbers, true)
        wrapLines = bool(Key.wrapLines, true)
        highlightCurrentLine = bool(Key.highlightCurrentLine, true)
        vimMode = bool(Key.vimMode, false)
        autoPairBrackets = bool(Key.autoPair, true)
        autoCloseEnvironments = bool(Key.autoCloseEnvironments, true)
        autoCompletion = bool(Key.autoCompletion, true)
        indentWidth = min(8, max(1, int(Key.indentWidth, 2)))
        insertSpaces = bool(Key.insertSpaces, true)
        spellChecking = bool(Key.spellChecking, true)
        let savedSpellLangs = d.stringArray(forKey: Key.spellCheckingLanguages) ?? []
        if savedSpellLangs.isEmpty {
            let effective = storedLanguage == "system"
                ? (Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") == true ? "pt-BR" : "en")
                : (["en", "pt-BR"].contains(storedLanguage) ? storedLanguage : "en")
            spellCheckingLanguages = [effective]
        } else {
            spellCheckingLanguages = savedSpellLangs
        }
        tabCompletes = bool(Key.tabCompletes, true)
        completionAcceptKeys = CompletionAcceptKeys(rawValue: d.string(forKey: Key.completionAcceptKeys) ?? "") ?? .tabAndReturn

        showPreview = bool(Key.showPreview, true)
        showIssues = bool(Key.showIssues, false)
        appIconImage = NSImage()

        applyAppearance()
    }

    /// The configuration handed to `LaTeXEditorView`. The completion trigger is the shortcut of Edit ▸ Complete
    /// (Settings › Shortcuts), so the menu and the editor always agree.
    var editorConfiguration: EditorConfiguration {
        EditorConfiguration(
            fontName: fontName.isEmpty ? nil : fontName,
            fontSize: CGFloat(fontSize),
            lineHeightMultiple: CGFloat(lineHeight),
            showLineNumbers: showLineNumbers,
            wrapLines: wrapLines,
            highlightCurrentLine: highlightCurrentLine,
            vimMode: vimMode,
            autoPairBrackets: autoPairBrackets,
            autoCloseEnvironments: autoCloseEnvironments,
            autoCompletion: autoCompletion,
            indentWidth: indentWidth,
            insertSpaces: insertSpaces,
            spellChecking: spellChecking,
            spellCheckingLanguages: spellCheckingLanguages,
            tabCompletes: tabCompletes,
            completionAcceptKeys: completionAcceptKeys,
            completionTrigger: ShortcutStore.shared.combo(for: .complete)
        )
    }

    /// The custom bin directory as a URL, or nil when detection is automatic.
    var customBinURL: URL? {
        let trimmed = customBinDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: Appearance & Language

    var accentSwiftUIColor: Color {
        guard let rgb = Self.parseHex(accentColor) else { return .accentColor }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    var effectiveLocale: Locale {
        language == "system" ? .autoupdatingCurrent : Locale(identifier: language)
    }

    func applyAppearance() {
        applyTheme()
        applyLanguage()
        applyAccentColor()
    }

    func applyTheme() {
        guard let app = NSApp else { return }
        switch theme {
        case "light": app.appearance = NSAppearance(named: .aqua)
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        default: app.appearance = nil
        }
    }

    func applyLanguage() {
        if language == "system" {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
    }

    func applyAccentColor() {
        guard let rgb = Self.parseHex(accentColor) else { return }
        let nsColor = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        EditorTheme.setCustomAccentColor(nsColor)
        let icon = Self.makeAccentIcon(hex: accentColor, rgb: rgb)
        appIconImage = icon
        if let app = NSApp {
            app.applicationIconImage = icon
            for window in app.windows { window.viewsNeedDisplay = true }
        }
    }

    static func normalizedHex(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").lowercased()
        guard cleaned.count == 6, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(cleaned)"
    }

    static func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let norm = normalizedHex(hex), let value = UInt32(norm.dropFirst(), radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255.0,
            Double((value >> 8) & 0xFF) / 255.0,
            Double(value & 0xFF) / 255.0
        )
    }

    private static func makeAccentIcon(hex: String, rgb: (r: Double, g: Double, b: Double)) -> NSImage {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "").lowercased()
        let isDefault = clean == "0a84ff" || clean == "007aff"
        if isDefault, let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let bundled = NSImage(contentsOf: url) {
            return bundled
        }

        let topColor: CGColor
        let botColor: CGColor
        if isDefault {
            botColor = CGColor(srgbRed: 43 / 255, green: 45 / 255, blue: 140 / 255, alpha: 1)
            topColor = CGColor(srgbRed: 58 / 255, green: 123 / 255, blue: 255 / 255, alpha: 1)
        } else {
            let (h, s, l) = rgbToHsl(r: rgb.r, g: rgb.g, b: rgb.b)
            let top = hslToRgb(h: h, s: min(1, s * 0.95), l: min(0.72, l + 0.12))
            let bot = hslToRgb(h: h, s: min(1, s * 1.05), l: max(0.18, l - 0.22))
            topColor = CGColor(srgbRed: top.r, green: top.g, blue: top.b, alpha: 1)
            botColor = CGColor(srgbRed: bot.r, green: bot.g, blue: bot.b, alpha: 1)
        }

        let size = 256
        let inset: CGFloat = 25
        let side: CGFloat = 206
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage()
        }
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let body = superellipsePath(inset: inset, side: side)
        let minX = inset, minY = inset, maxX = inset + side, maxY = inset + side
        let midX = inset + side / 2
        let slant = side * 0.2

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3.5), blur: 11, color: CGColor(srgbRed: 0.05, green: 0.04, blue: 0.2, alpha: 0.30))
        ctx.addPath(body)
        ctx.setFillColor(botColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [botColor, topColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: minX + slant, y: minY), end: CGPoint(x: maxX - slant, y: maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let sheenCentre = CGPoint(x: midX, y: maxY + 30)
        if let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34),
                     CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                     CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
            locations: [0, 0.55, 1]
        ) {
            ctx.drawRadialGradient(sheen, startCenter: sheenCentre, startRadius: 0, endCenter: sheenCentre, endRadius: 118, options: [])
        }
        ctx.addPath(body)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()

        if let glyph = partialDerivativeGlyphPath(canvasSize: CGFloat(size), height: 130) {
            let ink = glyph.boundingBoxOfPath
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2.5), blur: 6.5, color: CGColor(srgbRed: 0.02, green: 0.02, blue: 0.2, alpha: 0.40))
            ctx.addPath(glyph)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(glyph)
            ctx.clip()
            if let fillGrad = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98),
                         CGColor(srgbRed: 214 / 255, green: 226 / 255, blue: 1, alpha: 0.86)] as CFArray,
                locations: [0, 1]
            ) {
                ctx.drawLinearGradient(fillGrad, start: CGPoint(x: ink.midX, y: ink.maxY), end: CGPoint(x: ink.midX, y: ink.minY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }

        guard let cgImage = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private static func superellipsePath(inset: CGFloat, side: CGFloat) -> CGPath {
        let cx = Double(inset + side / 2)
        let cy = Double(inset + side / 2)
        let a = Double(side / 2)
        let exponent = 2.0 / 5.0
        func signedPow(_ v: Double) -> Double { v < 0 ? -pow(-v, exponent) : pow(v, exponent) }
        let path = CGMutablePath()
        let steps = 240
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * Double.pi
            let pt = CGPoint(x: cx + a * signedPow(cos(t)), y: cy + a * signedPow(sin(t)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    private static func partialDerivativeGlyphPath(canvasSize: CGFloat, height: CGFloat) -> CGPath? {
        let character = "\u{2202}"
        var descriptor = NSFont.systemFont(ofSize: 250).fontDescriptor
        if let serif = descriptor.withDesign(.serif) { descriptor = serif }
        descriptor = descriptor.withSymbolicTraits(.italic)
        let font = NSFont(descriptor: descriptor, size: 250)
            ?? NSFont(name: "Times New Roman Italic", size: 250)
            ?? NSFont.systemFont(ofSize: 250)
        let units = Array(character.utf16)
        let fitted = CTFontCreateForString(font as CTFont, character as CFString, CFRange(location: 0, length: units.count))
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(fitted, units, &glyphs, units.count),
              let glyph = glyphs.first, glyph != 0,
              let outline = CTFontCreatePathForGlyph(fitted, glyph, nil) else { return nil }
        let ink = outline.boundingBoxOfPath
        guard ink.height > 0 else { return nil }
        let scale = height / ink.height
        let centre = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
        var transform = CGAffineTransform(translationX: -ink.midX, y: -ink.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
        return outline.copy(using: &transform)
    }

    private static func rgbToHsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        if maxC == minC { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxC == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    private static func hslToRgb(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (hue2rgb(h + 1.0 / 3), hue2rgb(h), hue2rgb(h - 1.0 / 3))
    }
}
