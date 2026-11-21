// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// Ingenium 7.64 · the iPhone and iPad app's own check of its copy (ingenium_ios_project/Ingenium/SelfCore.swift), run on a Mac at each
// build against the same cases as the Fire app's SelfCore.java (tools/selftest/vectors, made by rig/t_764_self_core.py in the
// Ingenium-Mac-Mini repository with a throwaway test key, never the owner's, and the computer app's own reading of the copy).
//   swiftc -O -o selftest ingenium_ios_project/Ingenium/SelfCore.swift tools/selftest/main.swift && ./selftest tools/selftest/vectors

import Foundation

var ok = 0, bad = 0
func check(_ c: Bool, _ what: String, _ more: Any = "") {
    if c { ok += 1; print("PASS " + what) } else { bad += 1; print("FAIL " + what + "  " + String(describing: more)) }
}
let v = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/selftest/vectors")
func text(_ name: String, in dir: URL = v) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

func readCopy(_ dir: URL) -> [String: SelfCore.Read] {
    var m: [String: SelfCore.Read] = [:]
    for n in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    where n == SelfCore.page || (n.hasPrefix("carried-") && n.hasSuffix(".txt")) {
        if let r = SelfCore.read(dir.appendingPathComponent(n), page: n == SelfCore.page) { m[n] = r }
    }
    return m
}
func kept(_ dir: URL, _ k: SelfCore.Keys) -> [SelfCore.Sig] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".ingsig") }.compactMap {
        SelfCore.kept(text($0, in: dir), name: $0, keys: k)
    }
}

let k = SelfCore.keys(try? Data(contentsOf: v.appendingPathComponent("self.json")))
check(k.release == "7.64" && k.keys.count == 1, "self.json: the release and the owner's public keys are read", k.release)
let now = readCopy(v.appendingPathComponent("copy"))
let fields = (try? JSONSerialization.jsonObject(with: Data(text("fields.json").utf8))) as? [String: [String: Any]] ?? [:]
var same = fields.count == now.count && !fields.isEmpty
for (n, f) in fields { if now[n]?.sha256 != f["sha256"] as? String || now[n]?.size != (f["size"] as? Int) { same = false } }
check(same, "the copy as this app reads it (its stamped build number left out) is the copy the computer signs", now.mapValues { $0.sha256 })
let pg = now[SelfCore.page]
check(pg?.version == "7.64" && pg?.edition == "master" && pg?.build == "7.64.20261121.258", "the page's version and edition are read, and the build number it carries",
      [pg?.version, pg?.edition, pg?.build])

let keptDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-kept-\(getpid())")
try? FileManager.default.removeItem(at: keptDir)
try? FileManager.default.createDirectory(at: keptDir, withIntermediateDirectories: true)
var st = SelfCore.state(now: now, keys: k, kept: kept(keptDir, k), platform: "iPhone")
check(st["state"] as? String == "unsigned" && st["mobile"] as? Bool == true && st["platform"] as? String == "iPhone", "nothing kept: Not signed yet", st)

for (file, what) in [("other_key.json", "another key's"), ("changed_sig.json", "one changed after signing"), ("other_version.json", "one for another version"),
                     ("other_copy.json", "one for another copy"), ("desk_only.json", "one of the computer apps' kind"),
                     ("list_desk_only.json", "a file with no signature for phones and tablets"), ("junk.json", "a file that is not a signature")] {
    let p = SelfCore.put(text(file), now: now, keys: k, platform: "iPhone")
    check(p["ok"] as? Bool == false && p["error"] is String, "Bring a signature in: \(what) is refused (\(p["error"] ?? ""))", p)
}
for file in ["mobile.json", "list.json"] {
    let p = SelfCore.put(text(file), now: now, keys: k, platform: "iPhone")
    let name = p["name"] as? String ?? ""
    let good = p["ok"] as? Bool == true && p["keep"] is String && name.hasPrefix("ingenium-mobile-master-7.64-")
    check(good, "Bring a signature in: " + (file == "list.json" ? "the file with both signatures in it" : "the signature alone") + " is taken: " + name, p)
    if good { try? (p["keep"] as! String).write(to: keptDir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
}
st = SelfCore.state(now: now, keys: k, kept: kept(keptDir, k), platform: "iPhone")
check(st["state"] as? String == "signed" && (st["signed"] as? [String: Any])?["made"] as? String == "2026-11-21T21:00:00.000Z", "kept and checked: Signed, with the day it was made", st)

let changed = readCopy(v.appendingPathComponent("changed"))
st = SelfCore.state(now: changed, keys: k, kept: kept(keptDir, k), platform: "iPhone")
var ch = st["changed"] as? [[String: Any]] ?? []
check(st["state"] as? String == "changed" && ch.count == 1 && ch.first?["name"] as? String == "ingenium.html" && ch.first?["why"] as? String == "content",
      "one byte of the page changed: the state is changed, naming the page", st)
let tpl = text("self_refused.html")
var html = SelfCore.refusal(tpl, st, platform: "iPhone")
let wantFp = SelfCore.fp((ch.first?["want"] as? [String: Any])?["sha256"] as? String ?? ""), nowFp = SelfCore.fp((ch.first?["now"] as? [String: Any])?["sha256"] as? String ?? "")
check(html.contains("not the one you signed on 21 November 2026") && html.contains(wantFp) && html.contains(nowFp) && html.contains("this iPhone") && !html.contains("{{"),
      "the refusal page: the day signed, the file, both fingerprints, this device", html.count)

st = SelfCore.state(now: readCopy(v.appendingPathComponent("missing")), keys: k, kept: kept(keptDir, k), platform: "iPad")
ch = st["changed"] as? [[String: Any]] ?? []
check(st["state"] as? String == "changed" && ch.count == 1 && ch.first?["why"] as? String == "missing", "a carried file taken away: changed, and it is named missing", st)
html = SelfCore.refusal(tpl, st, platform: "iPad")
check(html.contains("a file of it is missing") && html.contains("this iPad"), "and the refusal page says a file is missing", html.count)

st = SelfCore.state(now: readCopy(v.appendingPathComponent("older")), keys: k, kept: kept(keptDir, k), platform: "iPhone")
ch = st["changed"] as? [[String: Any]] ?? []
check(st["state"] as? String == "changed" && ch.count == 1 && ch.first?["why"] as? String == "version", "a page naming another version, against this release's signature: changed (version)", st)

let k2 = keptDir.appendingPathComponent("edited", isDirectory: true)
try? FileManager.default.createDirectory(at: k2, withIntermediateDirectories: true)
if let first = ((try? FileManager.default.contentsOfDirectory(atPath: keptDir.path)) ?? []).first(where: { $0.hasSuffix(".ingsig") }) {
    try? text(first, in: keptDir).replacingOccurrences(of: "\"master\"", with: "\"gift\"").write(to: k2.appendingPathComponent("ingenium-mobile-gift-7.64-x.ingsig"), atomically: true, encoding: .utf8)
}
st = SelfCore.state(now: now, keys: k, kept: kept(k2, k), platform: "iPhone")
check(st["state"] as? String == "unsigned", "a kept signature edited by hand no longer counts: Not signed yet", st)

// the room receives the state as JSON: every answer must be one JSONSerialization writes
check(JSONSerialization.isValidJSONObject(SelfCore.state(now: changed, keys: k, kept: kept(keptDir, k), platform: "iPhone")), "the state the room receives is valid JSON")
try? FileManager.default.removeItem(at: keptDir)
print("\(ok) passed, \(bad) failed")
exit(bad == 0 ? 0 : 1)
