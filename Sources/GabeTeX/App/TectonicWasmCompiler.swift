import Foundation
@preconcurrency import WebKit
import TeXCore
import TeXToolchain

/// Fallback LaTeX compiler backed by `tectonic-worker.js` inside a hidden `WKWebView`.
/// Used when `AppSettings.shared.useTectonicWasm` is enabled (or as a fallback when no native TeX distribution is installed).
@MainActor
final class TectonicWasmCompiler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = TectonicWasmCompiler()

    private static let allowedExtensions: Set<String> = [
        "tex", "ltx", "bib", "sty", "cls", "bst", "def", "cfg", "clo", "ldf"
    ]
    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "pdf", "eps"
    ]
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let timeoutSeconds: TimeInterval = 300

    private struct WorkerReply {
        var ok: Bool
        var pdfBase64: String?
        var log: String
        var errors: Int
        var errorMessage: String?
    }

    private var webView: WKWebView?
    private var isLoaded = false
    private var loadTask: Task<Void, Error>?
    private var pendingLoad: CheckedContinuation<Void, Error>?
    private var pendingCompiles: [Int: CheckedContinuation<WorkerReply, Error>] = [:]
    private var isCompilingInWorker = false
    private var compileWaiters: [(id: Int, cont: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    private override init() {
        super.init()
    }

    func compile(_ request: CompileRequest, projectFiles: [URL]) async -> CompileResult {
        let started = ContinuousClock().now
        let mapper = ShadowPathMapper(projectDirectory: request.projectDirectory, shadowDirectory: request.projectDirectory)
        func elapsed() -> TimeInterval {
            let c = (ContinuousClock().now - started).components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
        func toolError(_ message: String, log: String = "") -> CompileResult {
            CompileResult(status: .toolError(message), diagnostics: [], log: log, toolOutput: message, duration: elapsed(), pathMapper: mapper)
        }

        if Task.isCancelled {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        }

        guard await acquireWorkerTurn() else {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        }
        defer { releaseWorkerTurn() }

        if Task.isCancelled {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        }

        do {
            try await ensureReady()
        } catch {
            return toolError(error.localizedDescription)
        }
        if Task.isCancelled {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        }

        let (files, binaryFiles, mainKey) = collectFiles(for: request, projectFiles: projectFiles)
        guard files[mainKey] != nil else {
            return toolError(String(localized: "The active TeX source file is missing."))
        }

        let id = nextID + 1
        nextID = id

        let reply: WorkerReply
        do {
            reply = try await runWorkerCompile(id: id, files: files, mainFile: mainKey, binaryFiles: binaryFiles)
        } catch is CancellationError {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        } catch {
            return toolError(error.localizedDescription)
        }

        if Task.isCancelled {
            return CompileResult(status: .cancelled, duration: elapsed(), pathMapper: mapper)
        }

        var diagnostics = Self.parseDiagnostics(from: reply.log, rootFile: request.rootFile)
        guard reply.ok, let b64 = reply.pdfBase64, !b64.isEmpty, let pdfData = Data(base64Encoded: b64) else {
            let msg = reply.errorMessage ?? (reply.log.isEmpty ? String(localized: "Tectonic compilation failed.") : reply.log)
            if diagnostics.isEmpty {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    source: .tex,
                    message: msg,
                    detail: reply.log.isEmpty ? nil : reply.log,
                    fileURL: request.rootFile,
                    line: 1
                ))
            }
            return CompileResult(
                status: .failed,
                diagnostics: diagnostics,
                log: reply.log,
                toolOutput: msg,
                duration: elapsed(),
                pathMapper: mapper
            )
        }

        let projectHash = Self.stablePathHash(request.projectDirectory.standardizedFileURL.path)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gabetex-tectonic-\(projectHash)", isDirectory: true)
        let pdfName = request.rootFile.deletingPathExtension().lastPathComponent + ".pdf"
        let pdfURL = tempDir.appendingPathComponent(pdfName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try pdfData.write(to: pdfURL, options: .atomic)
        } catch {
            return toolError(error.localizedDescription, log: reply.log)
        }

        var exportedPDFURL: URL?
        if request.purpose == .build {
            let destination = request.rootFile.deletingPathExtension().appendingPathExtension("pdf")
            if (try? pdfData.write(to: destination, options: .atomic)) != nil {
                exportedPDFURL = destination
            }
        }

        let hasErrors = reply.errors > 0 || diagnostics.contains { $0.severity == .error }
        return CompileResult(
            status: hasErrors ? .failed : .succeeded,
            pdfURL: pdfURL,
            exportedPDFURL: exportedPDFURL,
            diagnostics: diagnostics,
            log: reply.log,
            toolOutput: hasErrors ? (diagnostics.first?.message ?? "") : "",
            duration: elapsed(),
            pathMapper: mapper
        )
    }

    func terminate() {
        loadTask?.cancel()
        loadTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tectonic")
        webView?.stopLoading()
        webView = nil
        isLoaded = false
        let loadCont = pendingLoad
        pendingLoad = nil
        loadCont?.resume(throwing: CancellationError())
        let active = pendingCompiles
        pendingCompiles.removeAll()
        for (_, cont) in active {
            cont.resume(throwing: CancellationError())
        }
    }

    private func acquireWorkerTurn() async -> Bool {
        if Task.isCancelled { return false }
        if !isCompilingInWorker {
            isCompilingInWorker = true
            return true
        }
        let token = nextID + 1
        nextID = token
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if !isCompilingInWorker {
                    isCompilingInWorker = true
                    continuation.resume(returning: true)
                } else {
                    compileWaiters.append((token, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let idx = self.compileWaiters.firstIndex(where: { $0.id == token }) {
                    let waiter = self.compileWaiters.remove(at: idx)
                    waiter.cont.resume(returning: false)
                }
            }
        }
    }

    private func releaseWorkerTurn() {
        if !compileWaiters.isEmpty {
            let waiter = compileWaiters.removeFirst()
            waiter.cont.resume(returning: true)
            return
        }
        isCompilingInWorker = false
    }

    // MARK: - WebView & Worker Bridge

    private func ensureReady() async throws {
        if isLoaded, webView != nil { return }
        if let existing = loadTask {
            try await existing.value
            return
        }
        let task = Task { @MainActor in
            defer { self.loadTask = nil }
            guard let workerURL = Self.workerScriptURL(),
                  let workerScript = try? String(contentsOf: workerURL, encoding: .utf8) else {
                throw NSError(domain: "TectonicWasm", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Missing tectonic-worker.js resource.")
                ])
            }
            let scriptJSON = try String(data: JSONEncoder().encode(workerScript), encoding: .utf8) ?? "\"\""
            let html = """
            <!doctype html>
            <html><body><script>
            (function() {
              const workerSource = \(scriptJSON);
              let worker = null;
              let workerBlobUrl = null;
              function ensureWorker() {
                if (worker) return worker;
                const blob = new Blob([workerSource], { type: 'application/javascript' });
                workerBlobUrl = URL.createObjectURL(blob);
                worker = new Worker(workerBlobUrl);
                worker.onmessage = function(e) {
                  if (workerBlobUrl) {
                    URL.revokeObjectURL(workerBlobUrl);
                    workerBlobUrl = null;
                  }
                  const msg = e.data || {};
                  if (msg.type === 'progress') return;
                  let pdfBase64 = null;
                  if (msg.type === 'result' && msg.pdf) {
                    const bytes = new Uint8Array(msg.pdf);
                    let bin = '';
                    const chunk = 0x2000;
                    for (let i = 0; i < bytes.length; i += chunk) {
                      bin += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + chunk)));
                    }
                    pdfBase64 = btoa(bin);
                  }
                  window.webkit.messageHandlers.tectonic.postMessage({
                    type: msg.type || 'error',
                    id: msg.id || 0,
                    pdfBase64: pdfBase64,
                    log: msg.log || '',
                    errors: msg.errors || 0,
                    message: msg.message || ''
                  });
                };
                worker.onerror = function(e) {
                  if (workerBlobUrl) {
                    URL.revokeObjectURL(workerBlobUrl);
                    workerBlobUrl = null;
                  }
                  window.webkit.messageHandlers.tectonic.postMessage({
                    type: 'workerError',
                    id: 0,
                    message: (e && e.message) ? e.message : 'Tectonic worker error'
                  });
                  worker.terminate();
                  worker = null;
                };
                return worker;
              }
              window.__gabetexTectonicCompile = function(id, files, mainFile, binaryFiles) {
                const w = ensureWorker();
                w.postMessage({ type: 'compile', id: id, files: files, mainFile: mainFile, binaryFiles: binaryFiles || {} });
              };
            })();
            </script></body></html>
            """
            let controller = WKUserContentController()
            controller.add(self, name: "tectonic")
            let config = WKWebViewConfiguration()
            config.userContentController = controller
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = self
            self.webView = view
            self.isLoaded = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.pendingLoad = continuation
                view.loadHTMLString(html, baseURL: URL(string: "https://gabetex.local/"))
            }
        }
        loadTask = task
        try await task.value
    }

    private func runWorkerCompile(id: Int, files: [String: String], mainFile: String, binaryFiles: [String: String]) async throws -> WorkerReply {
        guard let webView else { throw CancellationError() }
        let filesJSON = String(data: try JSONEncoder().encode(files), encoding: .utf8) ?? "{}"
        let mainJSON = String(data: try JSONEncoder().encode(mainFile), encoding: .utf8) ?? "\"main.tex\""
        let binaryJSON = String(data: try JSONEncoder().encode(binaryFiles), encoding: .utf8) ?? "{}"
        let callJS = "window.__gabetexTectonicCompile(\(id), \(filesJSON), \(mainJSON), \(binaryJSON));"

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled, let self else { return }
            if let cont = self.pendingCompiles.removeValue(forKey: id) {
                self.terminate()
                cont.resume(throwing: NSError(domain: "TectonicWasm", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Tectonic compilation timed out.")
                ]))
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkerReply, Error>) in
                pendingCompiles[id] = continuation
                webView.evaluateJavaScript(callJS) { [weak self] _, error in
                    if let error, let cont = self?.pendingCompiles.removeValue(forKey: id) {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let cont = self.pendingCompiles.removeValue(forKey: id) {
                    self.terminate()
                    cont.resume(throwing: CancellationError())
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate & WKScriptMessageHandler

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other,
           let url = navigationAction.request.url,
           url.absoluteString == "about:blank" || url.host == "gabetex.local" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.terminate()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let cont = pendingLoad
        pendingLoad = nil
        cont?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        self.webView = nil
        isLoaded = false
        let cont = pendingLoad
        pendingLoad = nil
        cont?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.webView = nil
        isLoaded = false
        let cont = pendingLoad
        pendingLoad = nil
        cont?.resume(throwing: error)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "workerError" {
            let rawMsg = body["message"] as? String ?? ""
            let msg = rawMsg.isEmpty ? String(localized: "Tectonic worker error") : rawMsg
            let active = pendingCompiles
            pendingCompiles.removeAll()
            for (_, cont) in active {
                cont.resume(returning: WorkerReply(ok: false, pdfBase64: nil, log: "", errors: 1, errorMessage: msg))
            }
            return
        }
        guard let id = body["id"] as? Int,
              let cont = pendingCompiles.removeValue(forKey: id) else { return }
        let log = body["log"] as? String ?? ""
        let errors = body["errors"] as? Int ?? 0
        if type == "result" {
            cont.resume(returning: WorkerReply(
                ok: true,
                pdfBase64: body["pdfBase64"] as? String,
                log: log,
                errors: errors,
                errorMessage: nil
            ))
        } else {
            cont.resume(returning: WorkerReply(
                ok: false,
                pdfBase64: nil,
                log: log,
                errors: max(1, errors),
                errorMessage: body["message"] as? String
            ))
        }
    }

    // MARK: - Helpers

    private func collectFiles(for request: CompileRequest, projectFiles: [URL]) -> ([String: String], [String: String], String) {
        let baseDir = request.rootFile.deletingLastPathComponent().standardizedFileURL
        let basePrefix = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"
        func relativeKey(for url: URL) -> String {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(basePrefix) {
                return String(path.dropFirst(basePrefix.count))
            }
            return url.lastPathComponent
        }

        var files: [String: String] = [:]
        var binaryFiles: [String: String] = [:]
        for url in projectFiles {
            let ext = url.pathExtension.lowercased()
            let isText = Self.allowedExtensions.contains(ext)
            let isBinary = Self.binaryExtensions.contains(ext)
            guard isText || isBinary else { continue }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber, size.intValue > Self.maxFileBytes {
                continue
            }
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let key = relativeKey(for: url)
            if isText {
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    files[key] = text
                }
            } else {
                binaryFiles[key] = data.base64EncodedString()
            }
        }
        for (url, text) in request.overlays {
            files[relativeKey(for: url)] = text
        }
        let mainKey = relativeKey(for: request.rootFile)
        if files[mainKey] == nil,
           let data = FileManager.default.contents(atPath: request.rootFile.path),
           let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            files[mainKey] = text
        }
        return (files, binaryFiles, mainKey)
    }

    private static func parseDiagnostics(from log: String, rootFile: URL) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let lines = log.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("! ") else {
                index += 1
                continue
            }
            let message = String(line.dropFirst(2))
            if message.range(of: #"Font .* not loadable"#, options: [.regularExpression, .caseInsensitive]) != nil
                || message.range(of: #"\\textfont .* is undefined"#, options: [.regularExpression, .caseInsensitive]) != nil {
                index += 1
                continue
            }
            var detailLines = [line]
            var lineNumber = 1
            var lookahead = index + 1
            while lookahead < lines.count {
                let nextLine = lines[lookahead]
                if nextLine.isEmpty || nextLine.hasPrefix("! ") { break }
                detailLines.append(nextLine)
                if lineNumber == 1, nextLine.hasPrefix("l.") {
                    let digits = nextLine.dropFirst(2).prefix(while: { $0.isWholeNumber })
                    if let parsed = Int(digits), parsed > 0 { lineNumber = parsed }
                }
                lookahead += 1
            }
            result.append(Diagnostic(
                severity: .error,
                source: .tex,
                message: message,
                detail: detailLines.joined(separator: "\n"),
                fileURL: rootFile,
                line: lineNumber
            ))
            index = lookahead
        }
        return result
    }

    private static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16, uppercase: false)
    }

    private static func workerScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "tectonic-worker", withExtension: "js") {
            return bundled
        }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let adjacent = executableDir.appendingPathComponent("tectonic-worker.js")
            if FileManager.default.fileExists(atPath: adjacent.path) { return adjacent }
            let resources = executableDir.deletingLastPathComponent().appendingPathComponent("Resources/tectonic-worker.js")
            if FileManager.default.fileExists(atPath: resources.path) { return resources }
        }
        let repoRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/tectonic-worker.js")
        return FileManager.default.fileExists(atPath: repoRelative.path) ? repoRelative : nil
    }
}
