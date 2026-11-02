// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// webkit.messageHandlers.ingenium: how the page speaks to the app, with the
// same protocol as the Android app. The page posts {method, args, callId};
// answers come back as window.__ingNativeEvent({type:"reply", callId, ok,
// result|error}), with load progress and reply text as events in between.

import UIKit
import UniformTypeIdentifiers
import WebKit

final class EngineBridge: NSObject, WKScriptMessageHandler, UIDocumentPickerDelegate {
    weak var webView: WKWebView?
    weak var host: UIViewController?

    let library = ModelLibrary()
    private let engineQueue = DispatchQueue(label: "ingenium.engine", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "ingenium.io", qos: .userInitiated)
    // R70: downloads of Ingenium's lineup, one at a time, each with its stop switch
    private let downloadQueue = DispatchQueue(label: "ingenium.download", qos: .utility)
    private var installStops: [String: Bool] = [:]   // under installLock
    private let installLock = NSLock()

    private let modelLock = NSLock()
    private var model: EngineModel?          // set on the engine queue; read under modelLock for abort
    private var loadedId: String?
    private var loadedCtx = 0
    private var loadedInfo: [String: Any]?

    private var importCallId: String?        // main thread
    private var netTasks: [String: Task<Void, Never>] = [:]   // under netLock
    private let netLock = NSLock()
    private var savePicker: (callId: String, url: URL, picker: UIDocumentPickerViewController)?

    // MARK: messages from the page

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // 6.7 (security audit): WebKit defines this handler in every frame, including the sandboxed frames in which Ingenium
        // shows pages it did not write (a model's page, an app sent as a file, the preview). Only Ingenium's own page, the
        // main frame served from the app's own scheme, may speak to the engine, the model library or the network.
        let frame = message.frameInfo
        guard frame.isMainFrame, frame.securityOrigin.protocol.lowercased() == AppSchemeHandler.scheme else { return }
        guard let text = message.body as? String,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let callId = obj["callId"] as? String ?? ""
        let method = obj["method"] as? String ?? ""
        let args = obj["args"] as? [String: Any] ?? [:]

        switch method {
        case "info":
            ioQueue.async { self.replyOk(callId, self.info()) }
        case "listModels":
            ioQueue.async { self.replyOk(callId, self.library.list()) }
        case "load":
            engineQueue.async { self.doLoad(callId, args) }
        case "generate":
            engineQueue.async { self.doGenerate(callId, args) }
        case "abort":
            modelLock.lock(); let m = model; modelLock.unlock()
            m?.abort()
            replyOk(callId, ["ok": true])
        case "unload":
            engineQueue.async { self.freeModel(); self.replyOk(callId, ["ok": true]) }
        case "deleteModel":
            engineQueue.async {
                let id = args["id"] as? String ?? ""
                if id == self.loadedId { self.freeModel() }
                do { try self.library.delete(id: id); self.replyOk(callId, ["ok": true]) }
                catch { self.replyErr(callId, "\(error)") }
            }
        case "restoreBuiltIn":
            ioQueue.async {
                do { try self.library.restoreBuiltIn(); self.replyOk(callId, ["ok": true]) }
                catch { self.replyErr(callId, "\(error)") }
            }
        case "net":
            doNet(callId, args)
        // 6.9.1: an https address opened in Safari (GitHub's own sign-in page, a build on GitHub)
        case "openUrl":
            let u = args["url"] as? String ?? ""
            guard let url = URL(string: u), url.scheme?.lowercased() == "https", !u.contains(" "), !u.contains("\""), !u.contains("'"), !u.contains("<") else {
                replyErr(callId, "only an https address can be opened"); return
            }
            DispatchQueue.main.async { UIApplication.shared.open(url); self.replyOk(callId, ["ok": true]) }
        case "netAbort":
            let req = args["req"] as? String ?? ""
            netLock.lock(); let t = netTasks.removeValue(forKey: req); netLock.unlock()
            t?.cancel()
            replyOk(callId, ["ok": true])
        case "installModel":
            let key = args["key"] as? String ?? ""
            installLock.lock()
            let busy = installStops[key] != nil
            if !busy { installStops[key] = false }
            installLock.unlock()
            if busy { replyErr(callId, "That model is already being installed."); break }
            downloadQueue.async { self.doInstall(callId, key, args) }
        case "cancelInstall":
            let key = args["key"] as? String ?? ""
            installLock.lock()
            if installStops[key] != nil { installStops[key] = true }
            installLock.unlock()
            replyOk(callId, ["ok": true])
        // R72: a model the page converts arrives in pieces (base64), in order
        case "convertBegin":
            ioQueue.async {
                do {
                    let size = (args["size"] as? NSNumber)?.int64Value ?? 0
                    let id = try self.library.writeBegin(name: args["name"] as? String ?? "", size: size)
                    self.replyOk(callId, ["id": id])
                } catch let f as ModelLibrary.ImportFailure { self.replyErr(callId, f.reason) }
                catch { self.replyErr(callId, "\(error)") }
            }
        case "convertWrite":
            ioQueue.async {
                let id = args["id"] as? String ?? ""
                guard let data = Data(base64Encoded: args["data"] as? String ?? "") else {
                    self.library.writeAbort(id: id); self.replyErr(callId, "a piece of the model arrived damaged"); return
                }
                do { let n = try self.library.writeChunk(id: id, data: data); self.replyOk(callId, ["written": n]) }
                catch let f as ModelLibrary.ImportFailure { self.replyErr(callId, f.reason) }
                catch { self.replyErr(callId, "\(error)") }
            }
        case "convertEnd":
            ioQueue.async {
                do { let m = try self.library.writeEnd(id: args["id"] as? String ?? ""); self.replyOk(callId, ["model": m]) }
                catch let f as ModelLibrary.ImportFailure { self.replyErr(callId, f.reason) }
                catch { self.replyErr(callId, "\(error)") }
            }
        case "convertAbort":
            ioQueue.async { self.library.writeAbort(id: args["id"] as? String ?? ""); self.replyOk(callId, ["ok": true]) }
        case "importModels":
            DispatchQueue.main.async { self.openPicker(callId) }
        case "saveFile":
            DispatchQueue.main.async { self.saveFile(callId, args) }
        case "appearance":
            let dark = args["dark"] as? Bool ?? false
            let top = args["top"] as? String ?? ""
            let back = args["back"] as? String ?? ""
            DispatchQueue.main.async { (self.host as? WebViewController)?.setAppearance(dark: dark, top: top, back: back) }
            replyOk(callId, ["ok": true])
        case "clipboardRead":
            // R78: the page's own edit panel pastes through the app; iOS may ask
            // the person once to allow the paste, which is the system's own guard
            DispatchQueue.main.async { self.replyOk(callId, ["text": UIPasteboard.general.string ?? ""]) }
        case "clipboardWrite":
            let text = args["text"] as? String ?? ""
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
                self.replyOk(callId, ["ok": true])
            }
        case "log":
            // the cloud build's self-test reads these lines from the simulator's output
            print(args["msg"] as? String ?? "")
        default:
            replyErr(callId, "Unknown request: \(method)")
        }
    }

    // MARK: R70, installing a model of Ingenium's lineup

    private func doInstall(_ callId: String, _ key: String, _ args: [String: Any]) {
        defer { installLock.lock(); installStops.removeValue(forKey: key); installLock.unlock() }
        var last = Date.distantPast
        do {
            let m = try library.install(spec: args, progress: { got, total, phase in
                let now = Date()
                if phase != "download" || now.timeIntervalSince(last) >= 0.25 {
                    last = now
                    self.emit(["type": "install-progress", "key": key, "received": got, "total": total, "phase": phase])
                }
            }, cancelled: { [weak self] in
                guard let self = self else { return true }
                self.installLock.lock(); defer { self.installLock.unlock() }
                return self.installStops[key] ?? false
            })
            replyOk(callId, ["model": m])
        } catch is ModelLibrary.Cancelled {
            replyErr(callId, "Stopped.")
        } catch let f as ModelLibrary.ImportFailure {
            replyErr(callId, f.reason)
        } catch {
            replyErr(callId, "\(error)")
        }
    }

    // MARK: the internet, when the page asks (a connection, web search, GitHub)

    private static let netUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// One request for the page, from the app itself: no website rule refuses it, and a
    /// streamed reply (Claude, Ollama) comes back to the page piece by piece.
    private func doNet(_ callId: String, _ args: [String: Any]) {
        let req = args["req"] as? String ?? callId
        guard let s = args["url"] as? String, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            replyErr(callId, "Only web addresses (http and https) can be fetched.")
            return
        }
        let timeout = TimeInterval(max(5, min((args["timeout"] as? Int) ?? 120, 900)))
        var r = URLRequest(url: url, timeoutInterval: timeout)
        let method = (args["method"] as? String ?? "GET").uppercased()
        r.httpMethod = method
        r.setValue(EngineBridge.netUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in (args["headers"] as? [String: Any] ?? [:]) {
            let low = k.lowercased()
            if low == "host" || low == "content-length" || low == "connection" { continue }
            r.setValue("\(v)", forHTTPHeaderField: k)
        }
        if let b = args["body"] as? String, method != "GET", method != "HEAD" {
            r.httpBody = Data(b.utf8)
            if r.value(forHTTPHeaderField: "Content-Type") == nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        let stream = args["stream"] as? Bool ?? false
        let request = r   // a constant for the task: a captured var would not compile
        let task = Task {
            defer { self.netLock.lock(); self.netTasks.removeValue(forKey: req); self.netLock.unlock() }
            do {
                if stream {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: request)
                    let http = resp as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    var text = ""
                    for try await line in bytes.lines {
                        if status < 400 { self.emit(["type": "net-chunk", "req": req, "text": line + "\n"]) }
                        else { text += line + "\n"; if text.count > 200_000 { break } }
                    }
                    self.replyOk(callId, ["status": status, "contentType": http?.value(forHTTPHeaderField: "Content-Type") ?? "", "body": text])
                } else {
                    let (data, resp) = try await URLSession.shared.data(for: request)
                    let http = resp as? HTTPURLResponse
                    let body = String(data: data.prefix(8_000_000), encoding: .utf8) ?? String(decoding: data.prefix(8_000_000), as: UTF8.self)
                    self.replyOk(callId, ["status": http?.statusCode ?? 0, "contentType": http?.value(forHTTPHeaderField: "Content-Type") ?? "", "body": body])
                }
            } catch is CancellationError {
                self.replyErr(callId, "Stopped.")
            } catch let e as URLError where e.code == .cancelled {
                self.replyErr(callId, "Stopped.")
            } catch let e as URLError {
                switch e.code {
                case .notConnectedToInternet: self.replyErr(callId, "This device is not online.")
                case .cannotFindHost, .dnsLookupFailed: self.replyErr(callId, "That name could not be found. Is this device online?")
                case .timedOut: self.replyErr(callId, "That address did not answer in time.")
                case .cannotConnectToHost: self.replyErr(callId, "Nothing answered at that address (is the program there running?).")
                default: self.replyErr(callId, e.localizedDescription)
                }
            } catch {
                self.replyErr(callId, "\(error)")
            }
        }
        netLock.lock(); netTasks[req] = task; netLock.unlock()
    }

    // MARK: engine work (engine queue)

    private func doLoad(_ callId: String, _ args: [String: Any]) {
        let id = args["id"] as? String ?? ""
        let nCtx = max(512, min((args["n_ctx"] as? Int) ?? 4096, maxCtx))
        if model != nil, id == loadedId, nCtx == loadedCtx, let info = loadedInfo {
            replyOk(callId, info)
            return
        }
        freeModel()
        guard let path = library.path(for: id) else {
            replyErr(callId, "That model's file is missing from the app.")
            return
        }
        var last = Date.distantPast
        let report: (Float) -> Void = { p in
            let now = Date()
            if now.timeIntervalSince(last) > 0.15 || p >= 1 {
                last = now
                self.emit(["type": "load-progress", "fraction": p])
            }
        }
        do {
            let m: EngineModel
            do {
                m = try EngineModel.load(path: path, nCtx: nCtx, threads: threads, gpuLayers: gpuLayers, progress: report)
            } catch let first where gpuLayers > 0 {
                // the graphics chip could not take this model: run it on the processor instead
                print("Ingenium: the graphics chip could not load the model (\(first)); using the processor")
                last = Date.distantPast
                m = try EngineModel.load(path: path, nCtx: nCtx, threads: threads, gpuLayers: 0, progress: report)
            }
            modelLock.lock(); model = m; modelLock.unlock()
            loadedId = id
            loadedCtx = nCtx
            loadedInfo = m.info
            replyOk(callId, loadedInfo ?? [:])
        } catch {
            replyErr(callId, "\(error)")
        }
    }

    private func doGenerate(_ callId: String, _ args: [String: Any]) {
        guard let m = model else { replyErr(callId, "No model is loaded."); return }
        let req = args["req"] as? String ?? ""
        let msgs = jsonString(args["messages"] ?? [Any]()) ?? "[]"
        let params = jsonString(args["params"] ?? [String: Any]()) ?? "{}"
        var answer = "", thinking = ""
        var lastFlush = Date()
        func flush() {
            if !thinking.isEmpty { emit(["type": "piece", "req": req, "kind": 1, "text": thinking]); thinking = "" }
            if !answer.isEmpty { emit(["type": "piece", "req": req, "kind": 0, "text": answer]); answer = "" }
        }
        do {
            let stats = try m.generate(messagesJSON: msgs, paramsJSON: params) { kind, text in
                if kind == 1 { thinking += text } else { answer += text }
                if Date().timeIntervalSince(lastFlush) >= 0.06 { lastFlush = Date(); flush() }
            }
            flush()
            replyOk(callId, stats)
        } catch {
            flush()
            replyErr(callId, "\(error)")
        }
    }

    private func freeModel() {
        modelLock.lock(); let m = model; model = nil; modelLock.unlock()
        m?.free()
        loadedId = nil
        loadedInfo = nil
    }

    // MARK: adding models (main thread)

    private func openPicker(_ callId: String) {
        guard importCallId == nil else { replyErr(callId, "A file chooser is already open."); return }
        guard let host = host else { replyErr(callId, "The app window is not ready."); return }
        importCallId = callId
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data, UTType.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        host.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let save = savePicker, controller === save.picker {
            savePicker = nil
            try? FileManager.default.removeItem(at: save.url)
            replyOk(save.callId, ["ok": true])
            return
        }
        guard let callId = importCallId else { return }
        importCallId = nil
        ioQueue.async {
            var added = [[String: Any]](), failed = [[String: Any]]()
            for (i, url) in urls.enumerated() {
                let name = url.lastPathComponent
                self.emit(["type": "import-progress", "name": name, "fraction": Double(i) / Double(max(1, urls.count))])
                do {
                    added.append(try self.library.importFile(at: url, originalName: name))
                } catch let f as ModelLibrary.ImportFailure {
                    failed.append(["name": f.name, "reason": f.reason])
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    failed.append(["name": name, "reason": "\(error)"])
                }
            }
            self.replyOk(callId, ["added": added, "failed": failed])
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let save = savePicker, controller === save.picker {
            savePicker = nil
            try? FileManager.default.removeItem(at: save.url)
            replyErr(save.callId, "Saving was cancelled.")
            return
        }
        if let callId = importCallId {
            importCallId = nil
            replyOk(callId, ["added": [Any](), "failed": [Any](), "cancelled": true])
        }
    }

    // MARK: saving files from the page (main thread)

    private func saveFile(_ callId: String, _ args: [String: Any]) {
        guard savePicker == nil else { replyErr(callId, "A save is already open."); return }
        guard let host = host, let b64 = args["b64"] as? String, let data = Data(base64Encoded: b64) else {
            replyErr(callId, "Nothing to save.")
            return
        }
        var name = (args["name"] as? String) ?? "ingenium-export"
        name = name.replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ingenium-save", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch {
            replyErr(callId, "The file could not be prepared: \(error.localizedDescription)")
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self
        savePicker = (callId, url, picker)
        host.present(picker, animated: true)
    }

    // MARK: device facts

    private var totalRam: UInt64 { ProcessInfo.processInfo.physicalMemory }

    private var gpuLayers: Int {
        #if targetEnvironment(simulator)
        return 0      // the simulator's graphics are not the device's; use the processor there
        #else
        return 999    // every layer on the Apple graphics chip
        #endif
    }

    private var threads: Int {
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0) == 0, perf > 0 {
            return max(2, min(4, Int(perf)))
        }
        return max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    private var maxCtx: Int {
        let gb = totalRam >> 30
        if gb >= 8 { return 16384 }
        if gb >= 5 { return 8192 }
        return 4096
    }

    private func machine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func info() -> [String: Any] {
        let v = EngineModel.version
        let short = v.components(separatedBy: " | ").first ?? v
        var dev: [String: Any] = [
            "ramGB": (Double(totalRam) / Double(1 << 30) * 10).rounded() / 10,
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "model": machine(),
            "maker": "Apple",
        ]
        DispatchQueue.main.sync {
            dev["os"] = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
            dev["kind"] = UIDevice.current.model
        }
        return ["engine": v, "engineShort": short, "available": true, "platform": "apple",
                "threads": threads, "gpu": gpuLayers > 0, "maxCtx": maxCtx, "device": dev, "net": true]
    }

    // MARK: plumbing

    private func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func replyOk(_ callId: String, _ result: Any) {
        emit(["type": "reply", "callId": callId, "ok": true, "result": result])
    }

    private func replyErr(_ callId: String, _ error: String) {
        emit(["type": "reply", "callId": callId, "ok": false, "error": error])
    }

    private func emit(_ ev: [String: Any]) {
        // the event travels as a JavaScript string literal: JSON text, encoded as JSON
        guard let json = jsonString(ev), let lit = jsonString([json]) else { return }
        let js = "window.__ingNativeEvent&&window.__ingNativeEvent(" + String(lit.dropFirst().dropLast()) + ")"
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js, completionHandler: nil) }
    }
}
