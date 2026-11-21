/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   Ingenium 7.64 · Ingenium itself, signed and checked, part two, on Fire tablets and Android: what SelfCore checks, read from this app.
   Its copy is in its assets (ingenium.html and each carried-<id>.txt, written there by tools/app_page.py at the build); its release and the
   owner's public keys in assets/self.json (written by release.py at each release); her signatures, brought in from Settings, Security,
   Ingenium itself, in the app's own files (signatures/ingenium-mobile-<edition>-<version>-<fingerprint>.ingsig). At the start, only a device
   that keeps a signature reads its copy (MainActivity.startPage); one with none opens at once. A fault in the check itself never keeps
   Ingenium closed: it opens as before, and the log says why.
*/
package com.yannieforest.ingenium;

import android.content.Context;
import android.content.res.AssetManager;
import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

final class SelfCheck {
    private static final Charset UTF8 = Charset.forName("UTF-8");

    private SelfCheck() {}

    /** the device, as the room and the refusal page name it */
    static String platform(Context c) {
        if ("Amazon".equalsIgnoreCase(Build.MANUFACTURER)) return "Fire tablet";
        return c.getResources().getConfiguration().smallestScreenWidthDp >= 600 ? "Android tablet" : "Android phone";
    }

    static String asset(Context c, String name) throws IOException {
        try (InputStream in = c.getAssets().open(name)) { return new String(all(in), UTF8); }
    }

    static SelfCore.Keys keys(Context c) {
        try { return SelfCore.keys(asset(c, "self.json")); } catch (Exception e) { return SelfCore.keys("{\"release\":\"\",\"keys\":[]}"); }
    }

    /** the copy as this app carries it: the page and each carried-<id>.txt beside it in the assets */
    static Map<String, SelfCore.Read> copy(Context c) throws IOException {
        AssetManager am = c.getAssets();
        TreeMap<String, SelfCore.Read> m = new TreeMap<String, SelfCore.Read>();
        String[] names = am.list("");
        if (names != null) {
            Arrays.sort(names);
            for (String n : names) {
                if (!n.equals(SelfCore.PAGE) && !(n.startsWith("carried-") && n.endsWith(".txt"))) continue;
                try (InputStream in = am.open(n, AssetManager.ACCESS_STREAMING)) { m.put(n, SelfCore.read(in, n.equals(SelfCore.PAGE))); }
            }
        }
        return m;
    }

    static File dir(Context c) { return new File(c.getFilesDir(), "signatures"); }

    static boolean hasKept(Context c) {
        File[] fs = dir(c).listFiles();
        if (fs != null) for (File f : fs) if (f.getName().startsWith("ingenium-mobile-") && f.getName().endsWith(".ingsig")) return true;
        return false;
    }

    static List<SelfCore.Sig> kept(Context c, SelfCore.Keys k) {
        List<SelfCore.Sig> out = new ArrayList<SelfCore.Sig>();
        File[] fs = dir(c).listFiles();
        if (fs == null) return out;
        for (File f : fs) {
            if (!f.getName().startsWith("ingenium-mobile-") || !f.getName().endsWith(".ingsig") || f.length() > 65536) continue;
            try (InputStream in = new java.io.FileInputStream(f)) {
                SelfCore.Sig s = SelfCore.kept(new String(all(in), UTF8), f.getName(), k);
                if (s != null) out.add(s);
            } catch (Exception ignored) { }
        }
        return out;
    }

    static TreeMap<String, Object> state(Context c) throws IOException {
        SelfCore.Keys k = keys(c);
        return SelfCore.state(copy(c), k, kept(c, k), platform(c));
    }

    /** Bring a signature in: kept only when it is hers and names this very copy */
    static TreeMap<String, Object> put(Context c, String text) throws IOException {
        if (text == null || text.length() > 65536) {
            TreeMap<String, Object> no = new TreeMap<String, Object>();
            no.put("ok", Boolean.FALSE); no.put("error", "That file is not a signature of Ingenium.");
            return no;
        }
        TreeMap<String, Object> r = SelfCore.put(text, copy(c), keys(c), platform(c));
        if (Boolean.TRUE.equals(r.get("ok"))) {
            File d = dir(c);
            if (!d.isDirectory() && !d.mkdirs()) throw new IOException("the app's files cannot be written");
            File f = new File(d, (String) r.get("name"));
            try (FileOutputStream o = new FileOutputStream(f)) { o.write(((String) r.remove("keep")).getBytes(UTF8)); }
        }
        r.remove("keep");
        return r;
    }

    /** the newest signature kept for this release, as text */
    static TreeMap<String, Object> get(Context c) {
        TreeMap<String, Object> r = new TreeMap<String, Object>();
        SelfCore.Keys k = keys(c);
        SelfCore.Sig best = null;
        for (SelfCore.Sig s : kept(c, k)) if (k.release.equals(s.body.get("version")) && (best == null || ((String) s.body.get("made")).compareTo((String) best.body.get("made")) > 0)) best = s;
        if (best == null) { r.put("ok", Boolean.FALSE); r.put("error", "No signature is kept for this copy."); return r; }
        r.put("ok", Boolean.TRUE); r.put("name", best.name); r.put("text", best.text);
        return r;
    }

    private static byte[] all(InputStream in) throws IOException {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        byte[] b = new byte[1 << 14];
        int n;
        while ((n = in.read(b)) > 0) o.write(b, 0, n);
        return o.toByteArray();
    }
}
