// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// Ingenium 7.64 · Ingenium itself, signed and checked, part two: the iPhone and iPad app's own check of its copy of the page, before
// anything of it runs. The same steps as the Fire app's SelfCore.java (which is tested on a computer against cases made with the
// computer app's own code, rig/t_764_self_core.py in the Ingenium-Mac-Mini repository), and as the shells' check of 7.62
// (SignatureCheck.swift: JSON read strictly, PermitCore's fixed order, ECDSA P-256 with SHA-256). No UIKit here, so tools/selftest
// runs this file on a Mac at each build.
//   signed     a signature of hers names this app's release and edition, and every file it names is as it was signed
//   changed    a signature of hers names this app's release (else the version the page names), and the copy is not the one signed
//   unsigned   no signature of hers is kept for it: the page opens, and Security says Not signed yet

import Foundation
import CryptoKit

enum SelfCore {
    static let page = "ingenium.html"
    static let kind = "ingenium-release-signature", body = "ingenium-release", app = "ingenium-mobile", list = "ingenium-release-signatures"
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    // MARK: one file of the copy, as the computer reads it

    struct Read { let sha256: String; let size: Int; let version: String; let edition: String; let build: String }

    static let buildTag = Array("<meta name=\"ingenium-build\" content=\"".utf8), verPre = Array("var ING_VERSION=\"".utf8), edPre = Array("var ING_EDITION=\"".utf8)

    /// a file read whole and hashed; for the page, the build number in its first build tag (in its first MiB) left out, and the version and
    /// edition it names read (the first of each)
    static func read(_ url: URL, page isPage: Bool) -> Read? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var md = SHA256()
        var size = 0
        var head = [UInt8]()
        while head.count < (1 << 20) {
            let d = h.readData(ofLength: (1 << 20) - head.count)
            if d.isEmpty { break }
            head += [UInt8](d)
        }
        var build = ""
        if isPage, let r = findBuild(head) {
            build = String(decoding: head[r], as: UTF8.self)
            md.update(data: Data(head[0..<r.lowerBound])); md.update(data: Data(head[r.upperBound...]))
            size += head.count - r.count
        } else { md.update(data: Data(head)); size += head.count }
        var sv = Scan(pre: verPre, ver: true), se = Scan(pre: edPre, ver: false)
        if isPage { sv.feed(head); se.feed(head) }
        while true {
            let d = h.readData(ofLength: 1 << 16)
            if d.isEmpty { break }
            md.update(data: d); size += d.count
            if isPage { let b = [UInt8](d); if sv.found == nil { sv.feed(b) }; if se.found == nil { se.feed(b) } }
        }
        let hex = md.finalize().map { String(format: "%02x", $0) }.joined()
        return Read(sha256: hex, size: size, version: isPage ? (sv.found ?? "") : "", edition: isPage ? (se.found ?? "master") : "", build: build)
    }

    static func findBuild(_ h: [UInt8]) -> Range<Int>? {
        var from = 0
        while let i = indexOf(h, buildTag, from) {
            let s = i + buildTag.count
            var k = s
            while k < h.count && k - s <= 40 && isBuildChar(h[k]) { k += 1 }
            if k - s <= 40 && k + 1 < h.count && h[k] == 0x22 && h[k + 1] == 0x3E { return s..<k }
            from = i + 1
        }
        return nil
    }

    static func isBuildChar(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2E || b == 0x2D }

    struct Scan {
        let pre: [UInt8]; let ver: Bool; var found: String? = nil; var carry = [UInt8]()
        init(pre: [UInt8], ver: Bool) { self.pre = pre; self.ver = ver }
        mutating func feed(_ b: [UInt8]) {
            let w = carry + b
            var from = 0
            while found == nil, let i = SelfCore.indexOf(w, pre, from) {
                from = i + 1
                let s = i + pre.count
                var k = s
                if ver {
                    guard k < w.count else { carry = Array(w[i...]); return }
                    guard w[k] >= 0x30 && w[k] <= 0x39 else { continue }
                    k += 1
                    while k < w.count && k - s < 16 && ((w[k] >= 0x30 && w[k] <= 0x39) || w[k] == 0x2E) { k += 1 }
                } else {
                    while k < w.count && k - s < 16 && w[k] >= 0x61 && w[k] <= 0x7A { k += 1 }
                }
                if k >= w.count { carry = Array(w[i...]); return }
                if w[k] == 0x22 && k > s { found = String(decoding: w[s..<k], as: UTF8.self) }
            }
            carry = Array(w[max(0, w.count - pre.count - 18)...])
        }
    }

    static func indexOf(_ h: [UInt8], _ p: [UInt8], _ from: Int) -> Int? {
        if p.isEmpty || h.count < p.count { return nil }
        var i = max(0, from)
        let first = p[0]
        while i <= h.count - p.count {
            if h[i] == first {
                var j = 1
                while j < p.count && h[i + j] == p[j] { j += 1 }
                if j == p.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func fileOf(_ r: Read) -> [String: Any] { ["sha256": r.sha256, "size": r.size] }

    // MARK: the owner's public keys and this app's release (self.json, written by release.py)

    struct Keys { let release: String; let keys: [(kid: String, x: String, y: String)] }

    static func keys(_ data: Data?) -> Keys {
        guard let d = data, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return Keys(release: "", keys: []) }
        var ks: [(kid: String, x: String, y: String)] = []
        for k in (o["keys"] as? [[String: Any]]) ?? [] {
            if let kid = k["kid"] as? String, let x = k["x"] as? String, let y = k["y"] as? String { ks.append((kid, x, y)) }
        }
        return Keys(release: o["release"] as? String ?? "", keys: ks)
    }

    // MARK: a signature of hers

    struct Sig {
        let version: String, edition: String, made: String, kid: String, name: String, text: String
        let files: [String: (sha256: String, size: Int)]
    }

    static func kept(_ text: String, name: String, keys k: Keys) -> Sig? {
        var j = Json(Array(text.utf16))
        guard let o = j.whole() else { return nil }
        var why = ""
        return verified(o, keys: k, name: name, why: &why)
    }

    static func verified(_ o: J, keys k: Keys, name: String, why: inout String) -> Sig? {
        let notOne = "This is not a signature of Ingenium."
        guard case .obj(let f) = o, str(field(f, "kind")) == kind, isOne(field(f, "v")), case .obj(let b)? = field(f, "release") else { why = notOne; return nil }
        guard str(field(b, "app")) == app else {
            why = str(field(b, "app")) == "ingenium" ? "This signature is for the computer apps. Bring in the file Save the signature made on your computer: it holds the one for phones and tablets too." : "This signature is for another copy of Ingenium."
            return nil
        }
        guard let files = bodyOk(b) else { why = "This signature does not hold the fields of a release of Ingenium."; return nil }
        guard let kid = str(field(f, "kid")), let key = k.keys.first(where: { $0.kid == kid }) else { why = "It is not signed with one of the owner's keys this copy carries."; return nil }
        guard let sigText = str(field(f, "sig")), let rs = b64u(sigText), rs.count == 64, let x = b64u(key.x), let y = b64u(key.y), x.count == 32, y.count == 32,
              let pub = try? P256.Signing.PublicKey(rawRepresentation: x + y), let sig = try? P256.Signing.ECDSASignature(rawRepresentation: rs) else {
            why = "Its signature cannot be read."; return nil
        }
        var c = [UInt16]()
        guard canon(.obj(b), &c), pub.isValidSignature(sig, for: Data(String(decoding: c, as: UTF16.self).utf8)) else {
            why = "Its signature does not match: it was changed, or it is not the owner's."; return nil
        }
        var t = [UInt16]()
        guard canon(o, &t) else { why = notOne; return nil }
        return Sig(version: str(field(b, "version"))!, edition: str(field(b, "edition"))!, made: str(field(b, "made"))!, kid: kid, name: name,
                   text: String(decoding: t, as: UTF16.self), files: files)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    /// the release's fields as a release carries them; its files, or nil
    static func bodyOk(_ b: [([UInt16], J)]) -> [String: (sha256: String, size: Int)]? {
        var names = Set<String>()
        for (k, _) in b { names.insert(String(decoding: k, as: UTF16.self)) }
        guard names == ["kind", "v", "app", "version", "edition", "files", "made"], b.count == 7 else { return nil }
        guard str(field(b, "kind")) == body, isOne(field(b, "v")),
              let v = str(field(b, "version")), matches(v, "^[0-9]{1,3}(\\.[0-9]{1,3}){1,3}$"),
              let e = str(field(b, "edition")), matches(e, "^[a-z]{1,16}$"),
              let m = str(field(b, "made")), matches(m, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z$"),
              case .obj(let fs)? = field(b, "files"), fs.count >= 1, fs.count <= 32 else { return nil }
        var out: [String: (sha256: String, size: Int)] = [:]
        for (k, x) in fs {
            let n = String(decoding: k, as: UTF16.self)
            guard matches(n, "^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$"), !n.contains(".."), !n.contains("//"), case .obj(let fx) = x, fx.count == 2,
                  let h = str(field(fx, "sha256")), isHex64(h), case .num(let sz)? = field(fx, "size"), sz >= 0, sz < 9007199254740992, sz == sz.rounded() else { return nil }
            out[n] = (h, Int(sz))
        }
        return out
    }

    // MARK: the check

    static func state(now: [String: Read], keys k: Keys, kept: [Sig], platform: String) -> [String: Any] {
        let pg = now[page]
        let ver = pg?.version ?? "", ed = pg?.edition ?? "master"
        var st: [String: Any] = ["ok": true, "mobile": true, "platform": platform, "version": ver, "edition": ed, "build": pg?.build ?? "",
                                 "release": k.release, "files": pg.map { [page: fileOf($0)] } ?? [:], "keys": k.keys.map { $0.kid },
                                 "own": false, "refused": [Any](), "can": true]
        guard let s = pick(kept, k.release) ?? pick(kept, ver) else { st["state"] = "unsigned"; return st }
        st["signed"] = ["made": s.made, "kid": s.kid, "version": s.version, "edition": s.edition]
        let ch = changes(s, now: now, ver: ver, ed: ed)
        if ch.isEmpty { st["state"] = "signed" } else { st["state"] = "changed"; st["changed"] = ch }
        return st
    }

    static func pick(_ kept: [Sig], _ version: String) -> Sig? {
        if version.isEmpty { return nil }
        return kept.filter { $0.version == version }.sorted { $0.made > $1.made }.first
    }

    static func changes(_ s: Sig, now: [String: Read], ver: String, ed: String) -> [[String: Any]] {
        if s.version != ver { return [["name": page, "why": "version", "want": ["version": s.version], "now": ["version": ver]]] }
        if s.edition != ed { return [["name": page, "why": "edition", "want": ["edition": s.edition], "now": ["edition": ed]]] }
        var out: [[String: Any]] = []
        for name in s.files.keys.sorted() {
            let w = s.files[name]!
            let want: [String: Any] = ["sha256": w.sha256, "size": w.size]
            if let r = now[name] {
                if r.sha256 != w.sha256 || r.size != w.size { out.append(["name": name, "why": "content", "want": want, "now": fileOf(r)]) }
            } else { out.append(["name": name, "why": "missing", "want": want, "now": NSNull()]) }
        }
        return out
    }

    /// Bring a signature in: alone or in the file Save the signature makes; kept only when it names this very copy
    static func put(_ text: String, now: [String: Read], keys k: Keys, platform: String) -> [String: Any] {
        var j = Json(Array(text.utf16))
        guard let o = j.whole() else { return ["ok": false, "error": "This is not a signature of Ingenium."] }
        var cands: [J] = []
        if case .obj(let f) = o, str(field(f, "kind")) == list, isOne(field(f, "v")), case .arr(let a)? = field(f, "signatures") {
            for x in a { if case .obj(let xf) = x, case .obj(let xb)? = field(xf, "release"), str(field(xb, "app")) == app { cands.append(x) } }
            if cands.isEmpty { return ["ok": false, "error": "This file holds no signature for phones and tablets. Sign it for your phones and tablets on your computer, then save the signature again."] }
        } else { cands.append(o) }
        var err = "This is not a signature of Ingenium."
        let pg = now[page]
        let ver = pg?.version ?? "", ed = pg?.edition ?? "master"
        for c in cands {
            var why = ""
            guard let s = verified(c, keys: k, name: "", why: &why) else { err = why; continue }
            if s.version != ver { err = "This signature is for Ingenium \(s.version), and this \(platform) runs \(ver.isEmpty ? "another version" : ver)."; continue }
            if s.edition != ed { err = "This signature is for the \(s.edition) edition, and this \(platform) runs the \(ed) edition."; continue }
            let ch = changes(s, now: now, ver: ver, ed: ed)
            if let first = ch.first { err = "This signature is for another copy of Ingenium: \(first["name"] as? String ?? page) here is not the one signed."; continue }
            let sha = s.files[page]?.sha256 ?? String(repeating: "0", count: 12)
            let name = "ingenium-mobile-\(s.edition)-\(s.version)-\(sha.prefix(12)).ingsig"
            var out = state(now: now, keys: k, kept: [s], platform: platform)
            out["ok"] = true; out["keep"] = s.text; out["name"] = name
            return out
        }
        return ["ok": false, "error": err]
    }

    // MARK: the page the app shows in Ingenium's place (self_refused.html)

    static func refusal(_ tpl: String, _ st: [String: Any], platform: String) -> String {
        let day = SelfCore.day((st["signed"] as? [String: Any])?["made"] as? String ?? "")
        var rows = ""
        var reason = "a file in it changed since"
        for c in (st["changed"] as? [[String: Any]]) ?? [] {
            let why = c["why"] as? String ?? ""
            let w = c["want"] as? [String: Any] ?? [:], n = c["now"] as? [String: Any] ?? [:]
            rows += "<p class=\"nm\">" + esc(c["name"] as? String ?? "") + "</p>"
            switch why {
            case "version":
                reason = "it names another version of Ingenium"
                rows += "<p>It names Ingenium <b>" + esc("\(n["version"] ?? "")") + "</b>, and you signed <b>" + esc("\(w["version"] ?? "")") + "</b>: its page was put in from elsewhere.</p>"
            case "edition":
                reason = "it names another edition"
                rows += "<p>It names the <b>" + esc("\(n["edition"] ?? "")") + "</b> edition, and you signed the <b>" + esc("\(w["edition"] ?? "")") + "</b> edition: its page was put in from elsewhere.</p>"
            case "missing":
                reason = "a file of it is missing"
                rows += "<p>It is no longer there.</p>"
            default:
                rows += "<dl><dt>You signed</dt><dd><code>" + esc(fp(w["sha256"] as? String ?? "")) + "</code> · " + bytes(w["size"]) + " bytes</dd><dt>It is now</dt><dd><code>"
                    + esc(fp(n["sha256"] as? String ?? "")) + "</code> · " + bytes(n["size"]) + " bytes</dd></dl>"
            }
        }
        let lead = "This copy of Ingenium is not the one you signed" + (day.isEmpty ? "" : " on " + day) + ": " + reason + ". Nothing of it ran."
        return tpl.replacingOccurrences(of: "{{LEAD}}", with: esc(lead)).replacingOccurrences(of: "{{ROWS}}", with: rows).replacingOccurrences(of: "{{DEVICE}}", with: esc(platform))
    }

    static func fp(_ h: String) -> String {
        let u = Array(h)
        return u.count == 64 ? String(u[0..<8]) + " " + String(u[8..<16]) + " … " + String(u[56..<64]) : h
    }

    static func bytes(_ n: Any?) -> String {
        let v = (n as? Int) ?? Int((n as? Double) ?? 0)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func day(_ iso: String) -> String {
        let p = iso.split(separator: "T").first.map(String.init) ?? ""
        let a = p.split(separator: "-")
        guard a.count == 3, let y = Int(a[0]), let m = Int(a[1]), let d = Int(a[2]), m >= 1, m <= 12 else { return "" }
        return "\(d) \(months[m - 1]) \(y)"
    }

    static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c { case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"; case "'": o += "&#39;"; default: o.append(c) }
        }
        return o
    }

    // MARK: JSON read strictly, and canon (PermitCore's fixed order): the shells' own of 7.62

    indirect enum J { case null, bool(Bool), num(Double), str([UInt16]), arr([J]), obj([([UInt16], J)]) }

    struct Json {
        let s: [UInt16]
        var i = 0
        init(_ s: [UInt16]) { self.s = s }
        mutating func whole() -> J? { guard let v = value() else { return nil }; ws(); return i == s.count ? v : nil }
        mutating func ws() { while i < s.count && (s[i] == 0x20 || s[i] == 0x09 || s[i] == 0x0A || s[i] == 0x0D) { i += 1 } }
        mutating func lit(_ word: String) -> Bool {
            let u = Array(word.utf16)
            guard i + u.count <= s.count, Array(s[i..<(i + u.count)]) == u else { return false }
            i += u.count
            return true
        }
        mutating func value() -> J? {
            ws()
            guard i < s.count else { return nil }
            switch s[i] {
            case 0x7B: return object()
            case 0x5B: return array()
            case 0x22: if let t = string() { return .str(t) } else { return nil }
            default:
                if lit("true") { return .bool(true) }
                if lit("false") { return .bool(false) }
                if lit("null") { return .null }
                return number()
            }
        }
        mutating func object() -> J? {
            var o: [([UInt16], J)] = []
            i += 1; ws()
            if i < s.count && s[i] == 0x7D { i += 1; return .obj(o) }
            while true {
                ws()
                guard i < s.count, s[i] == 0x22, let k = string() else { return nil }
                ws()
                guard i < s.count, s[i] == 0x3A else { return nil }
                i += 1
                guard let v = value() else { return nil }
                o.append((k, v))
                ws()
                guard i < s.count else { return nil }
                let c = s[i]; i += 1
                if c == 0x7D { return .obj(o) }
                if c != 0x2C { return nil }
            }
        }
        mutating func array() -> J? {
            var a: [J] = []
            i += 1; ws()
            if i < s.count && s[i] == 0x5D { i += 1; return .arr(a) }
            while true {
                guard let v = value() else { return nil }
                a.append(v); ws()
                guard i < s.count else { return nil }
                let c = s[i]; i += 1
                if c == 0x5D { return .arr(a) }
                if c != 0x2C { return nil }
            }
        }
        mutating func string() -> [UInt16]? {
            var b: [UInt16] = []
            i += 1
            while true {
                guard i < s.count else { return nil }
                let c = s[i]; i += 1
                if c == 0x22 { return b }
                if c < 0x20 { return nil }
                if c != 0x5C { b.append(c); continue }
                guard i < s.count else { return nil }
                let e = s[i]; i += 1
                switch e {
                case 0x22: b.append(0x22)
                case 0x5C: b.append(0x5C)
                case 0x2F: b.append(0x2F)
                case 0x62: b.append(0x08)
                case 0x66: b.append(0x0C)
                case 0x6E: b.append(0x0A)
                case 0x72: b.append(0x0D)
                case 0x74: b.append(0x09)
                case 0x75:
                    guard i + 4 <= s.count else { return nil }
                    var v: UInt16 = 0
                    for k in 0..<4 {
                        let d = s[i + k]
                        var x: UInt16 = 0
                        if d >= 0x30 && d <= 0x39 { x = d - 0x30 } else if d >= 0x61 && d <= 0x66 { x = d - 0x61 + 10 } else if d >= 0x41 && d <= 0x46 { x = d - 0x41 + 10 } else { return nil }
                        v = v * 16 + x
                    }
                    i += 4
                    b.append(v)
                default: return nil
                }
            }
        }
        mutating func number() -> J? {
            let st = i
            if i < s.count && s[i] == 0x2D { i += 1 }
            guard i < s.count else { return nil }
            if s[i] == 0x30 { i += 1 } else if s[i] >= 0x31 && s[i] <= 0x39 { while i < s.count && s[i] >= 0x30 && s[i] <= 0x39 { i += 1 } } else { return nil }
            if i < s.count && s[i] == 0x2E {
                i += 1
                let d = i
                while i < s.count && s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
                if i == d { return nil }
            }
            if i < s.count && (s[i] == 0x65 || s[i] == 0x45) {
                i += 1
                if i < s.count && (s[i] == 0x2B || s[i] == 0x2D) { i += 1 }
                let d = i
                while i < s.count && s[i] >= 0x30 && s[i] <= 0x39 { i += 1 }
                if i == d { return nil }
            }
            guard let d = Double(String(decoding: s[st..<i], as: UTF16.self)) else { return nil }
            return .num(d)
        }
    }

    static func field(_ o: [([UInt16], J)], _ name: String) -> J? { let k = Array(name.utf16); return o.last(where: { $0.0 == k })?.1 }
    static func str(_ v: J?) -> String? { if case .str(let u)? = v { return String(decoding: u, as: UTF16.self) }; return nil }
    static func isOne(_ v: J?) -> Bool { if case .num(let d)? = v { return d == 1 }; return false }
    static func isHex64(_ h: String) -> Bool { let u = Array(h.utf8); return u.count == 64 && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) } }

    static func canon(_ v: J, _ out: inout [UInt16]) -> Bool {
        switch v {
        case .null: out += Array("null".utf16)
        case .bool(let b): out += Array((b ? "true" : "false").utf16)
        case .num(let d):
            guard let t = number(d) else { return false }
            out += Array(t.utf16)
        case .str(let t): quote(t, &out)
        case .arr(let a):
            out.append(0x5B)
            for (k, x) in a.enumerated() { if k > 0 { out.append(0x2C) }; if !canon(x, &out) { return false } }
            out.append(0x5D)
        case .obj(let o):
            var last: [[UInt16]: J] = [:]
            for (k, x) in o { last[k] = x }
            let keys = last.keys.sorted { $0.lexicographicallyPrecedes($1) }
            out.append(0x7B)
            for (k, name) in keys.enumerated() {
                if k > 0 { out.append(0x2C) }
                quote(name, &out)
                out.append(0x3A)
                if !canon(last[name]!, &out) { return false }
            }
            out.append(0x7D)
        }
        return true
    }

    static func number(_ d: Double) -> String? {
        guard d.isFinite, d == d.rounded(), abs(d) < 1e21 else { return nil }
        if d == 0 { return "0" }
        if abs(d) < 9.0e15 { return String(Int64(d)) }
        return String(format: "%.0f", d)
    }

    static func quote(_ s: [UInt16], _ out: inout [UInt16]) {
        out.append(0x22)
        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x08: out += [0x5C, 0x62]
            case 0x0C: out += [0x5C, 0x66]
            case 0x0A: out += [0x5C, 0x6E]
            case 0x0D: out += [0x5C, 0x72]
            case 0x09: out += [0x5C, 0x74]
            default:
                if c < 0x20 { u4(c, &out) }
                else if c >= 0xD800 && c <= 0xDBFF {
                    if i + 1 < s.count && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF { out.append(c); out.append(s[i + 1]); i += 1 } else { u4(c, &out) }
                } else if c >= 0xDC00 && c <= 0xDFFF { u4(c, &out) }
                else { out.append(c) }
            }
            i += 1
        }
        out.append(0x22)
    }

    static func u4(_ c: UInt16, _ out: inout [UInt16]) {
        let h = Array(String(c, radix: 16).utf16)
        out += [0x5C, 0x75]
        if h.count < 4 { for _ in h.count..<4 { out.append(0x30) } }
        out += h
    }

    static func b64u(_ s: String) -> Data? {
        let u = Array(s.utf8)
        if u.count % 4 == 1 { return nil }
        var out = Data(capacity: u.count * 6 / 8)
        var acc: UInt32 = 0, bits: UInt32 = 0
        for c in u {
            var v: UInt32 = 0
            if c >= 0x41 && c <= 0x5A { v = UInt32(c) - 0x41 } else if c >= 0x61 && c <= 0x7A { v = UInt32(c) - 0x61 + 26 }
            else if c >= 0x30 && c <= 0x39 { v = UInt32(c) - 0x30 + 52 } else if c == 0x2D { v = 62 } else if c == 0x5F { v = 63 } else { return nil }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xFF)); acc &= (1 << bits) - 1 }
        }
        return out
    }
}
