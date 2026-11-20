import Foundation

/// Balanced delimiter auto-closing (`\( \)`, `\[ \]`, `\begin{env}...\end{env}`) and paired
/// deletion (`{ }`, `( )`, `[ ]`, `$ $`, `$$ $$`, `\( \)`, `\[ \]`, `\begin...\end`) on
/// backward and forward delete.
public enum PairEditing {
    public struct DeletionRange: Equatable, Sendable {
        public let from: Int
        public let to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public struct DeletionPlan: Equatable, Sendable {
        public let ranges: [DeletionRange]
        public let caret: Int

        public init(ranges: [DeletionRange], caret: Int) {
            self.ranges = ranges
            self.caret = caret
        }
    }

    public struct BeginAutoClosePlan: Equatable, Sendable {
        public let insert: String
        public let caretOffset: Int

        public init(insert: String, caretOffset: Int) {
            self.insert = insert
            self.caretOffset = caretOffset
        }
    }

    private static let envTagRegex = try! NSRegularExpression(
        pattern: #"\\(begin|end)\s*\{([A-Za-z][A-Za-z0-9*]*)\}"#
    )
    private static let beginEndLineRegex = try! NSRegularExpression(
        pattern: #"\\begin\{([A-Za-z][A-Za-z0-9*]*)\}$"#
    )
    private static let commandBraceRegex = try! NSRegularExpression(
        pattern: #"(?:^|[^\\])\\[A-Za-z@]+\*?$"#
    )

    private static func isInsideLineComment(_ units: [UInt16], at idx: Int) -> Bool {
        var lineStart = idx
        while lineStart > 0 && units[lineStart - 1] != 10 {
            lineStart -= 1
        }
        var i = lineStart
        while i < idx {
            if units[i] == 37 && !MathContext.isEscaped(units, at: i) {
                return true
            }
            i += 1
        }
        return false
    }

    private static func mergeRanges(_ a: DeletionRange, _ b: DeletionRange) -> [DeletionRange] {
        let first = a.from <= b.from ? a : b
        let second = a.from <= b.from ? b : a
        if first.to >= second.from {
            return [DeletionRange(from: first.from, to: max(first.to, second.to))]
        }
        return [first, second]
    }

    /// Checks whether typing `}` finishing at UTF-16 `caretAfterBrace` completes an unclosed
    /// `\begin{env}` tag and returns the indented body + `\end{env}` block to insert.
    public static func beginAutoClose(
        in text: String,
        at caretAfterBrace: Int,
        indentUnit: String,
        lineEnding: String = "\n"
    ) -> BeginAutoClosePlan? {
        let units = Array(text.utf16)
        let pos = max(0, min(caretAfterBrace, units.count))
        var lineStart = pos
        while lineStart > 0 && units[lineStart - 1] != 10 { lineStart -= 1 }
        if isInsideLineComment(units, at: pos) { return nil }

        let lineHead = String(decoding: units[lineStart..<pos], as: UTF16.self)
        let nsHead = lineHead as NSString
        guard let m = beginEndLineRegex.firstMatch(in: lineHead, range: NSRange(location: 0, length: nsHead.length)) else {
            return nil
        }
        let slashIdx = lineStart + m.range.location
        if MathContext.isEscaped(units, at: slashIdx) { return nil }
        let env = nsHead.substring(with: m.range(at: 1))

        // Count balanced \begin{env} vs \end{env} across the document outside comments.
        let fullNS = text as NSString
        var begins = 0
        var ends = 0
        for match in envTagRegex.matches(in: text, range: NSRange(location: 0, length: fullNS.length)) {
            if MathContext.isEscaped(units, at: match.range.location) || isInsideLineComment(units, at: match.range.location) {
                continue
            }
            let name = fullNS.substring(with: match.range(at: 2))
            guard name == env else { continue }
            if fullNS.substring(with: match.range(at: 1)) == "begin" {
                begins += 1
            } else {
                ends += 1
            }
        }
        guard begins > ends else { return nil }

        var indentEnd = lineStart
        while indentEnd < pos && (units[indentEnd] == 32 || units[indentEnd] == 9) {
            indentEnd += 1
        }
        let indent = String(decoding: units[lineStart..<indentEnd], as: UTF16.self)
        let bodyPrefix = lineEnding + indent + indentUnit
        let insert = bodyPrefix + lineEnding + indent + "\\end{\(env)}"
        return BeginAutoClosePlan(insert: insert, caretOffset: bodyPrefix.utf16.count)
    }

    /// Resolves paired delimiter deletion at UTF-16 `utf16Offset` for Backspace (`forward: false`)
    /// or forward Delete (`forward: true`).
    public static func findPairedDeletion(
        in text: String,
        at utf16Offset: Int,
        forward: Bool
    ) -> DeletionPlan? {
        let units = Array(text.utf16)
        let pos = max(0, min(utf16Offset, units.count))
        return findEnvDeletion(text: text, units: units, pos: pos, forward: forward)
            ?? findEscapedParenBracketDeletion(units: units, pos: pos, forward: forward)
            ?? findDollarDeletion(units: units, pos: pos, forward: forward)
            ?? findBracketDeletion(units: units, pos: pos, forward: forward)
    }

    private static func findEnvDeletion(text: String, units: [UInt16], pos: Int, forward: Bool) -> DeletionPlan? {
        let ns = text as NSString
        var tags: [(isBegin: Bool, env: String, from: Int, to: Int)] = []
        for match in envTagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let loc = match.range.location
            if MathContext.isEscaped(units, at: loc) || isInsideLineComment(units, at: loc) { continue }
            let isBegin = ns.substring(with: match.range(at: 1)) == "begin"
            let env = ns.substring(with: match.range(at: 2))
            tags.append((isBegin, env, loc, loc + match.range.length))
        }
        guard let hitIdx = tags.firstIndex(where: { forward ? $0.from == pos : $0.to == pos }) else {
            return nil
        }
        let hit = tags[hitIdx]
        var partnerIdx: Int?
        if hit.isBegin {
            var depth = 1
            for i in (hitIdx + 1)..<tags.count where tags[i].env == hit.env {
                depth += tags[i].isBegin ? 1 : -1
                if depth == 0 {
                    partnerIdx = i
                    break
                }
            }
        } else {
            var depth = 1
            var i = hitIdx - 1
            while i >= 0 {
                if tags[i].env == hit.env {
                    depth += tags[i].isBegin ? -1 : 1
                    if depth == 0 {
                        partnerIdx = i
                        break
                    }
                }
                i -= 1
            }
        }
        guard let pIdx = partnerIdx else { return nil }
        let beginTag = hit.isBegin ? hit : tags[pIdx]
        let endTag = hit.isBegin ? tags[pIdx] : hit

        let innerOnlyWhitespace = units[beginTag.to..<endTag.from].allSatisfy {
            $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13
        }
        if innerOnlyWhitespace {
            return DeletionPlan(ranges: [DeletionRange(from: beginTag.from, to: endTag.to)], caret: beginTag.from)
        }

        var bTo = beginTag.to
        var scan = bTo
        while scan < endTag.from && (units[scan] == 32 || units[scan] == 9) { scan += 1 }
        if scan < endTag.from && units[scan] == 13 {
            scan += 1
            if scan < endTag.from && units[scan] == 10 { scan += 1 }
            bTo = scan
        } else if scan < endTag.from && units[scan] == 10 {
            bTo = scan + 1
        }

        var eFrom = endTag.from
        var nl = eFrom
        while nl > bTo && (units[nl - 1] == 32 || units[nl - 1] == 9) { nl -= 1 }
        if nl > bTo && units[nl - 1] == 10 {
            var stripFrom = nl - 1
            if stripFrom > bTo && units[stripFrom - 1] == 13 { stripFrom -= 1 }
            eFrom = stripFrom
        }

        if bTo >= eFrom {
            return DeletionPlan(ranges: [DeletionRange(from: beginTag.from, to: endTag.to)], caret: beginTag.from)
        }
        let caret = hit.isBegin ? beginTag.from : max(beginTag.from, eFrom - (bTo - beginTag.from))
        return DeletionPlan(
            ranges: [
                DeletionRange(from: beginTag.from, to: bTo),
                DeletionRange(from: eFrom, to: endTag.to),
            ],
            caret: caret
        )
    }

    private static func findEscapedParenBracketDeletion(units: [UInt16], pos: Int, forward: Bool) -> DeletionPlan? {
        let start = forward ? pos : pos - 2
        guard start >= 0, start + 2 <= units.count, units[start] == 92 else { return nil }
        if MathContext.isEscaped(units, at: start) || isInsideLineComment(units, at: start) { return nil }
        let ch = units[start + 1]
        let openCode: UInt16
        let closeCode: UInt16
        if ch == 40 || ch == 41 { openCode = 40; closeCode = 41 }
        else if ch == 91 || ch == 93 { openCode = 91; closeCode = 93 }
        else { return nil }

        let isOpener = ch == openCode
        if isOpener {
            var depth = 1
            var i = start + 2
            while i + 1 < units.count {
                if units[i] == 92 && !MathContext.isEscaped(units, at: i) && !isInsideLineComment(units, at: i) {
                    if units[i + 1] == openCode { depth += 1; i += 2; continue }
                    if units[i + 1] == closeCode {
                        depth -= 1
                        if depth == 0 {
                            return DeletionPlan(
                                ranges: mergeRanges(DeletionRange(from: start, to: start + 2), DeletionRange(from: i, to: i + 2)),
                                caret: start
                            )
                        }
                        i += 2; continue
                    }
                }
                i += 1
            }
        } else {
            var depth = 1
            var i = start - 2
            while i >= 0 {
                if units[i] == 92 && !MathContext.isEscaped(units, at: i) && !isInsideLineComment(units, at: i) {
                    if units[i + 1] == closeCode { depth += 1 }
                    else if units[i + 1] == openCode {
                        depth -= 1
                        if depth == 0 {
                            return DeletionPlan(
                                ranges: mergeRanges(DeletionRange(from: i, to: i + 2), DeletionRange(from: start, to: start + 2)),
                                caret: i + 2 == start ? i : start - 2
                            )
                        }
                    }
                }
                i -= 1
            }
        }
        return nil
    }

    private static func findForwardDoubleDollar(_ units: [UInt16], from: Int) -> Int? {
        var i = from
        while i + 1 < units.count {
            if units[i] == 37 && !MathContext.isEscaped(units, at: i) {
                while i < units.count && units[i] != 10 { i += 1 }
                continue
            }
            if units[i] == 36 && units[i + 1] == 36 && !MathContext.isEscaped(units, at: i) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findBackwardDoubleDollar(_ units: [UInt16], before: Int) -> Int? {
        var i = before - 2
        while i >= 0 {
            if units[i] == 36 && units[i + 1] == 36 && !MathContext.isEscaped(units, at: i)
                && !isInsideLineComment(units, at: i) && !MathContext.isInMathMode(units, at: i)
            {
                return i
            }
            i -= 1
        }
        return nil
    }

    private static func findForwardSingleDollar(_ units: [UInt16], from: Int) -> Int? {
        var i = from
        while i < units.count {
            let c = units[i]
            if c == 10 && i + 1 < units.count {
                var j = i + 1
                while j < units.count && (units[j] == 32 || units[j] == 9 || units[j] == 13) { j += 1 }
                if j < units.count && units[j] == 10 { return nil }
            }
            if c == 37 && !MathContext.isEscaped(units, at: i) {
                while i < units.count && units[i] != 10 { i += 1 }
                continue
            }
            if c == 36 && !MathContext.isEscaped(units, at: i) && (i + 1 >= units.count || units[i + 1] != 36) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findBackwardSingleDollar(_ units: [UInt16], before: Int) -> Int? {
        var i = before - 1
        while i >= 0 {
            if units[i] == 10 {
                var prev = i - 1
                var onlyBlank = true
                while prev >= 0 && units[prev] != 10 {
                    if units[prev] != 32 && units[prev] != 9 && units[prev] != 13 {
                        onlyBlank = false
                        break
                    }
                    prev -= 1
                }
                if prev >= 0 && onlyBlank { return nil }
            }
            if units[i] == 36 && !MathContext.isEscaped(units, at: i) && !isInsideLineComment(units, at: i) {
                if i > 0 && units[i - 1] == 36 && !MathContext.isEscaped(units, at: i - 1) {
                    i -= 2
                    continue
                }
                if !MathContext.isInMathMode(units, at: i) { return i }
            }
            i -= 1
        }
        return nil
    }

    private static func findDollarDeletion(units: [UInt16], pos: Int, forward: Bool) -> DeletionPlan? {
        if pos > 0 && pos < units.count && units[pos - 1] == 36 && units[pos] == 36
            && !MathContext.isEscaped(units, at: pos - 1) && !isInsideLineComment(units, at: pos - 1)
            && !MathContext.isInMathMode(units, at: pos - 1)
        {
            if findForwardDoubleDollar(units, from: pos + 1) == nil {
                return DeletionPlan(ranges: [DeletionRange(from: pos - 1, to: pos + 1)], caret: pos - 1)
            }
        }

        let dblStart = forward ? pos : pos - 2
        if dblStart >= 0 && dblStart + 2 <= units.count && units[dblStart] == 36 && units[dblStart + 1] == 36
            && !MathContext.isEscaped(units, at: dblStart) && !isInsideLineComment(units, at: dblStart)
        {
            if !MathContext.isInMathMode(units, at: dblStart) {
                if let close = findForwardDoubleDollar(units, from: dblStart + 2) {
                    return DeletionPlan(
                        ranges: mergeRanges(DeletionRange(from: dblStart, to: dblStart + 2), DeletionRange(from: close, to: close + 2)),
                        caret: dblStart
                    )
                }
                if forward {
                    return DeletionPlan(ranges: [DeletionRange(from: dblStart, to: dblStart + 2)], caret: dblStart)
                }
            } else if let open = findBackwardDoubleDollar(units, before: dblStart) {
                return DeletionPlan(
                    ranges: mergeRanges(DeletionRange(from: open, to: open + 2), DeletionRange(from: dblStart, to: dblStart + 2)),
                    caret: open + 2 == dblStart ? open : dblStart - 2
                )
            }
        }

        let idx = forward ? pos : pos - 1
        guard idx >= 0, idx < units.count, units[idx] == 36 else { return nil }
        if MathContext.isEscaped(units, at: idx) || isInsideLineComment(units, at: idx) { return nil }
        let partOfDouble =
            (idx > 0 && units[idx - 1] == 36 && !MathContext.isEscaped(units, at: idx - 1))
            || (idx + 1 < units.count && units[idx + 1] == 36)
        if partOfDouble { return nil }

        if !MathContext.isInMathMode(units, at: idx) {
            guard let close = findForwardSingleDollar(units, from: idx + 1) else { return nil }
            return DeletionPlan(
                ranges: mergeRanges(DeletionRange(from: idx, to: idx + 1), DeletionRange(from: close, to: close + 1)),
                caret: idx
            )
        }
        guard let open = findBackwardSingleDollar(units, before: idx) else { return nil }
        return DeletionPlan(
            ranges: mergeRanges(DeletionRange(from: open, to: open + 1), DeletionRange(from: idx, to: idx + 1)),
            caret: open + 1 == idx ? open : idx - 1
        )
    }

    private static func matchingCloser(for open: UInt16) -> UInt16? {
        switch open {
        case 123: return 125 // { -> }
        case 40: return 41   // ( -> )
        case 91: return 93   // [ -> ]
        default: return nil
        }
    }

    private static func matchingOpener(for close: UInt16) -> UInt16? {
        switch close {
        case 125: return 123
        case 41: return 40
        case 93: return 91
        default: return nil
        }
    }

    private static func isCommandArgumentBrace(_ units: [UInt16], openIdx: Int) -> Bool {
        guard openIdx > 0 else { return false }
        let prefix = String(decoding: units[0..<openIdx], as: UTF16.self)
        let ns = prefix as NSString
        return commandBraceRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func findBracketDeletion(units: [UInt16], pos: Int, forward: Bool) -> DeletionPlan? {
        if pos > 0 && pos < units.count,
           let closer = matchingCloser(for: units[pos - 1]), units[pos] == closer,
           !MathContext.isEscaped(units, at: pos - 1), !isInsideLineComment(units, at: pos - 1)
        {
            return DeletionPlan(ranges: [DeletionRange(from: pos - 1, to: pos + 1)], caret: pos - 1)
        }

        let idx = forward ? pos : pos - 1
        guard idx >= 0, idx < units.count else { return nil }
        if MathContext.isEscaped(units, at: idx) || isInsideLineComment(units, at: idx) { return nil }

        let ch = units[idx]
        if let closeChar = matchingCloser(for: ch) {
            var depth = 1
            var i = idx + 1
            while i < units.count {
                let cur = units[i]
                if cur == 37 {
                    while i < units.count && units[i] != 10 { i += 1 }
                    continue
                }
                if cur == 92 {
                    i += 2
                    continue
                }
                if cur == ch { depth += 1 }
                else if cur == closeChar {
                    depth -= 1
                    if depth == 0 {
                        if ch == 123 && i > idx + 1 && isCommandArgumentBrace(units, openIdx: idx) { return nil }
                        return DeletionPlan(
                            ranges: mergeRanges(DeletionRange(from: idx, to: idx + 1), DeletionRange(from: i, to: i + 1)),
                            caret: idx
                        )
                    }
                }
                i += 1
            }
            return nil
        }

        if let openChar = matchingOpener(for: ch) {
            var depth = 1
            var i = idx - 1
            while i >= 0 {
                if isInsideLineComment(units, at: i) || MathContext.isEscaped(units, at: i) {
                    i -= 1
                    continue
                }
                let cur = units[i]
                if cur == ch { depth += 1 }
                else if cur == openChar {
                    depth -= 1
                    if depth == 0 {
                        if openChar == 123 && i + 1 < idx && isCommandArgumentBrace(units, openIdx: i) { return nil }
                        return DeletionPlan(
                            ranges: mergeRanges(DeletionRange(from: i, to: i + 1), DeletionRange(from: idx, to: idx + 1)),
                            caret: i + 1 == idx ? i : idx - 1
                        )
                    }
                }
                i -= 1
            }
        }
        return nil
    }
}
