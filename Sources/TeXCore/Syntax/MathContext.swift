import Foundation

/// Context-aware LaTeX math mode detection and delimiter wrapping for symbols inserted
/// from the Math Symbols table via click or drag-and-drop.
public enum MathContext {
    public struct SymbolInsertionPlan: Equatable, Sendable {
        public let range: NSRange
        public let text: String
        public let moveAfterClosingDollar: Bool

        public init(range: NSRange, text: String, moveAfterClosingDollar: Bool) {
            self.range = range
            self.text = text
            self.moveAfterClosingDollar = moveAfterClosingDollar
        }
    }

    private enum Mode {
        case none
        case dollar
        case double
        case paren
        case bracket
        case env
    }

    private struct Frame {
        let mode: Mode
        let envName: String
        let returnBraceDepth: Int
    }

    private static let verbatimEnvs: Set<String> = [
        "verbatim", "verbatim*", "Verbatim", "Verbatim*",
        "BVerbatim", "BVerbatim*", "LVerbatim", "LVerbatim*",
        "lstlisting", "minted", "comment", "filecontents", "filecontents*",
        "spverbatim", "verbatimtab",
    ]

    private static let mathEnvs: Set<String> = [
        "equation", "equation*", "align", "align*", "alignat", "alignat*",
        "flalign", "flalign*", "gather", "gather*", "multline", "multline*",
        "eqnarray", "eqnarray*", "math", "displaymath", "dmath", "dmath*",
    ]

    private static let textModeCommands: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt",
        "mbox", "hbox", "intertext", "shortintertext",
    ]

    @inline(__always)
    private static func isASCIIAlpha(_ u: UInt16) -> Bool {
        (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
    }

    /// True when `utf16Index` is preceded by an odd number of consecutive backslashes.
    public static func isEscaped(_ units: [UInt16], at utf16Index: Int) -> Bool {
        var backslashes = 0
        var i = utf16Index - 1
        while i >= 0 && units[i] == 92 {
            backslashes += 1
            i -= 1
        }
        return (backslashes & 1) == 1
    }

    /// Returns `true` when UTF-16 `offset` in `text` is inside a LaTeX math region.
    public static func isInMathMode(_ text: String, at utf16Offset: Int) -> Bool {
        let units = Array(text.utf16)
        return isInMathMode(units, at: utf16Offset)
    }

    static func isInMathMode(_ units: [UInt16], at utf16Offset: Int) -> Bool {
        let limit = max(0, min(utf16Offset, units.count))
        var mode: Mode = .none
        var envName = ""
        var verbatimEnv: String?
        var braceDepth = 0
        var atLineStart = true
        var frames: [Frame] = []

        var i = 0
        while i < limit {
            let ch = units[i]

            if let activeVerb = verbatimEnv {
                if ch == 92, i + 4 <= limit,
                   units[i + 1] == 101, units[i + 2] == 110, units[i + 3] == 100 // \end
                {
                    var j = i + 4
                    while j < limit && (units[j] == 32 || units[j] == 9) { j += 1 }
                    if j < limit && units[j] == 123 {
                        var close = j + 1
                        while close < limit && units[close] != 125 { close += 1 }
                        if close < limit,
                           String(decoding: units[(j + 1)..<close], as: UTF16.self)
                               .trimmingCharacters(in: .whitespaces) == activeVerb
                        {
                            verbatimEnv = nil
                            atLineStart = false
                            i = close + 1
                            continue
                        }
                    }
                }
                if ch == 10 { atLineStart = true }
                else if ch != 13 && ch != 32 && ch != 9 { atLineStart = false }
                i += 1
                continue
            }

            if ch == 10 {
                if atLineStart && mode == .dollar {
                    mode = .none
                }
                atLineStart = true
                i += 1
                continue
            }

            if ch == 13 || ch == 32 || ch == 9 {
                i += 1
                continue
            }

            if ch == 37 { // %
                atLineStart = false
                while i < limit && units[i] != 10 { i += 1 }
                continue
            }

            atLineStart = false

            if ch == 92 { // backslash
                if i + 1 >= limit {
                    i += 1
                    continue
                }
                let next = units[i + 1]
                if !isASCIIAlpha(next) {
                    if next == 40 && mode == .none { mode = .paren }
                    else if next == 41 && mode == .paren { mode = .none }
                    else if next == 91 && mode == .none { mode = .bracket }
                    else if next == 93 && mode == .bracket { mode = .none }
                    i += 2
                    continue
                }

                var j = i + 1
                while j < limit && isASCIIAlpha(units[j]) { j += 1 }
                let cmd = String(decoding: units[(i + 1)..<j], as: UTF16.self)
                i = j

                if cmd == "verb" || cmd == "lstinline" {
                    if i < limit && units[i] == 42 { i += 1 }
                    if i < limit && units[i] != 10 {
                        let delim = units[i]
                        i += 1
                        while i < limit && units[i] != delim && units[i] != 10 { i += 1 }
                        if i < limit && units[i] == delim { i += 1 }
                    }
                    continue
                }

                if cmd == "begin" || cmd == "end" {
                    var k = i
                    while k < limit && (units[k] == 32 || units[k] == 9) { k += 1 }
                    if k < limit && units[k] == 123 {
                        var close = k + 1
                        while close < limit && units[close] != 125 { close += 1 }
                        if close < limit {
                            let name = String(decoding: units[(k + 1)..<close], as: UTF16.self)
                                .trimmingCharacters(in: .whitespaces)
                            if cmd == "begin" {
                                if verbatimEnvs.contains(name) {
                                    verbatimEnv = name
                                } else if mode == .none && mathEnvs.contains(name) {
                                    mode = .env
                                    envName = name
                                }
                            } else if mode == .env && name == envName {
                                mode = .none
                                envName = ""
                            }
                            i = close + 1
                        }
                    }
                    continue
                }

                if mode != .none && textModeCommands.contains(cmd) {
                    var k = i
                    while k < limit && (units[k] == 32 || units[k] == 9) { k += 1 }
                    if k < limit && units[k] == 123 {
                        frames.append(Frame(mode: mode, envName: envName, returnBraceDepth: braceDepth))
                        mode = .none
                        envName = ""
                        braceDepth += 1
                        i = k + 1
                    }
                }
                continue
            }

            if ch == 123 {
                braceDepth += 1
                i += 1
                continue
            }

            if ch == 125 {
                if braceDepth > 0 { braceDepth -= 1 }
                if let last = frames.last, last.returnBraceDepth == braceDepth {
                    frames.removeLast()
                    mode = last.mode
                    envName = last.envName
                }
                i += 1
                continue
            }

            if ch == 36 { // $
                switch mode {
                case .dollar:
                    mode = .none
                    i += 1
                case .double:
                    if i + 1 < limit && units[i + 1] == 36 { i += 2 } else { i += 1 }
                    mode = .none
                case .none:
                    if i + 1 < limit && units[i + 1] == 36 {
                        mode = .double
                        i += 2
                    } else if i + 1 == limit && i + 1 < units.count && units[i + 1] == 36 {
                        // Caret positioned inside empty auto-paired `$$`.
                        mode = .dollar
                        i += 1
                    } else {
                        mode = .dollar
                        i += 1
                    }
                default:
                    i += 1
                }
                continue
            }

            i += 1
        }

        return verbatimEnv == nil && mode != .none
    }

    /// Prepares `snippet` for insertion replacing `range` in `text`, wrapping in `$...$` or
    /// `\[\n...\n\]` outside math mode and merging into adjacent single `$` delimiters.
    public static func prepareSymbolInsertion(
        _ snippet: String,
        in text: String,
        replacing range: NSRange
    ) -> SymbolInsertionPlan {
        let units = Array(text.utf16)
        let s = max(0, min(range.location, units.count))
        let rawEnd = range.location == NSNotFound ? s : (range.location + range.length)
        let e = max(s, min(rawEnd, units.count))

        if isInMathMode(units, at: s) {
            return SymbolInsertionPlan(
                range: NSRange(location: s, length: e - s),
                text: snippet,
                moveAfterClosingDollar: false
            )
        }

        let isMultiline = snippet.contains("\n")
        if s == e && !isMultiline {
            if s > 0, units[s - 1] == 36, (s < 2 || units[s - 2] != 36),
               !isEscaped(units, at: s - 1), isInMathMode(units, at: s - 1)
            {
                return SymbolInsertionPlan(
                    range: NSRange(location: s - 1, length: 0),
                    text: snippet,
                    moveAfterClosingDollar: true
                )
            }
            if s < units.count, units[s] == 36,
               (s + 1 >= units.count || units[s + 1] != 36),
               !isEscaped(units, at: s), isInMathMode(units, at: s + 1)
            {
                return SymbolInsertionPlan(
                    range: NSRange(location: s + 1, length: 0),
                    text: snippet,
                    moveAfterClosingDollar: false
                )
            }
        }

        let wrapped = isMultiline ? "\\[\n\(snippet)\n\\]" : "$\(snippet)$"
        return SymbolInsertionPlan(
            range: NSRange(location: s, length: e - s),
            text: wrapped,
            moveAfterClosingDollar: false
        )
    }

    public struct PackageImportPlan: Equatable, Sendable {
        public let offset: Int
        public let text: String

        public init(offset: Int, text: String) {
            self.offset = offset
            self.text = text
        }
    }

    private static let packageCmdRegex = try! NSRegularExpression(
        pattern: #"\\(?:usepackage|RequirePackage)(?:\s*\[[^\]]*\])?\s*\{([^}]+)\}"#
    )
    private static let docClassCmdRegex = try! NSRegularExpression(
        pattern: #"\\documentclass(?:\s*\[[^\]]*\])?\s*\{[^}]+\}"#
    )
    private static let beginDocRegex = try! NSRegularExpression(
        pattern: #"\\begin\s*\{document\}"#
    )

    private static func stripLineComment(_ line: String) -> String {
        let units = Array(line.utf16)
        for i in units.indices where units[i] == 37 && !isEscaped(units, at: i) {
            return String(decoding: units[0..<i], as: UTF16.self)
        }
        return line
    }

    private static func scanPreamble(_ text: String) -> (
        hasPreamble: Bool,
        imported: Set<String>,
        lastPkgLineEnd: Int?,
        docClassLineEnd: Int?,
        beginDocLineStart: Int?
    ) {
        var imported = Set<String>()
        var hasPreamble = false
        var lastPkgLineEnd: Int?
        var docClassLineEnd: Int?
        var beginDocLineStart: Int?

        let ns = text as NSString
        var offset = 0
        while offset <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let rawLine = ns.substring(with: lineRange)
            let uncommented = stripLineComment(rawLine)
            let uNS = uncommented as NSString
            let uRange = NSRange(location: 0, length: uNS.length)

            if beginDocRegex.firstMatch(in: uncommented, range: uRange) != nil {
                hasPreamble = true
                beginDocLineStart = lineRange.location
                break
            }
            if docClassCmdRegex.firstMatch(in: uncommented, range: uRange) != nil {
                hasPreamble = true
                docClassLineEnd = lineRange.location + lineRange.length
            }
            let pkgMatches = packageCmdRegex.matches(in: uncommented, range: uRange)
            if !pkgMatches.isEmpty {
                hasPreamble = true
                lastPkgLineEnd = lineRange.location + lineRange.length
                for match in pkgMatches {
                    let arg = uNS.substring(with: match.range(at: 1))
                    for part in arg.split(separator: ",") {
                        let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { imported.insert(name) }
                    }
                }
            }
            if lineRange.length == 0 || lineRange.location + lineRange.length >= ns.length { break }
            offset = lineRange.location + lineRange.length
        }
        return (hasPreamble, imported, lastPkgLineEnd, docClassLineEnd, beginDocLineStart)
    }

    /// True when `packageName` (or a superset like `mathtools`/`amssymb`) is already imported in the preamble.
    public static func hasPackageImport(_ packageName: String, in text: String) -> Bool {
        let target = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return true }
        let info = scanPreamble(text)
        if info.imported.contains(target) { return true }
        if target == "amsmath" && info.imported.contains("mathtools") { return true }
        if target == "amsfonts" && info.imported.contains("amssymb") { return true }
        return false
    }

    /// Plans an insertion of `\usepackage{packageName}` into the preamble, or returns `nil` when
    /// the document has no preamble or already imports the package.
    public static func packageImportPlan(
        for packageName: String,
        in text: String,
        lineEnding: String = "\n"
    ) -> PackageImportPlan? {
        let target = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let info = scanPreamble(text)
        guard info.hasPreamble else { return nil }
        if info.imported.contains(target) { return nil }
        if target == "amsmath" && info.imported.contains("mathtools") { return nil }
        if target == "amsfonts" && info.imported.contains("amssymb") { return nil }

        guard let insertAt = info.lastPkgLineEnd ?? info.docClassLineEnd ?? info.beginDocLineStart else {
            return nil
        }
        let ns = text as NSString
        let needsLeadingEol = insertAt > 0 && ns.character(at: insertAt - 1) != 10
        let directive = "\\usepackage{\(target)}"
        return PackageImportPlan(
            offset: insertAt,
            text: needsLeadingEol ? "\(lineEnding)\(directive)" : "\(directive)\(lineEnding)"
        )
    }
}
