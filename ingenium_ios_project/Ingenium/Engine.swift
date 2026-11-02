// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// A thin Swift face for the shared native engine (native/ingenium_engine.h).
// Every call except abort() must come from the one engine queue.

import Foundation

enum EngineError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let m): return m
        }
    }
}

/// Boxes handed to the C callbacks as their `user` pointer.
private final class PieceSink {
    let onPiece: (Int32, String) -> Void
    init(_ f: @escaping (Int32, String) -> Void) { onPiece = f }
}

private final class ProgressSink {
    let onProgress: (Float) -> Void
    init(_ f: @escaping (Float) -> Void) { onProgress = f }
}

final class EngineModel {
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var freed = false

    private init(handle: OpaquePointer) { self.handle = handle }

    static func backendInit() {
        ie_backend_init { level, text in
            guard level >= 3, let text = text else { return }
            print("[engine] " + String(cString: text), terminator: "")
        }
    }

    static var version: String { String(cString: ie_version()) }

    /// GGUF metadata without loading the weights, or nil when the file is not a readable model.
    static func inspect(path: String) -> [String: Any]? {
        guard let p = ie_inspect(path, nil) else { return nil }
        defer { ie_free_str(p) }
        let s = String(cString: p)
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    static func load(path: String, nCtx: Int, threads: Int, gpuLayers: Int,
                     progress: @escaping (Float) -> Void) throws -> EngineModel {
        var params = ie_load_params(n_ctx: Int32(nCtx), n_threads: Int32(threads),
                                    n_gpu_layers: Int32(gpuLayers), use_mmap: true)
        let sink = Unmanaged.passRetained(ProgressSink(progress))
        defer { sink.release() }
        var err = [CChar](repeating: 0, count: 512)
        let cb: ie_progress_cb = { user, p in
            guard let user = user else { return true }
            Unmanaged<ProgressSink>.fromOpaque(user).takeUnretainedValue().onProgress(p)
            return true
        }
        let h = err.withUnsafeMutableBufferPointer { buf in
            ie_load(path, nil, &params, cb, sink.toOpaque(), buf.baseAddress, buf.count)
        }
        guard let handle = h else {
            throw EngineError.failed(String(cString: err))
        }
        return EngineModel(handle: handle)
    }

    var info: [String: Any] {
        guard let p = ie_model_info(handle) else { return [:] }
        defer { ie_free_str(p) }
        return ((try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8))) as? [String: Any]) ?? [:]
    }

    /// Streams one reply; kind 0 = answer, 1 = reasoning. Returns the statistics.
    func generate(messagesJSON: String, paramsJSON: String,
                  onPiece: @escaping (Int32, String) -> Void) throws -> [String: Any] {
        let sink = Unmanaged.passRetained(PieceSink(onPiece))
        defer { sink.release() }
        var err = [CChar](repeating: 0, count: 512)
        let cb: ie_piece_cb = { user, kind, text, len in
            guard let user = user, let text = text else { return }
            let data = Data(bytes: text, count: len)
            Unmanaged<PieceSink>.fromOpaque(user).takeUnretainedValue()
                .onPiece(kind, String(decoding: data, as: UTF8.self))
        }
        let stats = err.withUnsafeMutableBufferPointer { buf in
            ie_generate(handle, messagesJSON, paramsJSON, cb, sink.toOpaque(), buf.baseAddress, buf.count)
        }
        guard let s = stats else { throw EngineError.failed(String(cString: err)) }
        defer { ie_free_str(s) }
        return ((try? JSONSerialization.jsonObject(with: Data(String(cString: s).utf8))) as? [String: Any]) ?? [:]
    }

    /// Thread-safe: ends a running reply at its next step.
    func abort() {
        lock.lock(); defer { lock.unlock() }
        if !freed { ie_abort(handle) }
    }

    func free() {
        lock.lock()
        if freed { lock.unlock(); return }
        freed = true
        lock.unlock()
        ie_free(handle)
    }

    deinit { free() }
}
