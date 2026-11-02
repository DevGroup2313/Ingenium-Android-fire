// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// The app's own model library on iPhone and iPad.
//   - The built-in models ship inside the app (Models/ in the bundle) and are
//     read in place. "Removing" one hides it; it can come back at any time.
//     R70: Models/builtin.json may list several; an app from before had one.
//   - Models the person adds live in the app's Documents/Models folder, which
//     the Files app shows (On My iPhone > Ingenium > Models). A .gguf copied
//     there by hand is picked up the next time the list is read.
//   - R70: models of Ingenium's lineup download from Hugging Face into that
//     folder (a broken download resumes) and are kept only when their SHA-256
//     fingerprint matches.

import CryptoKit
import Foundation

final class ModelLibrary {
    static let builtinId = "builtin"              // the first built-in model (the only one before R70)
    static let builtinPrefix = "builtin:"         // R70: "builtin:<file>" for each built-in model

    struct ImportFailure: Error {
        let name: String
        let reason: String
    }

    struct Cancelled: Error {}

    private let fm = FileManager.default
    private let lock = NSLock()
    let modelsDir: URL
    private let supportDir: URL
    private let indexURL: URL
    private let builtins: [[String: Any]]

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modelsDir = docs.appendingPathComponent("Models", isDirectory: true)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = support
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("ingenium-models.json")
        var list = [[String: Any]]()
        if let url = Bundle.main.url(forResource: "builtin", withExtension: "json", subdirectory: "Models"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ms = obj["models"] as? [[String: Any]] {
                list = ms.filter { !(($0["file"] as? String) ?? "").isEmpty }
            } else if !((obj["file"] as? String) ?? "").isEmpty {
                list = [obj]   // the one-model form of an app from before R70
            }
        }
        builtins = list
        // R72: a conversion stopped by the app closing leaves its .part behind
        if let left = try? fm.contentsOfDirectory(atPath: support.path) {
            for n in left where n.hasPrefix("c") && n.hasSuffix(".gguf.part") {
                try? fm.removeItem(at: support.appendingPathComponent(n))
            }
        }
    }

    // MARK: index

    private func readIndex() -> [String: Any] {
        if let data = try? Data(contentsOf: indexURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return ["models": [[String: Any]](), "builtinHidden": false]
    }

    private func writeIndex(_ idx: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: idx)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: built-in

    private func builtinURL(_ cfg: [String: Any]) -> URL? {
        guard let file = cfg["file"] as? String else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent("Models").appendingPathComponent(file)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private static func builtinIdFor(_ cfg: [String: Any]) -> String {
        builtinPrefix + ((cfg["file"] as? String) ?? "")
    }

    /// The built-in model an id names: "builtin:<file>", or "builtin" for the first.
    private func builtinFor(_ id: String) -> [String: Any]? {
        if id == ModelLibrary.builtinId { return builtins.first }
        guard id.hasPrefix(ModelLibrary.builtinPrefix) else { return nil }
        let f = String(id.dropFirst(ModelLibrary.builtinPrefix.count))
        return builtins.first(where: { ($0["file"] as? String) == f })
    }

    /// Files of the built-in models the person has hidden.
    private func hiddenFiles(_ idx: [String: Any]) -> [String] {
        var out = (idx["hiddenBuiltins"] as? [String]) ?? []
        // before R70 there was one built-in model and one switch for it
        if (idx["builtinHidden"] as? Bool) == true, let f = builtins.first?["file"] as? String, !out.contains(f) {
            out.append(f)
        }
        return out
    }

    var builtinName: String { builtins.first?["name"] as? String ?? "Built-in model" }

    // MARK: queries

    func list() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        var changed = false
        var models = (idx["models"] as? [[String: Any]]) ?? []

        // keep only entries whose files are still there
        let before = models.count
        models = models.filter { m in
            guard let f = m["file"] as? String else { return false }
            return fm.fileExists(atPath: modelsDir.appendingPathComponent(f).path)
        }
        if models.count != before { changed = true }

        // pick up any .gguf put into the folder by hand (Files app, Finder)
        let known = Set(models.compactMap { $0["file"] as? String })
        let files = (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        for f in files where f.lowercased().hasSuffix(".gguf") && !known.contains(f) {
            let url = modelsDir.appendingPathComponent(f)
            guard let meta = EngineModel.inspect(path: url.path), (meta["is_projector"] as? Bool) != true else { continue }
            models.append(entry(id: "f" + ModelLibrary.stableId(f), file: f, fileName: f, meta: meta))
            changed = true
        }

        var out = [[String: Any]]()
        let hidden = hiddenFiles(idx)
        var metas = (idx["builtinMetas"] as? [String: Any]) ?? [:]
        var anyPresent = false
        var hiddenNames = [String]()
        for cfg in builtins {
            guard let url = builtinURL(cfg), let file = cfg["file"] as? String else { continue }
            anyPresent = true
            if hidden.contains(file) {
                hiddenNames.append(cfg["name"] as? String ?? file)
                continue
            }
            var meta = metas[file] as? [String: Any]
            if meta == nil, let m = EngineModel.inspect(path: url.path) {
                meta = m
                metas[file] = m
                idx["builtinMetas"] = metas
                changed = true
            }
            var e = entry(id: ModelLibrary.builtinIdFor(cfg), file: file, fileName: file, meta: meta)
            e["name"] = cfg["name"] as? String ?? file
            e["builtIn"] = true
            e["size"] = fileSize(url)
            if let lu = cfg["lineup"] as? String, !lu.isEmpty { e["lineup"] = lu }
            out.append(e)
        }
        for var m in models {
            m["builtIn"] = false
            if let f = m["file"] as? String { m["size"] = fileSize(modelsDir.appendingPathComponent(f)) }
            out.append(m)
        }
        if changed {
            idx["models"] = models
            try? writeIndex(idx)
        }
        let firstId = builtins.first.map { ModelLibrary.builtinIdFor($0) } ?? ModelLibrary.builtinId
        return [
            "models": out,
            "builtin": ["available": anyPresent, "hidden": !hiddenNames.isEmpty, "id": firstId,
                        "name": hiddenNames.isEmpty ? builtinName : hiddenNames.joined(separator: ", ")],
        ]
    }

    func path(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cfg = builtinFor(id) { return builtinURL(cfg)?.path }
        if id == ModelLibrary.builtinId || id.hasPrefix(ModelLibrary.builtinPrefix) { return nil }
        let models = (readIndex()["models"] as? [[String: Any]]) ?? []
        guard let m = models.first(where: { ($0["id"] as? String) == id }), let f = m["file"] as? String else { return nil }
        let url = modelsDir.appendingPathComponent(f)
        return fm.fileExists(atPath: url.path) ? url.path : nil
    }

    // MARK: changes

    func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        if let cfg = builtinFor(id), let file = cfg["file"] as? String {
            var hidden = hiddenFiles(idx)
            if !hidden.contains(file) { hidden.append(file) }
            idx["hiddenBuiltins"] = hidden
            idx.removeValue(forKey: "builtinHidden")
            try writeIndex(idx)
            return
        }
        var models = (idx["models"] as? [[String: Any]]) ?? []
        guard let i = models.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw EngineError.failed("That model is no longer in the library.")
        }
        if let f = models[i]["file"] as? String {
            try? fm.removeItem(at: modelsDir.appendingPathComponent(f))
        }
        models.remove(at: i)
        idx["models"] = models
        try writeIndex(idx)
    }

    func restoreBuiltIn() throws {
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        idx["builtinHidden"] = false
        idx["hiddenBuiltins"] = [String]()
        try writeIndex(idx)
    }

    /// Takes in a file the person picked (already a private copy) and files it in the library.
    func importFile(at source: URL, originalName: String) throws -> [String: Any] {
        let name = originalName
        // the first four bytes of every GGUF file are the letters GGUF
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            throw ImportFailure(name: name, reason: "the file could not be opened")
        }
        let magic = handle.readData(ofLength: 4)
        try? handle.close()
        guard magic == Data("GGUF".utf8) else {
            throw ImportFailure(name: name, reason: "it is not a GGUF model file. Ingenium runs GGUF models; other formats need converting to GGUF first")
        }
        guard let meta = EngineModel.inspect(path: source.path) else {
            throw ImportFailure(name: name, reason: "it starts like a GGUF file but could not be read; it may be damaged or incomplete")
        }
        if (meta["is_projector"] as? Bool) == true {
            throw ImportFailure(name: name, reason: "it is a vision projector (mmproj), not a chat model on its own")
        }
        var file = name.lowercased().hasSuffix(".gguf") ? name : name + ".gguf"
        file = file.replacingOccurrences(of: "/", with: "_")
        var dest = modelsDir.appendingPathComponent(file)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = modelsDir.appendingPathComponent(file.replacingOccurrences(of: ".gguf", with: " \(n).gguf"))
            n += 1
        }
        do {
            try fm.moveItem(at: source, to: dest)
        } catch {
            do { try fm.copyItem(at: source, to: dest) } catch {
                throw ImportFailure(name: name, reason: "it could not be copied into the app (\(error.localizedDescription))")
            }
        }
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        var models = (idx["models"] as? [[String: Any]]) ?? []
        let e = entry(id: "m" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36),
                      file: dest.lastPathComponent, fileName: name, meta: meta)
        models.append(e)
        idx["models"] = models
        try? writeIndex(idx)
        return e
    }

    // MARK: R72, converted models

    /* A model the page converted (from safetensors, PyTorch or MLX files) comes
       in pieces: begin, write... end. The pieces go into a .part file beside the
       app's own data, so an app closed part way leaves nothing in Files; at the
       end the file must be the size announced and start like a GGUF, and it
       joins the library like an imported model. */
    private struct Writer { let handle: FileHandle; let part: URL; let name: String; let size: Int64 }
    private var writers = [String: Writer]()
    private let writerLock = NSLock()

    func writeBegin(name: String, size: Int64) throws -> String {
        if size > 0, let free = (try? modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < size + 64 * 1024 * 1024 {
            throw ImportFailure(name: name, reason: "there is not enough free space: the converted model needs about \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        let id = "c" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<4096), radix: 36)
        let part = supportDir.appendingPathComponent(id + ".gguf.part")
        _ = fm.createFile(atPath: part.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: part) else {
            throw ImportFailure(name: name, reason: "the file could not be started")
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        writerLock.lock(); writers[id] = Writer(handle: h, part: part, name: clean.isEmpty ? "Converted model" : clean, size: size); writerLock.unlock()
        return id
    }

    func writeChunk(id: String, data: Data) throws -> Int64 {
        writerLock.lock(); let w = writers[id]; writerLock.unlock()
        guard let w = w else { throw ImportFailure(name: "The model", reason: "that conversion is no longer open") }
        do {
            try w.handle.seekToEnd()
            try w.handle.write(contentsOf: data)
            return Int64(try w.handle.offset())
        } catch {
            writeAbort(id: id)
            throw ImportFailure(name: w.name, reason: "the file could not be written (\(error.localizedDescription))")
        }
    }

    func writeAbort(id: String) {
        writerLock.lock(); let w = writers.removeValue(forKey: id); writerLock.unlock()
        guard let w = w else { return }
        try? w.handle.close()
        try? fm.removeItem(at: w.part)
    }

    func writeEnd(id: String) throws -> [String: Any] {
        writerLock.lock(); let w = writers.removeValue(forKey: id); writerLock.unlock()
        guard let w = w else { throw ImportFailure(name: "The model", reason: "the conversion was not open") }
        try? w.handle.close()
        if w.size > 0 && fileSize(w.part) != w.size {
            try? fm.removeItem(at: w.part)
            throw ImportFailure(name: w.name, reason: "the converted file came out the wrong size")
        }
        let head = (try? FileHandle(forReadingFrom: w.part)).map { h -> Data in let d = h.readData(ofLength: 4); try? h.close(); return d } ?? Data()
        guard head == Data("GGUF".utf8) else {
            try? fm.removeItem(at: w.part)
            throw ImportFailure(name: w.name, reason: "the converted file is not a GGUF file")
        }
        let dest = modelsDir.appendingPathComponent(id + ".gguf")
        do { try fm.moveItem(at: w.part, to: dest) } catch {
            try? fm.removeItem(at: w.part)
            throw ImportFailure(name: w.name, reason: "the converted file could not be put in place")
        }
        guard let meta = EngineModel.inspect(path: dest.path) else {
            try? fm.removeItem(at: dest)
            throw ImportFailure(name: w.name, reason: "the engine could not read the converted file")
        }
        var e = entry(id: id, file: dest.lastPathComponent, fileName: w.name + ".gguf", meta: meta)
        e["name"] = w.name
        e["converted"] = true
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        var models = (idx["models"] as? [[String: Any]]) ?? []
        models.append(e)
        idx["models"] = models
        try? writeIndex(idx)
        return e
    }

    // MARK: R70, lineup downloads

    /// Downloads a model of Ingenium's lineup into the library. spec: key, url,
    /// sha256, size, file, name, tiers. Only Hugging Face addresses are taken; a
    /// broken download resumes from where it stopped, and the file is kept only
    /// when its SHA-256 matches. Blocks; run it off the main thread. cancelled
    /// is asked often; the part already fetched stays for the next try.
    func install(spec: [String: Any], progress: @escaping (Int64, Int64, String) -> Void,
                 cancelled: @escaping () -> Bool) throws -> [String: Any] {
        let key = spec["key"] as? String ?? ""
        let urlString = spec["url"] as? String ?? ""
        let sha = (spec["sha256"] as? String ?? "").lowercased()
        let file = spec["file"] as? String ?? ""
        let name = spec["name"] as? String ?? file
        let size = (spec["size"] as? NSNumber)?.int64Value ?? -1
        guard urlString.hasPrefix("https://huggingface.co/"), let url = URL(string: urlString),
              sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              file.range(of: "^[A-Za-z0-9._-]{1,200}\\.gguf$", options: .regularExpression) != nil, size > 0 else {
            throw ImportFailure(name: name, reason: "the request did not name a model of Ingenium's lineup properly")
        }
        // already here: the same fingerprint
        lock.lock()
        let existing = ((readIndex()["models"] as? [[String: Any]]) ?? []).first(where: { m in
            (m["sha256"] as? String) == sha && fileSize(modelsDir.appendingPathComponent(m["file"] as? String ?? "")) == size
        })
        lock.unlock()
        if let e = existing { return e }

        let part = supportDir.appendingPathComponent(String(sha.prefix(16)) + ".dl.part")
        var have = fm.fileExists(atPath: part.path) ? fileSize(part) : 0
        if have > size { try? fm.removeItem(at: part); have = 0 }
        let free = (try? modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if free < size - have + 64 * 1024 * 1024 {
            throw ImportFailure(name: name, reason: String(format: "there is not enough free space on this device (%.1f GB needed, %.1f GB free)",
                                                           Double(size - have) / 1e9, Double(free) / 1e9))
        }
        var hasher = SHA256()
        if have > 0 {   // the part fetched before counts towards the fingerprint
            progress(have, size, "resume")
            if let h = try? FileHandle(forReadingFrom: part) {
                var done: Int64 = 0
                while done < have {
                    if cancelled() { try? h.close(); throw Cancelled() }
                    let chunk = h.readData(ofLength: Int(min(Int64(4 << 20), have - done)))
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    done += Int64(chunk.count)
                }
                try? h.close()
                if done != have { try? fm.removeItem(at: part); have = 0; hasher = SHA256() }
            } else {
                try? fm.removeItem(at: part); have = 0
            }
        }
        var lastErr = ""
        var attempt = 0
        while have < size && attempt < 6 {
            attempt += 1
            if cancelled() { throw Cancelled() }
            let d = ModelDownload(url: url, part: part, size: size, have: have, hasher: hasher, progress: progress, cancelled: cancelled)
            let r = d.run()
            have = r.have
            hasher = r.hasher
            if r.cancelled { throw Cancelled() }
            if let e = r.error { lastErr = e }
            if r.fatal { break }
            if have < size { Thread.sleep(forTimeInterval: min(16, pow(2, Double(attempt)))) }
        }
        if have != size {
            throw ImportFailure(name: name, reason: "the download stopped part way (\(lastErr.isEmpty ? "no reason given" : lastErr)). Install again to carry on from where it stopped.")
        }
        progress(have, size, "verify")
        let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if got != sha {
            try? fm.removeItem(at: part)
            throw ImportFailure(name: name, reason: "the downloaded file does not match its SHA-256 fingerprint, so it was deleted")
        }
        let id = "l" + String(sha.prefix(12))
        let dest = modelsDir.appendingPathComponent(id + ".gguf")
        let meta = EngineModel.inspect(path: part.path)
        lock.lock(); defer { lock.unlock() }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: part, to: dest)
        } catch {
            throw ImportFailure(name: name, reason: "the download could not be finished (\(error.localizedDescription))")
        }
        var e = entry(id: id, file: dest.lastPathComponent, fileName: file, meta: meta)
        e["name"] = name
        e["size"] = size
        e["sha256"] = sha
        e["lineup"] = key
        if let tiers = spec["tiers"] as? [String] { e["tiers"] = tiers }
        var idx = readIndex()
        var models = (idx["models"] as? [[String: Any]]) ?? []
        models.append(e)
        idx["models"] = models
        try? writeIndex(idx)
        return e
    }

    // MARK: helpers

    /// The same short id for the same file name on every launch (FNV-1a).
    static func stableId(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    private func entry(id: String, file: String, fileName: String, meta: [String: Any]?) -> [String: Any] {
        var e: [String: Any] = ["id": id, "file": file, "fileName": fileName, "name": ModelLibrary.niceName(fileName, meta)]
        if let m = meta {
            e["arch"] = m["arch"] ?? ""
            e["ctxTrain"] = m["ctx_train"] ?? 0
            e["layers"] = m["layers"] ?? 0
            e["sizeLabel"] = m["size_label"] ?? ""
        }
        return e
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func niceName(_ fileName: String, _ meta: [String: Any]?) -> String {
        if let m = meta {
            let base = ((m["basename"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let size = ((m["size_label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !base.isEmpty {
                let withSize = size.isEmpty || base.lowercased().contains(size.lowercased()) ? base : base + " " + size
                return withSize
                    .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            }
            let nm = ((m["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !nm.isEmpty, nm.range(of: "^[0-9a-fA-F]{24,}$", options: .regularExpression) == nil { return nm }
        }
        var n = fileName.replacingOccurrences(of: "\\.gguf$", with: "", options: [.regularExpression, .caseInsensitive])
        n = n.replacingOccurrences(of: "[-_.](i?q\\d[a-z0-9_]*|f16|f32|bf16|fp16)$", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        n = n.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "New model" : n
    }
}

/// One attempt at a lineup download: streams the file into its .part with a
/// Range request (carrying on from what is there), feeding the fingerprint as
/// the bytes come. Blocks until the attempt ends.
final class ModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // the delegate queue alone writes the fields below, until finished is signalled
    struct Result {
        var have: Int64
        var hasher: SHA256
        var error: String?
        var fatal: Bool
        var cancelled: Bool
    }

    private let url: URL
    private let part: URL
    private let size: Int64
    private var have: Int64
    private var hasher: SHA256
    private let progress: (Int64, Int64, String) -> Void
    private let cancelled: () -> Bool
    private var handle: FileHandle?
    private var error: String?
    private var fatal = false
    private var lastTick = Date.distantPast
    private let finished = DispatchSemaphore(value: 0)

    init(url: URL, part: URL, size: Int64, have: Int64, hasher: SHA256, progress: @escaping (Int64, Int64, String) -> Void,
         cancelled: @escaping () -> Bool) {
        self.url = url
        self.part = part
        self.size = size
        self.have = have
        self.hasher = hasher
        self.progress = progress
        self.cancelled = cancelled
    }

    func run() -> Result {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Ingenium", forHTTPHeaderField: "User-Agent")
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: req)
        task.resume()
        var wasCancelled = false
        while finished.wait(timeout: .now() + 0.5) == .timedOut {
            if cancelled() && !wasCancelled { wasCancelled = true; task.cancel() }
        }
        session.finishTasksAndInvalidate()
        // the last delegate call (didCompleteWithError) signalled finished after its writes
        return Result(have: have, hasher: hasher, error: error, fatal: fatal, cancelled: wasCancelled || cancelled())
    }

    // How the bytes are written is decided when the first of them arrives,
    // from the last response: some systems report each redirect on the way
    // as a response of its own before the real one.
    private var status = 0

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code >= 400 || code == 0 {
            error = "the server answered \(code)"
            fatal = code == 401 || code == 403 || code == 404
            completionHandler(.cancel)
            return
        }
        if code == 206, let cr = http?.value(forHTTPHeaderField: "Content-Range"),
           let m = cr.range(of: "^bytes ([0-9]+)-", options: .regularExpression) {
            let start = Int64(cr[m].dropFirst(6).dropLast()) ?? -1
            if start != have {   // not where this copy stops: try again
                error = "the server sent the wrong part of the file"
                completionHandler(.cancel)
                return
            }
        }
        status = code
        completionHandler(.allow)
    }

    private func openPart() -> Bool {
        if status == 200 && have > 0 {   // the server sent the whole file again: start over
            have = 0
            hasher = SHA256()
            try? FileManager.default.removeItem(at: part)
        }
        if !FileManager.default.fileExists(atPath: part.path) {
            _ = FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: part) else { return false }
        do { try h.truncate(atOffset: UInt64(have)) } catch { try? h.close(); return false }
        _ = try? h.seekToEnd()
        handle = h
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if handle == nil && !openPart() {
            error = "the download could not be written"
            fatal = true
            dataTask.cancel()
            return
        }
        guard let h = handle else { return }
        if have + Int64(data.count) > size {
            error = "the file is larger than expected"
            fatal = true
            dataTask.cancel()
            return
        }
        do { try h.write(contentsOf: data) } catch {
            self.error = "the download could not be written (\(error.localizedDescription))"
            fatal = true
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        have += Int64(data.count)
        if cancelled() {   // the person pressed Cancel: stop at once, keeping what is here
            dataTask.cancel()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastTick) > 0.3 {
            lastTick = now
            progress(have, size, "download")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        try? handle?.close()
        handle = nil
        if let e = err as NSError?, e.code != NSURLErrorCancelled, error == nil {
            error = e.code == NSURLErrorNotConnectedToInternet || e.code == NSURLErrorCannotFindHost
                ? "Hugging Face could not be reached (is this device online?)" : e.localizedDescription
        }
        finished.signal()
    }
}
