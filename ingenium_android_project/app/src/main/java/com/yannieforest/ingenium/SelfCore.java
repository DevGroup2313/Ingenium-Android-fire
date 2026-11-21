/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   Ingenium 7.64 · Ingenium itself, signed and checked, part two: the Fire and Android app's own check of its copy of the page, before
   anything of it runs. Its copy is made from the release's page by tools/app_page.py (the engine and the kit store left out, each block
   carried for later written beside it as carried-<id>.txt, the build number stamped into the first <meta name="ingenium-build">); her
   master copy, on a computer, makes the same copy from its own page (desktop/app_self2_764.py in the Ingenium-Mac-Mini repository) and
   signs it with her owner key (the release's app "ingenium-mobile"). This app reads its copy as the computer does, with the stamped build
   number left out, and holds it against a signature of hers brought in here (Settings, Security, Ingenium itself, Bring a signature in).
   No Android in this file, so the same code is tested on a computer (rig/selfcore/SelfCoreTest.java) and at each build on GitHub
   (tools/selftest). The steps of the check are the shells' own of 7.62 (SignatureCheck: canon, JSON, ECDSA P-256 with SHA-256).
     signed     a signature of hers names this app's release and edition, and every file it names is as it was signed
     changed    a signature of hers names this app's release (else the version the page names), and the copy is not the one signed
     unsigned   no signature of hers is kept for it: the page opens, and Security says Not signed yet
*/
package com.yannieforest.ingenium;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.math.BigDecimal;
import java.nio.charset.Charset;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class SelfCore {
    public static final String PAGE = "ingenium.html";
    public static final String KIND = "ingenium-release-signature", BODY = "ingenium-release", APP = "ingenium-mobile", LIST = "ingenium-release-signatures";
    static final Charset UTF8 = Charset.forName("UTF-8");
    static final int HEAD = 1 << 20;
    static final Pattern V = Pattern.compile("^[0-9]{1,3}(\\.[0-9]{1,3}){1,3}$"), E = Pattern.compile("^[a-z]{1,16}$"),
        T = Pattern.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z$"), HEX = Pattern.compile("^[0-9a-f]{64}$"),
        NAME = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$"), KID = Pattern.compile("^[A-Za-z0-9_-]{1,64}$");
    static final String[] MONTHS = {"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};
    private static final byte[] SPKI_HEAD = {0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, (byte) 0x86, 0x48, (byte) 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, (byte) 0x86, 0x48, (byte) 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00};

    private SelfCore() {}

    /* ------------------------------------------------ one file of the copy, as the computer reads it */

    public static final class Read {
        public final String sha256, version, edition, build;
        public final long size;
        Read(String sha256, long size, String version, String edition, String build) {
            this.sha256 = sha256; this.size = size; this.version = version; this.edition = edition; this.build = build;
        }
    }

    private static final byte[] BUILD_TAG = ascii("<meta name=\"ingenium-build\" content=\""), VER = ascii("var ING_VERSION=\""), ED = ascii("var ING_EDITION=\"");

    /** a file of the copy, read whole and hashed; for the page, the build number in its first build tag (in its first MiB) is left out,
        and the version and edition it names are read (the first of each, as the computer reads them) */
    public static Read read(InputStream in, boolean page) throws IOException {
        MessageDigest md;
        try { md = MessageDigest.getInstance("SHA-256"); } catch (Exception e) { throw new IOException("no SHA-256 here"); }
        byte[] head = readUpTo(in, HEAD);
        long size = 0;
        String build = "", version = "", edition = "";
        int[] tag = page ? findBuild(head) : null;
        if (tag != null) {
            build = new String(head, tag[0], tag[1] - tag[0], UTF8);
            md.update(head, 0, tag[0]); md.update(head, tag[1], head.length - tag[1]);
            size += head.length - (tag[1] - tag[0]);
        } else { md.update(head); size += head.length; }
        Scanner sv = page ? new Scanner(VER, true) : null, se = page ? new Scanner(ED, false) : null;
        if (page) { sv.feed(head, head.length); se.feed(head, head.length); }
        byte[] buf = new byte[1 << 16];
        int n;
        while ((n = in.read(buf)) > 0) {
            md.update(buf, 0, n); size += n;
            if (page) { if (sv.found == null) sv.feed(buf, n); if (se.found == null) se.feed(buf, n); }
        }
        if (page) { version = sv.found == null ? "" : sv.found; edition = se.found == null ? "master" : se.found; }
        return new Read(hex(md.digest()), size, version, edition, build);
    }

    private static byte[] readUpTo(InputStream in, int max) throws IOException {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        byte[] b = new byte[1 << 16];
        while (o.size() < max) {
            int n = in.read(b, 0, Math.min(b.length, max - o.size()));
            if (n <= 0) break;
            o.write(b, 0, n);
        }
        return o.toByteArray();
    }

    /** the first build tag whose content is 0 to 40 letters, digits, dots and dashes: [start, end) of its content */
    static int[] findBuild(byte[] h) {
        for (int i = indexOf(h, BUILD_TAG, 0); i >= 0; i = indexOf(h, BUILD_TAG, i + 1)) {
            int s = i + BUILD_TAG.length, k = s;
            while (k < h.length && k - s <= 40 && isBuildChar(h[k])) k++;
            if (k - s <= 40 && k + 1 < h.length && h[k] == '"' && h[k + 1] == '>') return new int[]{s, k};
        }
        return null;
    }

    private static boolean isBuildChar(byte b) {
        return (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '.' || b == '-';
    }

    /** the first var ING_VERSION="…" or var ING_EDITION="…" with a value of the right shape, found across the chunks of a stream */
    private static final class Scanner {
        final byte[] pre; final boolean ver; String found; byte[] carry = new byte[0];
        Scanner(byte[] pre, boolean ver) { this.pre = pre; this.ver = ver; }
        void feed(byte[] b, int n) {
            byte[] w = new byte[carry.length + n];
            System.arraycopy(carry, 0, w, 0, carry.length); System.arraycopy(b, 0, w, carry.length, n);
            for (int i = indexOf(w, pre, 0); i >= 0 && found == null; i = indexOf(w, pre, i + 1)) {
                int s = i + pre.length, k = s, max = ver ? 16 : 16;
                if (ver) { if (k < w.length && w[k] >= '0' && w[k] <= '9') k++; else continue; while (k < w.length && k - s < max && ((w[k] >= '0' && w[k] <= '9') || w[k] == '.')) k++; }
                else while (k < w.length && k - s < max && w[k] >= 'a' && w[k] <= 'z') k++;
                if (k >= w.length) { carry = tail(w, i); return; }   /* the value runs on into the next chunk */
                if (w[k] == '"' && k > s) found = new String(w, s, k - s, UTF8);
            }
            carry = tail(w, Math.max(0, w.length - pre.length - 18));
        }
        private static byte[] tail(byte[] w, int from) { byte[] t = new byte[w.length - from]; System.arraycopy(w, from, t, 0, t.length); return t; }
    }

    private static int indexOf(byte[] h, byte[] p, int from) {
        outer:
        for (int i = Math.max(0, from); i <= h.length - p.length; i++) {
            for (int j = 0; j < p.length; j++) if (h[i + j] != p[j]) continue outer;
            return i;
        }
        return -1;
    }

    /** the copy's files as a signature names them: {name: {sha256, size}} */
    public static TreeMap<String, Object> files(Map<String, Read> now) {
        TreeMap<String, Object> out = new TreeMap<String, Object>();
        for (Map.Entry<String, Read> e : now.entrySet()) out.put(e.getKey(), fileOf(e.getValue()));
        return out;
    }

    static TreeMap<String, Object> fileOf(Read r) {
        TreeMap<String, Object> f = new TreeMap<String, Object>();
        f.put("sha256", r.sha256); f.put("size", (double) r.size);
        return f;
    }

    /* ------------------------------------------------ the owner's public keys and this app's release (self.json, written by release.py) */

    public static final class Keys {
        public final String release;
        public final List<String[]> keys;   /* {kid, x, y} */
        Keys(String release, List<String[]> keys) { this.release = release; this.keys = keys; }
        String[] find(String kid) { for (String[] k : keys) if (k[0].equals(kid)) return k; return null; }
        List<Object> kids() { List<Object> l = new ArrayList<Object>(); for (String[] k : keys) l.add(k[0]); return l; }
    }

    public static Keys keys(String selfJson) {
        Object o = new Json(selfJson).whole();
        List<String[]> ks = new ArrayList<String[]>();
        String rel = "";
        if (o instanceof TreeMap) {
            TreeMap<?, ?> m = (TreeMap<?, ?>) o;
            if (m.get("release") instanceof String) rel = (String) m.get("release");
            if (m.get("keys") instanceof List) for (Object k : (List<?>) m.get("keys")) {
                if (!(k instanceof TreeMap)) continue;
                TreeMap<?, ?> km = (TreeMap<?, ?>) k;
                if (km.get("kid") instanceof String && km.get("x") instanceof String && km.get("y") instanceof String)
                    ks.add(new String[]{(String) km.get("kid"), (String) km.get("x"), (String) km.get("y")});
            }
        }
        return new Keys(rel, ks);
    }

    /* ------------------------------------------------ a signature of hers */

    public static final class Sig {
        public final TreeMap<String, Object> body;
        public final String kid, name, text;
        Sig(TreeMap<String, Object> body, String kid, String name, String text) { this.body = body; this.kid = kid; this.name = name; this.text = text; }
        String version() { return (String) body.get("version"); }
        String edition() { return (String) body.get("edition"); }
        String made() { return (String) body.get("made"); }
        @SuppressWarnings("unchecked") TreeMap<String, Object> files() { return (TreeMap<String, Object>) body.get("files"); }
    }

    /** a signature kept here: counted only when it is of the copy for phones and tablets, and hers; else null */
    public static Sig kept(String text, String name, Keys k) {
        try { Object o = new Json(text).whole(); String[] why = new String[1]; return verified(o, k, name, why); } catch (Exception e) { return null; }
    }

    /** null with why[0] when the object is not a signature of hers of the copy for phones and tablets */
    @SuppressWarnings("unchecked")
    static Sig verified(Object o, Keys k, String name, String[] why) {
        if (!(o instanceof TreeMap)) { why[0] = "This is not a signature of Ingenium."; return null; }
        TreeMap<String, Object> f = (TreeMap<String, Object>) o;
        if (!KIND.equals(f.get("kind")) || !isOne(f.get("v"))) { why[0] = "This is not a signature of Ingenium."; return null; }
        if (!(f.get("release") instanceof TreeMap)) { why[0] = "This is not a signature of Ingenium."; return null; }
        TreeMap<String, Object> b = (TreeMap<String, Object>) f.get("release");
        if (!APP.equals(b.get("app"))) { why[0] = "ingenium".equals(b.get("app")) ? "This signature is for the computer apps. Bring in the file Save the signature made on your computer: it holds the one for phones and tablets too." : "This signature is for another copy of Ingenium."; return null; }
        if (!bodyOk(b)) { why[0] = "This signature does not hold the fields of a release of Ingenium."; return null; }
        Object kid = f.get("kid"), sig = f.get("sig");
        if (!(kid instanceof String) || !KID.matcher((String) kid).matches()) { why[0] = "It is not signed with one of the owner's keys this copy carries."; return null; }
        String[] key = k.find((String) kid);
        if (key == null) { why[0] = "It is not signed with one of the owner's keys this copy carries."; return null; }
        byte[] rs = sig instanceof String ? b64u((String) sig) : null, x = b64u(key[1]), y = b64u(key[2]);
        if (rs == null || rs.length != 64 || x == null || y == null || x.length != 32 || y.length != 32) { why[0] = "Its signature cannot be read."; return null; }
        StringBuilder c = new StringBuilder();
        canon(b, c);
        if (!verify(x, y, rs, c.toString().getBytes(UTF8))) { why[0] = "Its signature does not match: it was changed, or it is not the owner's."; return null; }
        StringBuilder t = new StringBuilder();
        canon(f, t);
        return new Sig(b, (String) kid, name, t.toString());
    }

    static boolean bodyOk(TreeMap<String, Object> b) {
        if (b.size() != 7) return false;
        for (String key : new String[]{"kind", "v", "app", "version", "edition", "files", "made"}) if (!b.containsKey(key)) return false;
        if (!BODY.equals(b.get("kind")) || !isOne(b.get("v"))) return false;
        if (!(b.get("version") instanceof String) || !V.matcher((String) b.get("version")).matches()) return false;
        if (!(b.get("edition") instanceof String) || !E.matcher((String) b.get("edition")).matches()) return false;
        if (!(b.get("made") instanceof String) || !T.matcher((String) b.get("made")).matches()) return false;
        if (!(b.get("files") instanceof TreeMap)) return false;
        TreeMap<?, ?> fs = (TreeMap<?, ?>) b.get("files");
        if (fs.size() < 1 || fs.size() > 32) return false;
        for (Map.Entry<?, ?> e : fs.entrySet()) {
            String n = (String) e.getKey();
            if (!NAME.matcher(n).matches() || n.contains("..") || n.contains("//")) return false;
            if (!(e.getValue() instanceof TreeMap)) return false;
            TreeMap<?, ?> x = (TreeMap<?, ?>) e.getValue();
            if (x.size() != 2 || !(x.get("sha256") instanceof String) || !HEX.matcher((String) x.get("sha256")).matches()) return false;
            if (!(x.get("size") instanceof Double)) return false;
            double s = (Double) x.get("size");
            if (s < 0 || s >= 9007199254740992.0 || s != Math.rint(s)) return false;
        }
        return true;
    }

    /* ------------------------------------------------ the check */

    /** the state the room shows, and the start acts on: {ok, state, mobile, platform, version, edition, build, release, files, keys, own,
        refused, can, signed?, changed?} */
    public static TreeMap<String, Object> state(Map<String, Read> now, Keys k, List<Sig> kept, String platform) {
        TreeMap<String, Object> st = new TreeMap<String, Object>();
        Read pg = now.get(PAGE);
        String ver = pg == null ? "" : pg.version, ed = pg == null ? "master" : pg.edition;
        st.put("ok", Boolean.TRUE); st.put("mobile", Boolean.TRUE); st.put("platform", platform);
        st.put("version", ver); st.put("edition", ed); st.put("build", pg == null ? "" : pg.build); st.put("release", k.release);
        TreeMap<String, Object> own = new TreeMap<String, Object>();
        if (pg != null) own.put(PAGE, fileOf(pg));
        st.put("files", own); st.put("keys", k.kids()); st.put("own", Boolean.FALSE); st.put("refused", new ArrayList<Object>()); st.put("can", Boolean.TRUE);
        Sig s = pick(kept, k.release);
        if (s == null) s = pick(kept, ver);
        if (s == null) { st.put("state", "unsigned"); return st; }
        TreeMap<String, Object> signed = new TreeMap<String, Object>();
        signed.put("made", s.made()); signed.put("kid", s.kid); signed.put("version", s.version()); signed.put("edition", s.edition());
        st.put("signed", signed);
        List<Object> changed = changes(s, now, ver, ed);
        if (changed.isEmpty()) { st.put("state", "signed"); return st; }
        st.put("state", "changed"); st.put("changed", changed);
        return st;
    }

    /** the newest kept signature of that version */
    static Sig pick(List<Sig> kept, String version) {
        if (kept == null || version == null || version.isEmpty()) return null;
        List<Sig> l = new ArrayList<Sig>();
        for (Sig s : kept) if (version.equals(s.version())) l.add(s);
        if (l.isEmpty()) return null;
        Collections.sort(l, new Comparator<Sig>() { public int compare(Sig a, Sig b) { return b.made().compareTo(a.made()); } });
        return l.get(0);
    }

    static List<Object> changes(Sig s, Map<String, Read> now, String ver, String ed) {
        List<Object> out = new ArrayList<Object>();
        if (!s.version().equals(ver) || !s.edition().equals(ed)) {
            boolean v = !s.version().equals(ver);
            TreeMap<String, Object> c = new TreeMap<String, Object>(), want = new TreeMap<String, Object>(), is = new TreeMap<String, Object>();
            want.put(v ? "version" : "edition", v ? s.version() : s.edition());
            is.put(v ? "version" : "edition", v ? ver : ed);
            c.put("name", PAGE); c.put("why", v ? "version" : "edition"); c.put("want", want); c.put("now", is);
            out.add(c);
            return out;
        }
        for (Map.Entry<String, Object> e : s.files().entrySet()) {
            Read r = now.get(e.getKey());
            TreeMap<?, ?> want = (TreeMap<?, ?>) e.getValue();
            TreeMap<String, Object> c = new TreeMap<String, Object>();
            c.put("name", e.getKey()); c.put("want", want);
            if (r == null) { c.put("why", "missing"); c.put("now", Json.NULL); out.add(c); }
            else if (!r.sha256.equals(want.get("sha256")) || (double) r.size != (Double) want.get("size")) { c.put("why", "content"); c.put("now", fileOf(r)); out.add(c); }
        }
        return out;
    }

    /** Bring a signature in: a signature of hers of the copy for phones and tablets, alone or in the file Save the signature makes, kept only
        when it names this very copy. {ok:true, keep, name, …the state with it} or {ok:false, error} */
    @SuppressWarnings("unchecked")
    public static TreeMap<String, Object> put(String text, Map<String, Read> now, Keys k, String platform) {
        TreeMap<String, Object> out = new TreeMap<String, Object>();
        Object o;
        try { o = new Json(text == null ? "" : text).whole(); } catch (Exception e) { return no(out, "This is not a signature of Ingenium."); }
        List<Object> cands = new ArrayList<Object>();
        if (o instanceof TreeMap && LIST.equals(((TreeMap<?, ?>) o).get("kind")) && isOne(((TreeMap<?, ?>) o).get("v")) && ((TreeMap<?, ?>) o).get("signatures") instanceof List) {
            for (Object x : (List<?>) ((TreeMap<?, ?>) o).get("signatures")) {
                if (x instanceof TreeMap && ((TreeMap<?, ?>) x).get("release") instanceof TreeMap && APP.equals(((TreeMap<?, ?>) ((TreeMap<?, ?>) x).get("release")).get("app"))) cands.add(x);
            }
            if (cands.isEmpty()) return no(out, "This file holds no signature for phones and tablets. Sign it for your phones and tablets on your computer, then save the signature again.");
        } else cands.add(o);
        String err = null;
        for (Object c : cands) {
            String[] why = new String[1];
            Sig s = verified(c, k, null, why);
            if (s == null) { err = why[0]; continue; }
            Read pg = now.get(PAGE);
            String ver = pg == null ? "" : pg.version, ed = pg == null ? "master" : pg.edition;
            if (!s.version().equals(ver)) { err = "This signature is for Ingenium " + s.version() + ", and this " + platform + " runs " + (ver.isEmpty() ? "another version" : ver) + "."; continue; }
            if (!s.edition().equals(ed)) { err = "This signature is for the " + s.edition() + " edition, and this " + platform + " runs the " + ed + " edition."; continue; }
            List<Object> ch = changes(s, now, ver, ed);
            if (!ch.isEmpty()) { err = "This signature is for another copy of Ingenium: " + ((TreeMap<?, ?>) ch.get(0)).get("name") + " here is not the one signed."; continue; }
            String sha = String.valueOf(((TreeMap<?, ?>) s.files().get(PAGE) == null ? new TreeMap<String, Object>() : (TreeMap<?, ?>) s.files().get(PAGE)).get("sha256"));
            String name = "ingenium-mobile-" + s.edition() + "-" + s.version() + "-" + (sha.length() >= 12 ? sha.substring(0, 12) : "000000000000") + ".ingsig";
            List<Sig> with = new ArrayList<Sig>();
            with.add(new Sig(s.body, s.kid, name, s.text));
            out.putAll(state(now, k, with, platform));
            out.put("ok", Boolean.TRUE); out.put("keep", s.text); out.put("name", name);
            return out;
        }
        return no(out, err == null ? "This is not a signature of Ingenium." : err);
    }

    private static TreeMap<String, Object> no(TreeMap<String, Object> out, String why) { out.put("ok", Boolean.FALSE); out.put("error", why); return out; }

    /* ------------------------------------------------ the page the app shows in Ingenium's place (assets/self_refused.html) */

    public static String refusal(String tpl, Map<String, Object> st, String platform) {
        Object sg = st.get("signed");
        String day = sg instanceof Map ? day(String.valueOf(((Map<?, ?>) sg).get("made"))) : "";
        StringBuilder rows = new StringBuilder();
        String reason = "a file in it changed since";
        Object ch = st.get("changed");
        if (ch instanceof List) for (Object o : (List<?>) ch) {
            Map<?, ?> c = (Map<?, ?>) o;
            String why = String.valueOf(c.get("why"));
            Map<?, ?> w = c.get("want") instanceof Map ? (Map<?, ?>) c.get("want") : null, n = c.get("now") instanceof Map ? (Map<?, ?>) c.get("now") : null;
            rows.append("<p class=\"nm\">").append(esc(String.valueOf(c.get("name")))).append("</p>");
            if (why.equals("version")) { reason = "it names another version of Ingenium"; rows.append("<p>It names Ingenium <b>").append(esc(String.valueOf(n.get("version")))).append("</b>, and you signed <b>").append(esc(String.valueOf(w.get("version")))).append("</b>: its page was put in from elsewhere.</p>"); }
            else if (why.equals("edition")) { reason = "it names another edition"; rows.append("<p>It names the <b>").append(esc(String.valueOf(n.get("edition")))).append("</b> edition, and you signed the <b>").append(esc(String.valueOf(w.get("edition")))).append("</b> edition: its page was put in from elsewhere.</p>"); }
            else if (why.equals("missing")) { reason = "a file of it is missing"; rows.append("<p>It is no longer there.</p>"); }
            else rows.append("<dl><dt>You signed</dt><dd><code>").append(esc(fp(w.get("sha256")))).append("</code> · ").append(bytes(w.get("size")))
                     .append(" bytes</dd><dt>It is now</dt><dd><code>").append(esc(fp(n.get("sha256")))).append("</code> · ").append(bytes(n.get("size"))).append(" bytes</dd></dl>");
        }
        String lead = "This copy of Ingenium is not the one you signed" + (day.isEmpty() ? "" : " on " + day) + ": " + reason + ". Nothing of it ran.";
        return tpl.replace("{{LEAD}}", esc(lead)).replace("{{ROWS}}", rows.toString()).replace("{{DEVICE}}", esc(platform));
    }

    public static String fp(Object h) {
        String s = String.valueOf(h == null ? "" : h);
        return s.length() == 64 ? s.substring(0, 8) + " " + s.substring(8, 16) + " … " + s.substring(56) : s;
    }

    static String bytes(Object n) {
        long v = n instanceof Number ? ((Number) n).longValue() : 0;
        return String.format(java.util.Locale.ROOT, "%,d", v);
    }

    static String day(String iso) {
        Matcher m = Pattern.compile("^(\\d{4})-(\\d\\d)-(\\d\\d)").matcher(iso == null ? "" : iso);
        if (!m.find()) return "";
        int mo = Integer.parseInt(m.group(2));
        return Integer.parseInt(m.group(3)) + " " + (mo >= 1 && mo <= 12 ? MONTHS[mo - 1] : "") + " " + m.group(1);
    }

    static String esc(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) { case '&': b.append("&amp;"); break; case '<': b.append("&lt;"); break; case '>': b.append("&gt;"); break; case '"': b.append("&quot;"); break; case '\'': b.append("&#39;"); break; default: b.append(c); }
        }
        return b.toString();
    }

    /* ------------------------------------------------ canon (PermitCore's fixed order) and JSON, the shells' own of 7.62 */

    public static String json(Object v) { StringBuilder b = new StringBuilder(); canon(v, b); return b.toString(); }

    static void canon(Object v, StringBuilder b) {
        if (v == Json.NULL || v == null) b.append("null");
        else if (v instanceof Boolean) b.append(((Boolean) v) ? "true" : "false");
        else if (v instanceof Number) b.append(number(((Number) v).doubleValue()));
        else if (v instanceof String) quote((String) v, b);
        else if (v instanceof List) {
            b.append('[');
            List<?> l = (List<?>) v;
            for (int i = 0; i < l.size(); i++) { if (i > 0) b.append(','); canon(l.get(i), b); }
            b.append(']');
        } else if (v instanceof Map) {
            TreeMap<String, Object> m = new TreeMap<String, Object>();
            for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) m.put((String) e.getKey(), e.getValue());
            b.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> e : m.entrySet()) {
                if (!first) b.append(',');
                first = false;
                quote(e.getKey(), b);
                b.append(':');
                canon(e.getValue(), b);
            }
            b.append('}');
        } else throw new IllegalArgumentException("a value canon does not write");
    }

    static String number(double d) {
        if (Double.isNaN(d) || Double.isInfinite(d) || d != Math.rint(d) || Math.abs(d) >= 1e21) throw new IllegalArgumentException("not a whole number");
        if (d == 0) return "0";
        return new BigDecimal(d).toBigInteger().toString();
    }

    static void quote(String s, StringBuilder b) {
        b.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\b': b.append("\\b"); break;
                case '\f': b.append("\\f"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) u4(c, b);
                    else if (Character.isHighSurrogate(c)) {
                        if (i + 1 < s.length() && Character.isLowSurrogate(s.charAt(i + 1))) { b.append(c).append(s.charAt(i + 1)); i++; }
                        else u4(c, b);
                    } else if (Character.isLowSurrogate(c)) u4(c, b);
                    else b.append(c);
            }
        }
        b.append('"');
    }

    private static void u4(char c, StringBuilder b) {
        String h = Integer.toHexString(c);
        b.append("\\u");
        for (int k = h.length(); k < 4; k++) b.append('0');
        b.append(h);
    }

    public static final class Json {
        public static final Object NULL = new Object();
        private final String s;
        private int i;

        public Json(String s) { this.s = s; }

        public Object whole() { Object v = value(); ws(); if (i != s.length()) throw bad(); return v; }

        private RuntimeException bad() { return new IllegalArgumentException("not JSON at " + i); }

        private void ws() { while (i < s.length()) { char c = s.charAt(i); if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++; else break; } }

        private Object value() {
            ws();
            if (i >= s.length()) throw bad();
            char c = s.charAt(i);
            if (c == '{') return object();
            if (c == '[') return array();
            if (c == '"') return string();
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            if (s.startsWith("null", i)) { i += 4; return NULL; }
            return number();
        }

        private Object object() {
            TreeMap<String, Object> m = new TreeMap<String, Object>();
            i++;
            ws();
            if (i < s.length() && s.charAt(i) == '}') { i++; return m; }
            while (true) {
                ws();
                if (i >= s.length() || s.charAt(i) != '"') throw bad();
                String k = string();
                ws();
                if (i >= s.length() || s.charAt(i) != ':') throw bad();
                i++;
                m.put(k, value());
                ws();
                if (i >= s.length()) throw bad();
                char c = s.charAt(i++);
                if (c == '}') return m;
                if (c != ',') throw bad();
            }
        }

        private Object array() {
            List<Object> l = new ArrayList<Object>();
            i++;
            ws();
            if (i < s.length() && s.charAt(i) == ']') { i++; return l; }
            while (true) {
                l.add(value());
                ws();
                if (i >= s.length()) throw bad();
                char c = s.charAt(i++);
                if (c == ']') return l;
                if (c != ',') throw bad();
            }
        }

        private String string() {
            StringBuilder b = new StringBuilder();
            i++;
            while (true) {
                if (i >= s.length()) throw bad();
                char c = s.charAt(i++);
                if (c == '"') return b.toString();
                if (c < 0x20) throw bad();
                if (c != '\\') { b.append(c); continue; }
                if (i >= s.length()) throw bad();
                char e = s.charAt(i++);
                switch (e) {
                    case '"': b.append('"'); break;
                    case '\\': b.append('\\'); break;
                    case '/': b.append('/'); break;
                    case 'b': b.append('\b'); break;
                    case 'f': b.append('\f'); break;
                    case 'n': b.append('\n'); break;
                    case 'r': b.append('\r'); break;
                    case 't': b.append('\t'); break;
                    case 'u':
                        if (i + 4 > s.length()) throw bad();
                        int v = 0;
                        for (int k = 0; k < 4; k++) {
                            int d = Character.digit(s.charAt(i + k), 16);
                            if (d < 0) throw bad();
                            v = v * 16 + d;
                        }
                        i += 4;
                        b.append((char) v);
                        break;
                    default: throw bad();
                }
            }
        }

        private Object number() {
            int st = i;
            if (i < s.length() && s.charAt(i) == '-') i++;
            if (i >= s.length()) throw bad();
            if (s.charAt(i) == '0') i++;
            else if (s.charAt(i) >= '1' && s.charAt(i) <= '9') { while (i < s.length() && s.charAt(i) >= '0' && s.charAt(i) <= '9') i++; }
            else throw bad();
            if (i < s.length() && s.charAt(i) == '.') {
                i++;
                int d = i;
                while (i < s.length() && s.charAt(i) >= '0' && s.charAt(i) <= '9') i++;
                if (i == d) throw bad();
            }
            if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
                i++;
                if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
                int d = i;
                while (i < s.length() && s.charAt(i) >= '0' && s.charAt(i) <= '9') i++;
                if (i == d) throw bad();
            }
            return Double.valueOf(s.substring(st, i));
        }
    }

    private static boolean isOne(Object v) { return v instanceof Double && (Double) v == 1.0; }

    static boolean verify(byte[] x, byte[] y, byte[] rs, byte[] message) {
        try {
            byte[] spki = new byte[SPKI_HEAD.length + 65];
            System.arraycopy(SPKI_HEAD, 0, spki, 0, SPKI_HEAD.length);
            spki[SPKI_HEAD.length] = 4;
            System.arraycopy(x, 0, spki, SPKI_HEAD.length + 1, 32);
            System.arraycopy(y, 0, spki, SPKI_HEAD.length + 33, 32);
            PublicKey pk = KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(spki));
            Signature v = Signature.getInstance("SHA256withECDSA");
            v.initVerify(pk);
            v.update(message);
            return v.verify(der(rs));
        } catch (Exception e) {
            return false;
        }
    }

    private static byte[] der(byte[] rs) {
        byte[] r = whole(rs, 0), s = whole(rs, 32);
        byte[] out = new byte[6 + r.length + s.length];
        out[0] = 0x30; out[1] = (byte) (4 + r.length + s.length); out[2] = 0x02; out[3] = (byte) r.length;
        System.arraycopy(r, 0, out, 4, r.length);
        out[4 + r.length] = 0x02; out[5 + r.length] = (byte) s.length;
        System.arraycopy(s, 0, out, 6 + r.length, s.length);
        return out;
    }

    private static byte[] whole(byte[] src, int off) {
        int k = off;
        while (k < off + 31 && src[k] == 0) k++;
        boolean pad = (src[k] & 0x80) != 0;
        byte[] out = new byte[off + 32 - k + (pad ? 1 : 0)];
        System.arraycopy(src, k, out, pad ? 1 : 0, off + 32 - k);
        return out;
    }

    static byte[] b64u(String s) {
        int n = s.length();
        if (n % 4 == 1) return null;
        byte[] out = new byte[n * 6 / 8];
        int o = 0, acc = 0, bits = 0;
        for (int k = 0; k < n; k++) {
            char c = s.charAt(k);
            int v = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26 : c >= '0' && c <= '9' ? c - '0' + 52 : c == '-' ? 62 : c == '_' ? 63 : -1;
            if (v < 0) return null;
            acc = (acc << 6) | v;
            bits += 6;
            if (bits >= 8) { bits -= 8; out[o++] = (byte) (acc >> bits); acc &= (1 << bits) - 1; }
        }
        return out;
    }

    static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(Character.forDigit((x >> 4) & 15, 16)).append(Character.forDigit(x & 15, 16));
        return s.toString();
    }

    private static byte[] ascii(String s) {
        byte[] b = new byte[s.length()];
        for (int k = 0; k < s.length(); k++) b[k] = (byte) s.charAt(k);
        return b;
    }
}
