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
        var i = min(utf16Index, units.count) - 1
        while i >= 0 && units[i] == 92 {
            backslashes += 1
            i -= 1
        }
        return (backslashes & 1) == 1
    }

    private static func endsWithLetterCommand(_ snippet: String) -> Bool {
        let units = Array(snippet.utf16)
        var j = units.count - 1
        while j >= 0 && isASCIIAlpha(units[j]) { j -= 1 }
        guard j >= 0 && j < units.count - 1 && units[j] == 92 else { return false }
        return !isEscaped(units, at: j)
    }

    /// Strict ASCII validation for LaTeX package names before interpolating into `\usepackage{...}`.
    public static func isValidPackageName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.utf8.allSatisfy { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 46 || b == 95 || b == 45
        }
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
                let needsSpace = s + 1 < units.count
                    && isASCIIAlpha(units[s + 1])
                    && endsWithLetterCommand(snippet)
                return SymbolInsertionPlan(
                    range: NSRange(location: s + 1, length: 0),
                    text: needsSpace ? "\(snippet) " : snippet,
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

    private static func maskLineComments(_ text: String) -> (masked: String, units: [UInt16]) {
        var units = Array(text.utf16)
        var i = 0
        while i < units.count {
            if units[i] == 37 && !isEscaped(units, at: i) {
                while i < units.count && units[i] != 10 && units[i] != 13 {
                    units[i] = 32
                    i += 1
                }
                continue
            }
            i += 1
        }
        return (String(decoding: units, as: UTF16.self), units)
    }

    private static func insertOffsetAfter(_ units: [UInt16], cmdEnd: Int, maxLimit: Int) -> Int {
        var i = cmdEnd
        while i < maxLimit {
            if units[i] == 10 { return i + 1 }
            if units[i] == 13 {
                return (i + 1 < maxLimit && units[i + 1] == 10) ? i + 2 : i + 1
            }
            i += 1
        }
        return maxLimit < units.count ? maxLimit : cmdEnd
    }

    private static func lineStartBefore(_ units: [UInt16], offset: Int) -> Int {
        var i = min(offset, units.count)
        while i > 0 && units[i - 1] != 10 && units[i - 1] != 13 {
            i -= 1
        }
        return i
    }

    private static func scanPreamble(_ text: String) -> (
        hasPreamble: Bool,
        imported: Set<String>,
        lastPkgOffset: Int?,
        docClassOffset: Int?,
        beginDocOffset: Int?
    ) {
        let (masked, units) = maskLineComments(text)
        let fullRange = NSRange(location: 0, length: units.count)
        let beginMatch = beginDocRegex.firstMatch(in: masked, range: fullRange)
        let preambleLimit = beginMatch?.range.location ?? units.count
        let preambleRange = NSRange(location: 0, length: preambleLimit)

        var imported = Set<String>()
        var hasPreamble = beginMatch != nil
        let beginDocOffset = beginMatch.map { lineStartBefore(units, offset: $0.range.location) }

        var docClassOffset: Int?
        if let docMatch = docClassCmdRegex.firstMatch(in: masked, range: preambleRange) {
            hasPreamble = true
            docClassOffset = insertOffsetAfter(
                units,
                cmdEnd: docMatch.range.location + docMatch.range.length,
                maxLimit: preambleLimit
            )
        }

        let pkgMatches = packageCmdRegex.matches(in: masked, range: preambleRange)
        var lastPkgOffset: Int?
        if let lastMatch = pkgMatches.last {
            hasPreamble = true
            lastPkgOffset = insertOffsetAfter(
                units,
                cmdEnd: lastMatch.range.location + lastMatch.range.length,
                maxLimit: preambleLimit
            )
            let mNS = masked as NSString
            for match in pkgMatches {
                let arg = mNS.substring(with: match.range(at: 1))
                for part in arg.split(separator: ",") {
                    let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { imported.insert(name) }
                }
            }
        }
        return (hasPreamble, imported, lastPkgOffset, docClassOffset, beginDocOffset)
    }

    /// True when `packageName` (or a superset like `mathtools`/`amssymb`) is already imported in the preamble.
    public static func hasPackageImport(_ packageName: String, in text: String) -> Bool {
        let target = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPackageName(target) else { return false }
        let info = scanPreamble(text)
        if info.imported.contains(target) { return true }
        if target == "amsmath" && info.imported.contains("mathtools") { return true }
        if target == "amsfonts" && info.imported.contains("amssymb") { return true }
        return false
    }

    /// Plans an insertion of `\usepackage{packageName}` into the preamble, or returns `nil` when
    /// the document has no preamble, `packageName` is invalid, or the package is already imported.
    public static func packageImportPlan(
        for packageName: String,
        in text: String,
        lineEnding: String = "\n"
    ) -> PackageImportPlan? {
        let target = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPackageName(target) else { return nil }
        let info = scanPreamble(text)
        guard info.hasPreamble else { return nil }
        if info.imported.contains(target) { return nil }
        if target == "amsmath" && info.imported.contains("mathtools") { return nil }
        if target == "amsfonts" && info.imported.contains("amssymb") { return nil }

        guard let insertAt = info.lastPkgOffset ?? info.docClassOffset ?? info.beginDocOffset else {
            return nil
        }
        let ns = text as NSString
        let prev: UInt16 = insertAt > 0 ? ns.character(at: insertAt - 1) : 10
        let next: UInt16 = insertAt < ns.length ? ns.character(at: insertAt) : 10
        let needsLeadingEol = insertAt > 0 && prev != 10 && prev != 13
        let needsTrailingEol = insertAt < ns.length && next != 10 && next != 13
        let directive = "\\usepackage{\(target)}"
        let leading = needsLeadingEol ? lineEnding : ""
        let trailing = (needsLeadingEol && !needsTrailingEol) ? "" : lineEnding
        return PackageImportPlan(
            offset: insertAt,
            text: "\(leading)\(directive)\(trailing)"
        )
    }
}
