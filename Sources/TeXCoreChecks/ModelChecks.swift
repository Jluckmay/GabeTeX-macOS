import Foundation
import CheckKit
import TeXCore

@MainActor
func runModelChecks() async {
    await Check.suite("LineIndex") {
        let idx = LineIndex("ab\ncd\r\nef\rg")
        Check.equal(idx.lineCount, 4)
        Check.equal(idx.position(ofOffset: 3), SourcePosition(line: 2, column: 1))
        Check.equal(idx.offset(of: SourcePosition(line: 3, column: 2)), 8)
        Check.equal(idx.contentsRange(ofLine: 2), NSRange(location: 3, length: 2))
        Check.equal(LineIndex("").lineCount, 1)
        Check.equal(LineIndex("a\n").lineCount, 2)
        Check.equal(LineIndex("é😀x").position(ofOffset: 3), SourcePosition(line: 1, column: 4), "columns are UTF-16 units")
    }

    await Check.suite("CompletionCatalog parses") {
        Check.expect(!CompletionCatalog.allCommands.isEmpty)
        Check.expect(CompletionCatalog.environments.contains { $0.label == "itemize" })
        Check.expect(CompletionCatalog.packages.contains { $0.label == "amsmath" })
        Check.expect(CompletionCatalog.mathCommands.contains { $0.label == "\\alpha" })
        let labels = CompletionCatalog.allCommands.map(\.label)
        Check.equal(Set(labels).count, labels.count, "allCommands is de-duplicated")
    }

    await Check.suite("ProjectTemplates") {
        Check.expect(!ProjectTemplates.all.isEmpty)
        var ids = Set<String>()
        for template in ProjectTemplates.all {
            Check.expect(ids.insert(template.id).inserted, "unique id \(template.id)")
            Check.expect(template.files[template.mainFile] != nil, "\(template.id): main file \(template.mainFile) exists")
            let files = template.instantiate(title: "My Title", author: "Gabe", date: Date(timeIntervalSince1970: 0))
            Check.expect(files.values.allSatisfy { !$0.contains("{{") }, "\(template.id): placeholders replaced")
            let main = files[template.mainFile] ?? ""
            Check.expect(LaTeXScanner.isRootDocument(main), "\(template.id): main file is a root document")
            // Every file reachable from the main file exists in the template.
            let index = ProjectIndex.build(
                rootFile: fileURL(template.mainFile),
                read: { url in files[String(url.path.dropFirst("/proj/".count))] },
                fileExists: { url in files[String(url.path.dropFirst("/proj/".count))] != nil }
            )
            for reference in LaTeXScanner.includes(in: main) where [.input, .include, .subfile].contains(reference.kind) {
                let resolved = ProjectIndex.resolve(reference, includingFile: fileURL(template.mainFile), rootFile: fileURL(template.mainFile),
                                                    fileExists: { files[String(($0).path.dropFirst("/proj/".count))] != nil })
                Check.expect(resolved != nil, "\(template.id): \\\(reference.kind.rawValue){\(reference.argument)} resolves")
            }
            Check.expect(index.files.count >= 1)
        }
    }

    await Check.suite("MathContext & PairEditing") {
        Check.expect(MathContext.isInMathMode("a $x + y$ b", at: 5))
        Check.expect(!MathContext.isInMathMode("a $x + y$ b", at: 1))
        Check.expect(!MathContext.isInMathMode("Cost \\$5", at: 8))

        let wrap = MathContext.prepareSymbolInsertion("\\alpha", in: "Hello world", replacing: NSRange(location: 6, length: 0))
        Check.equal(wrap.text, "$\\alpha$")
        let mergeLeft = MathContext.prepareSymbolInsertion("\\alpha", in: "Hello $x$", replacing: NSRange(location: 6, length: 0))
        Check.equal(mergeLeft.range, NSRange(location: 7, length: 0))
        Check.equal(mergeLeft.text, "\\alpha ")

        Check.expect(!MathContext.hasPackageImport("bad}\n\\input{x}%", in: "\\usepackage{amsmath}\n\\begin{document}"))
        Check.expect(MathContext.packageImportPlan(for: "bad}\n\\input{x}%", in: "\\documentclass{article}\n\\begin{document}") == nil)

        let sameLinePlan = MathContext.packageImportPlan(for: "amssymb", in: "\\documentclass{article}\\begin{document}")
        Check.equal(sameLinePlan, MathContext.PackageImportPlan(offset: 23, text: "\n\\usepackage{amssymb}\n"))

        let docWithDisplay = "Hello $$\n\n$$\na^2+b^2=c^2\n$$"
        Check.equal(
            PairEditing.findPairedDeletion(in: docWithDisplay, at: 7, forward: false),
            PairEditing.DeletionPlan(ranges: [PairEditing.DeletionRange(from: 6, to: 8)], caret: 6)
        )
        Check.expect(PairEditing.findPairedDeletion(in: "\\usepackage[T1]{fontenc}", at: 24, forward: false) == nil)
        Check.expect(PairEditing.findPairedDeletion(in: "\\frac{a}{b}", at: 11, forward: false) == nil)
        Check.expect(PairEditing.findPairedDeletion(in: "\\left( x \\right)", at: 5, forward: false) == nil)
    }
}
