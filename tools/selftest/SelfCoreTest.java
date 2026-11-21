/*
   Ingenium 7.64 · the Fire and Android app's own check of its copy (SelfCore.java, in the Fire and iPhone repository), run on a computer
   against what rig/t_764_self_core.py makes: a phone's copy made by tools/app_page.py with a build number stamped in, the owner's
   public keys (a test key's), and signatures made with that key (never the owner's). Prints PASS and FAIL lines, then "n passed, m failed".
     java -cp <classes> com.yannieforest.ingenium.SelfCoreTest <vectors folder>
*/
package com.yannieforest.ingenium;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public final class SelfCoreTest {
    static int ok, bad;
    static final Charset UTF8 = Charset.forName("UTF-8");

    static void check(boolean c, String what, Object more) {
        if (c) { ok++; System.out.println("PASS " + what); }
        else { bad++; System.out.println("FAIL " + what + "  " + String.valueOf(more)); }
    }

    static String text(File f) throws Exception { return new String(Files.readAllBytes(f.toPath()), UTF8); }

    /** the copy as the app reads it: ingenium.html and each carried-<id>.txt in the folder */
    static Map<String, SelfCore.Read> readCopy(File dir) throws Exception {
        TreeMap<String, SelfCore.Read> m = new TreeMap<String, SelfCore.Read>();
        String[] names = dir.list();
        java.util.Arrays.sort(names);
        for (String n : names) {
            if (!n.equals(SelfCore.PAGE) && !(n.startsWith("carried-") && n.endsWith(".txt"))) continue;
            try (InputStream in = new FileInputStream(new File(dir, n))) { m.put(n, SelfCore.read(in, n.equals(SelfCore.PAGE))); }
        }
        return m;
    }

    static List<SelfCore.Sig> keptIn(File dir, SelfCore.Keys k) throws Exception {
        List<SelfCore.Sig> out = new ArrayList<SelfCore.Sig>();
        File[] fs = dir.listFiles();
        if (fs != null) for (File f : fs) if (f.getName().endsWith(".ingsig")) { SelfCore.Sig s = SelfCore.kept(text(f), f.getName(), k); if (s != null) out.add(s); }
        return out;
    }

    public static void main(String[] a) throws Exception {
        File v = new File(a[0]);
        SelfCore.Keys k = SelfCore.keys(text(new File(v, "self.json")));
        check(k.release.equals("7.64") && k.keys.size() == 1, "self.json: the release and the owner's public keys are read", k.release + " " + k.keys.size());
        File copy = new File(v, "copy");
        Map<String, SelfCore.Read> now = readCopy(copy);
        Object want = new SelfCore.Json(text(new File(v, "fields.json"))).whole();
        TreeMap<String, Object> mine = SelfCore.files(now);
        check(SelfCore.json(mine).equals(SelfCore.json(want)), "the copy as this app reads it (its stamped build number left out) is the copy the computer signs", SelfCore.json(mine) + " vs " + SelfCore.json(want));
        SelfCore.Read pg = now.get(SelfCore.PAGE);
        check(pg != null && pg.version.equals("7.64") && pg.edition.equals("master") && pg.build.equals("7.64.20261121.258"),
              "the page's version and edition are read, and the build number it carries", pg == null ? null : pg.version + " " + pg.edition + " " + pg.build);

        // nothing kept: unsigned
        File kept = new File(v, "kept");
        kept.mkdirs();
        TreeMap<String, Object> st = SelfCore.state(now, k, keptIn(kept, k), "Fire tablet");
        check("unsigned".equals(st.get("state")) && Boolean.TRUE.equals(st.get("mobile")) && "Fire tablet".equals(st.get("platform")), "nothing kept: Not signed yet", SelfCore.json(st));

        // refused, nothing kept
        String[][] refuse = {{"other_key.json", "another key's"}, {"changed_sig.json", "one changed after signing"}, {"other_version.json", "one for another version"},
                             {"other_copy.json", "one for another copy"}, {"desk_only.json", "one of the computer apps' kind"}, {"list_desk_only.json", "a file with no signature for phones and tablets"},
                             {"junk.json", "a file that is not a signature"}};
        for (String[] r : refuse) {
            TreeMap<String, Object> p = SelfCore.put(text(new File(v, r[0])), now, k, "Fire tablet");
            check(Boolean.FALSE.equals(p.get("ok")) && p.get("error") instanceof String, "Bring a signature in: " + r[1] + " is refused (" + p.get("error") + ")", SelfCore.json(p));
        }

        // the owner's signature, alone and in the file Save the signature makes
        for (String n : new String[]{"mobile.json", "list.json"}) {
            TreeMap<String, Object> p = SelfCore.put(text(new File(v, n)), now, k, "Fire tablet");
            boolean good = Boolean.TRUE.equals(p.get("ok")) && p.get("keep") instanceof String && String.valueOf(p.get("name")).startsWith("ingenium-mobile-master-7.64-");
            check(good, "Bring a signature in: " + (n.equals("list.json") ? "the file with both signatures in it" : "the signature alone") + " is taken: " + p.get("name"), SelfCore.json(p));
            if (good) Files.write(new File(kept, (String) p.get("name")).toPath(), ((String) p.get("keep")).getBytes(UTF8));
        }
        st = SelfCore.state(now, k, keptIn(kept, k), "Fire tablet");
        check("signed".equals(st.get("state")) && st.get("signed") instanceof Map && "2026-11-21T21:00:00.000Z".equals(((Map<?, ?>) st.get("signed")).get("made")),
              "kept and checked: Signed, with the day it was made", SelfCore.json(st));

        // the same copy, one byte changed: changed, and the refusal page says which file and both fingerprints
        File changed = new File(v, "changed");
        Map<String, SelfCore.Read> now2 = readCopy(changed);
        st = SelfCore.state(now2, k, keptIn(kept, k), "Fire tablet");
        List<?> ch = (List<?>) st.get("changed");
        check("changed".equals(st.get("state")) && ch.size() == 1 && "ingenium.html".equals(((Map<?, ?>) ch.get(0)).get("name")) && "content".equals(((Map<?, ?>) ch.get(0)).get("why")),
              "one byte of the page changed: the state is changed, naming the page", SelfCore.json(st));
        String html = SelfCore.refusal(text(new File(v, "self_refused.html")), st, "Fire tablet");
        String wantFp = SelfCore.fp(((Map<?, ?>) ((Map<?, ?>) ch.get(0)).get("want")).get("sha256")), nowFp = SelfCore.fp(((Map<?, ?>) ((Map<?, ?>) ch.get(0)).get("now")).get("sha256"));
        check(html.contains("not the one you signed on 21 November 2026") && html.contains(wantFp) && html.contains(nowFp) && html.contains("this Fire tablet")
              && !html.contains("{{"), "the refusal page: the day signed, the file, both fingerprints, this device", html.length());

        // a carried file taken away: changed (missing)
        File missing = new File(v, "missing");
        st = SelfCore.state(readCopy(missing), k, keptIn(kept, k), "iPhone");
        ch = (List<?>) st.get("changed");
        check("changed".equals(st.get("state")) && ch.size() == 1 && "missing".equals(((Map<?, ?>) ch.get(0)).get("why")), "a carried file taken away: changed, and it is named missing", SelfCore.json(st));
        html = SelfCore.refusal(text(new File(v, "self_refused.html")), st, "iPhone");
        check(html.contains("a file of it is missing") && html.contains("this iPhone"), "and the refusal page says a file is missing", html.length());

        // a copy of another version, with a signature of this app's release kept: changed (version)
        File older = new File(v, "older");
        st = SelfCore.state(readCopy(older), k, keptIn(kept, k), "Fire tablet");
        ch = (List<?>) st.get("changed");
        check("changed".equals(st.get("state")) && ch.size() == 1 && "version".equals(((Map<?, ?>) ch.get(0)).get("why")), "a page naming another version, against this release's signature: changed (version)", SelfCore.json(st));

        // a kept file edited by hand stops counting
        File k2 = new File(v, "kept2");
        k2.mkdirs();
        String t = text(new File(kept, kept.list()[0])).replace("\"master\"", "\"gift\"");
        Files.write(new File(k2, "ingenium-mobile-gift-7.64-x.ingsig").toPath(), t.getBytes(UTF8));
        st = SelfCore.state(now, k, keptIn(k2, k), "Fire tablet");
        check("unsigned".equals(st.get("state")), "a kept signature edited by hand no longer counts: Not signed yet", SelfCore.json(st));

        // on a real phone's copy made from a release page (when given)
        File real = new File(v, "real");
        if (real.isDirectory()) {
            long t0 = System.currentTimeMillis();
            Map<String, SelfCore.Read> rn = readCopy(real);
            long ms = System.currentTimeMillis() - t0;
            Object rw = new SelfCore.Json(text(new File(v, "real_fields.json"))).whole();
            check(SelfCore.json(SelfCore.files(rn)).equals(SelfCore.json(rw)), "a real release's phone copy reads as the computer signs it (" + rn.size() + " file, read in " + ms + " ms)", SelfCore.json(SelfCore.files(rn)));
        }
        System.out.println(ok + " passed, " + bad + " failed");
        System.exit(bad == 0 ? 0 : 1);
    }
}
