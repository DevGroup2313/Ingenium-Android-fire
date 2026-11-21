// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// Ingenium 7.64 · Ingenium itself, signed and checked, part two, on iPhone and iPad: what SelfCore checks, read from this app. Its copy is
// in the app (ingenium.html and each carried-<id>.txt, written there by tools/app_page.py at the build); its release and the owner's
// public keys in self.json (written by release.py at each release); her signatures, brought in from Settings, Security, Ingenium itself,
// in the app's own Application Support (signatures/ingenium-mobile-<edition>-<version>-<fingerprint>.ingsig). At the start only a device
// that keeps a signature reads its copy (WebViewController.startPage); one with none opens at once. A fault in the check itself never
// keeps Ingenium closed: it opens as before.

import UIKit

enum SelfStore {
    static var platform: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    static func bundled(_ name: String) -> Data? { try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent(name)) }

    static func keys() -> SelfCore.Keys { SelfCore.keys(bundled("self.json")) }

    static func copy() -> [String: SelfCore.Read] {
        var m: [String: SelfCore.Read] = [:]
        let base = Bundle.main.bundleURL
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
        for n in names where n == SelfCore.page || (n.hasPrefix("carried-") && n.hasSuffix(".txt")) {
            if let r = SelfCore.read(base.appendingPathComponent(n), page: n == SelfCore.page) { m[n] = r }
        }
        return m
    }

    static var dir: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return sup.appendingPathComponent("signatures", isDirectory: true)
    }

    static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("ingenium-mobile-") && $0.pathExtension == "ingsig" }
    }

    static var hasKept: Bool { !files().isEmpty }

    static func kept(_ k: SelfCore.Keys) -> [SelfCore.Sig] {
        files().compactMap { u in
            guard let d = try? Data(contentsOf: u), d.count <= 65536, let t = String(data: d, encoding: .utf8) else { return nil }
            return SelfCore.kept(t, name: u.lastPathComponent, keys: k)
        }
    }

    static func state() -> [String: Any] {
        let k = keys()
        return SelfCore.state(now: copy(), keys: k, kept: kept(k), platform: platform)
    }

    /// Bring a signature in: kept only when it is hers and names this very copy
    static func put(_ text: String) -> [String: Any] {
        guard text.utf8.count <= 65536 else { return ["ok": false, "error": "That file is not a signature of Ingenium."] }
        var r = SelfCore.put(text, now: copy(), keys: keys(), platform: platform)
        if (r["ok"] as? Bool) == true, let keep = r["keep"] as? String, let name = r["name"] as? String {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(keep.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
            } catch { return ["ok": false, "error": "The signature could not be kept: \(error.localizedDescription)"] }
        }
        r["keep"] = nil
        return r
    }

    /// the newest signature kept for this release, as text
    static func get() -> [String: Any] {
        let k = keys()
        guard let s = kept(k).filter({ $0.version == k.release }).sorted(by: { $0.made > $1.made }).first else { return ["ok": false, "error": "No signature is kept for this copy."] }
        return ["ok": true, "name": s.name, "text": s.text]
    }
}
