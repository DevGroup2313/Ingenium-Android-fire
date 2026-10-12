/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   The app's own model library.
     - The built-in models ship inside the app package (assets/models/) and
       are read in place, so they never take space twice. "Removing" one hides
       it; it can be brought back at any time. R70: there may be several
       (builtin.json lists them); an app from before R70 had one.
     - Models the person adds are copied into the app's private storage, so
       they stay ready whatever happens to the original file.
     - R70: models from Ingenium's lineup are downloaded straight into that
       storage (resuming where a broken download stopped) and kept only when
       their SHA-256 fingerprint matches.
*/
package com.yannieforest.ingenium;

import android.content.ContentResolver;
import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.database.Cursor;
import android.net.Uri;
import android.os.SystemClock;
import android.provider.OpenableColumns;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.concurrent.atomic.AtomicBoolean;

final class ModelLibrary {

    static final String BUILTIN_ID = "builtin";          // the first built-in model (and the only one before R70)
    static final String BUILTIN_PREFIX = "builtin:";     // R70: "builtin:<file>" for each built-in model

    interface Progress {
        void onProgress(String name, float fraction);
    }

    /** R70: a lineup download's progress; phase is "download", "resume" or "verify". */
    interface InstallProgress {
        void onProgress(long received, long total, String phase);
    }

    static final class ImportException extends Exception {
        final String name;
        final String reason;

        ImportException(String name, String reason) {
            super(reason);
            this.name = name;
            this.reason = reason;
        }
    }

    /** Where a model's bytes are: a file path, or a range inside the app package. */
    static final class Source implements AutoCloseable {
        String path;
        AssetFileDescriptor afd;

        @Override
        public void close() {
            try {
                if (afd != null) afd.close();
            } catch (IOException ignored) {
            }
        }
    }

    private final Context ctx;
    private final File dir;
    private final File indexFile;
    private final List<JSONObject> builtins = new ArrayList<>();

    ModelLibrary(Context context) {
        ctx = context.getApplicationContext();
        dir = new File(ctx.getFilesDir(), "models");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        indexFile = new File(dir, "index.json");
        JSONObject bj = readAssetJson("models/builtin.json");
        if (bj != null) {
            JSONArray list = bj.optJSONArray("models");
            if (list != null) {
                for (int i = 0; i < list.length(); i++) {
                    JSONObject m = list.optJSONObject(i);
                    if (m != null && !m.optString("file", "").isEmpty()) builtins.add(m);
                }
            } else if (!bj.optString("file", "").isEmpty()) {
                builtins.add(bj);   // the one-model form of an app from before R70
            }
        }
        // a copy interrupted by the app closing leaves a .part file behind (a
        // lineup download's .dl.part stays, so the download can resume)
        File[] leftovers = dir.listFiles((d, n) -> n.endsWith(".part") && !n.endsWith(".dl.part"));
        if (leftovers != null) for (File f : leftovers) //noinspection ResultOfMethodCallIgnored
            f.delete();
    }

    // ------------------------------------------------------------------ index

    private JSONObject readIndex() {
        try {
            if (indexFile.exists()) {
                return new JSONObject(new String(readAll(new java.io.FileInputStream(indexFile)), StandardCharsets.UTF_8));
            }
        } catch (Exception ignored) {
        }
        JSONObject o = new JSONObject();
        try {
            o.put("models", new JSONArray());
            o.put("builtinHidden", false);
        } catch (JSONException ignored) {
        }
        return o;
    }

    private void writeIndex(JSONObject o) throws IOException {
        File tmp = new File(dir, "index.json.tmp");
        try (OutputStream out = new FileOutputStream(tmp)) {
            out.write(o.toString().getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
        if (!tmp.renameTo(indexFile)) throw new IOException("the model list could not be saved");
    }

    // ------------------------------------------------------------------ built-in

    private static String builtinId(int i, JSONObject cfg) {
        return BUILTIN_PREFIX + cfg.optString("file");
    }

    private boolean builtinPresent(JSONObject cfg) {
        try (AssetFileDescriptor afd = ctx.getAssets().openFd("models/" + cfg.optString("file"))) {
            return afd.getLength() > 0;
        } catch (IOException e) {
            return false;   // absent, or stored compressed (the build keeps it uncompressed)
        }
    }

    /** Files of the built-in models the person has hidden. */
    private static List<String> hiddenFiles(JSONObject idx, List<JSONObject> builtins) {
        List<String> out = new ArrayList<>();
        JSONArray h = idx.optJSONArray("hiddenBuiltins");
        if (h != null) for (int i = 0; i < h.length(); i++) out.add(h.optString(i));
        // before R70 there was one built-in model and one switch for it
        if (idx.optBoolean("builtinHidden", false) && !builtins.isEmpty()) {
            String f = builtins.get(0).optString("file");
            if (!out.contains(f)) out.add(f);
        }
        return out;
    }

    private JSONObject builtinEntry(JSONObject idx, int i, JSONObject cfg) throws JSONException {
        String f = cfg.optString("file");
        JSONObject e = new JSONObject();
        e.put("id", builtinId(i, cfg));
        e.put("builtIn", true);
        e.put("fileName", f);
        e.put("name", cfg.optString("name", "Built-in model"));
        if (!cfg.optString("lineup", "").isEmpty()) e.put("lineup", cfg.optString("lineup"));
        long len = 0;
        JSONObject metas = idx.optJSONObject("builtinMetas");
        if (metas == null) metas = new JSONObject();
        JSONObject meta = metas.optJSONObject(f);
        try (AssetFileDescriptor afd = ctx.getAssets().openFd("models/" + f)) {
            len = afd.getLength();
            if (meta == null || meta.optLong("length") != len) {
                meta = null;
                if (NativeEngine.available) {
                    byte[] js = NativeEngine.inspectFd(afd.getParcelFileDescriptor().getFd(), afd.getStartOffset());
                    if (js != null) {
                        meta = new JSONObject(new String(js, StandardCharsets.UTF_8));
                        meta.put("length", len);
                        metas.put(f, meta);
                        idx.put("builtinMetas", metas);
                        try {
                            writeIndex(idx);
                        } catch (IOException ignored) {
                        }
                    }
                }
            }
        } catch (IOException ignored) {
        }
        e.put("size", len);
        copyMeta(meta, e);
        return e;
    }

    /** The built-in model an id names: "builtin:<file>", or "builtin" for the first. */
    private JSONObject builtinFor(String id) {
        if (BUILTIN_ID.equals(id)) return builtins.isEmpty() ? null : builtins.get(0);
        if (id == null || !id.startsWith(BUILTIN_PREFIX)) return null;
        String f = id.substring(BUILTIN_PREFIX.length());
        for (JSONObject b : builtins) if (f.equals(b.optString("file"))) return b;
        return null;
    }

    // ------------------------------------------------------------------ queries

    synchronized JSONObject list() throws JSONException {
        JSONObject idx = readIndex();
        JSONArray out = new JSONArray();
        List<String> hidden = hiddenFiles(idx, builtins);
        boolean anyPresent = false, anyHidden = false;
        StringBuilder hiddenNames = new StringBuilder();
        for (int i = 0; i < builtins.size(); i++) {
            JSONObject cfg = builtins.get(i);
            if (!builtinPresent(cfg)) continue;
            anyPresent = true;
            if (hidden.contains(cfg.optString("file"))) {
                anyHidden = true;
                if (hiddenNames.length() > 0) hiddenNames.append(", ");
                hiddenNames.append(cfg.optString("name", cfg.optString("file")));
                continue;
            }
            out.put(builtinEntry(idx, i, cfg));
        }
        JSONArray ms = idx.optJSONArray("models");
        if (ms != null) {
            for (int i = 0; i < ms.length(); i++) {
                JSONObject m = ms.optJSONObject(i);
                if (m == null) continue;
                File f = new File(dir, m.optString("file"));
                if (!f.exists()) continue;
                JSONObject e = new JSONObject(m.toString());
                e.put("builtIn", false);
                e.put("size", f.length());
                out.put(e);
            }
        }
        JSONObject b = new JSONObject();
        b.put("available", anyPresent);
        b.put("hidden", anyHidden);
        b.put("id", builtins.isEmpty() ? BUILTIN_ID : builtinId(0, builtins.get(0)));
        b.put("name", anyHidden ? hiddenNames.toString() : (builtins.isEmpty() ? "" : builtins.get(0).optString("name", "")));
        JSONObject res = new JSONObject();
        res.put("models", out);
        res.put("builtin", b);
        return res;
    }

    synchronized Source open(String id) throws IOException {
        Source s = new Source();
        JSONObject cfg = builtinFor(id);
        if (cfg != null || BUILTIN_ID.equals(id) || (id != null && id.startsWith(BUILTIN_PREFIX))) {
            if (cfg == null) throw new IOException("this app has no such built-in model");
            s.afd = ctx.getAssets().openFd("models/" + cfg.optString("file"));
            return s;
        }
        JSONArray ms = readIndex().optJSONArray("models");
        if (ms != null) {
            for (int i = 0; i < ms.length(); i++) {
                JSONObject m = ms.optJSONObject(i);
                if (m != null && id.equals(m.optString("id"))) {
                    File f = new File(dir, m.optString("file"));
                    if (!f.exists()) throw new IOException("the model's file is missing");
                    s.path = f.getAbsolutePath();
                    return s;
                }
            }
        }
        throw new IOException("no such model");
    }

    // ------------------------------------------------------------------ changes

    synchronized void delete(String id) throws IOException, JSONException {
        JSONObject idx = readIndex();
        JSONObject cfg = builtinFor(id);
        if (cfg != null) {
            List<String> hidden = hiddenFiles(idx, builtins);
            if (!hidden.contains(cfg.optString("file"))) hidden.add(cfg.optString("file"));
            idx.put("hiddenBuiltins", new JSONArray(hidden));
            idx.remove("builtinHidden");
            writeIndex(idx);
            return;
        }
        JSONArray ms = idx.optJSONArray("models");
        JSONArray keep = new JSONArray();
        boolean found = false;
        if (ms != null) {
            for (int i = 0; i < ms.length(); i++) {
                JSONObject m = ms.optJSONObject(i);
                if (m == null) continue;
                if (id.equals(m.optString("id"))) {
                    found = true;
                    //noinspection ResultOfMethodCallIgnored
                    new File(dir, m.optString("file")).delete();
                } else {
                    keep.put(m);
                }
            }
        }
        if (!found) throw new IOException("no such model");
        idx.put("models", keep);
        writeIndex(idx);
    }

    synchronized void restoreBuiltIn() throws IOException, JSONException {
        JSONObject idx = readIndex();
        idx.put("builtinHidden", false);
        idx.put("hiddenBuiltins", new JSONArray());
        writeIndex(idx);
    }

    /** Copy a chosen file into the library. Runs on a background thread. */
    JSONObject importUri(Uri uri, Progress progress) throws ImportException {
        ContentResolver cr = ctx.getContentResolver();
        String name = "model.gguf";
        long size = -1;
        try (Cursor c = cr.query(uri, new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                if (!c.isNull(0)) name = c.getString(0);
                if (!c.isNull(1)) size = c.getLong(1);
            }
        } catch (Exception ignored) {
        }

        // the first four bytes of every GGUF file are the letters GGUF
        try (InputStream in = cr.openInputStream(uri)) {
            if (in == null) throw new ImportException(name, "the file could not be opened");
            byte[] magic = new byte[4];
            int got = 0;
            while (got < 4) {
                int r = in.read(magic, got, 4 - got);
                if (r < 0) break;
                got += r;
            }
            if (got < 4 || !"GGUF".equals(new String(magic, StandardCharsets.US_ASCII))) {
                throw new ImportException(name, "it is not a GGUF model file. Ingenium runs GGUF models; other formats (.safetensors, .bin, .pt) need converting to GGUF first");
            }
        } catch (IOException e) {
            throw new ImportException(name, "the file could not be read (" + e.getMessage() + ")");
        }

        long free = dir.getUsableSpace();
        if (size > 0 && free < size + 64L * 1024 * 1024) {
            throw new ImportException(name, String.format(Locale.US,
                    "there is not enough free space on this device (%s needed, %s free)", human(size), human(free)));
        }

        String id = "m" + Long.toString(System.currentTimeMillis(), 36) + Integer.toString(new Random().nextInt(1 << 20), 36);
        File part = new File(dir, id + ".gguf.part");
        File dest = new File(dir, id + ".gguf");
        long copied = 0, lastTick = 0;
        try (InputStream in = cr.openInputStream(uri); OutputStream out = new FileOutputStream(part)) {
            if (in == null) throw new IOException("the file could not be opened");
            byte[] buf = new byte[1 << 20];
            int r;
            while ((r = in.read(buf)) > 0) {
                out.write(buf, 0, r);
                copied += r;
                long now = SystemClock.uptimeMillis();
                if (progress != null && size > 0 && now - lastTick > 250) {
                    lastTick = now;
                    progress.onProgress(name, Math.min(1f, copied / (float) size));
                }
            }
            out.flush();
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "copying stopped part way (" + e.getMessage() + ")");
        }
        if (size > 0 && copied != size) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the copy came out the wrong size; please try again");
        }
        if (!part.renameTo(dest)) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the copy could not be finished");
        }
        if (progress != null) progress.onProgress(name, 1f);

        JSONObject meta = null;
        if (NativeEngine.available) {
            byte[] js = NativeEngine.inspectPath(dest.getAbsolutePath().getBytes(StandardCharsets.UTF_8));
            if (js != null) {
                try {
                    meta = new JSONObject(new String(js, StandardCharsets.UTF_8));
                } catch (JSONException ignored) {
                }
            }
        }
        if (NativeEngine.available && meta == null) {
            //noinspection ResultOfMethodCallIgnored
            dest.delete();
            throw new ImportException(name, "it starts like a GGUF file but could not be read; it may be damaged or incomplete");
        }
        if (meta != null && meta.optBoolean("is_projector")) {
            //noinspection ResultOfMethodCallIgnored
            dest.delete();
            throw new ImportException(name, "it is a vision projector (mmproj), which helps a model see pictures; it is not a chat model on its own");
        }

        try {
            JSONObject e = new JSONObject();
            e.put("id", id);
            e.put("file", dest.getName());
            e.put("fileName", name);
            e.put("name", niceName(name, meta));
            e.put("size", dest.length());
            copyMeta(meta, e);
            synchronized (this) {
                JSONObject idx = readIndex();
                JSONArray ms = idx.optJSONArray("models");
                if (ms == null) ms = new JSONArray();
                ms.put(e);
                idx.put("models", ms);
                writeIndex(idx);
            }
            return e;
        } catch (JSONException | IOException ex) {
            //noinspection ResultOfMethodCallIgnored
            dest.delete();
            throw new ImportException(name, "the model list could not be updated (" + ex.getMessage() + ")");
        }
    }

    // ------------------------------------------------------------------ R70: lineup downloads

    static final class Cancelled extends Exception {
        Cancelled() {
            super("Stopped.");
        }
    }

    /** Downloads a model of Ingenium's lineup into the library. spec: key, url,
     *  sha256, size, file, name, tiers. Only Hugging Face addresses are taken; a
     *  broken download resumes from where it stopped, and the file is kept only
     *  when its SHA-256 matches. Runs on a background thread; stop cancels it
     *  (the part already fetched stays, for the next try). */
    JSONObject install(JSONObject spec, InstallProgress progress, AtomicBoolean stop) throws ImportException, Cancelled {
        final String key = spec.optString("key"), url = spec.optString("url");
        final String sha = spec.optString("sha256").toLowerCase(Locale.ROOT), file = spec.optString("file");
        final String name = spec.optString("name", file);
        final long size = spec.optLong("size", -1);
        if (!url.startsWith("https://huggingface.co/") || !sha.matches("[0-9a-f]{64}") || !file.matches("[A-Za-z0-9._-]{1,200}\\.gguf") || size <= 0) {
            throw new ImportException(name, "the request did not name a model of Ingenium's lineup properly");
        }
        // already here: the same fingerprint
        synchronized (this) {
            JSONArray ms = readIndex().optJSONArray("models");
            if (ms != null) for (int i = 0; i < ms.length(); i++) {
                JSONObject m = ms.optJSONObject(i);
                if (m != null && sha.equals(m.optString("sha256")) && new File(dir, m.optString("file")).length() == size) return m;
            }
        }
        File part = new File(dir, sha.substring(0, 16) + ".dl.part");
        long have = part.exists() ? part.length() : 0;
        if (have > size) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            have = 0;
        }
        long free = dir.getUsableSpace();
        if (free < size - have + 64L * 1024 * 1024) {
            throw new ImportException(name, String.format(Locale.US,
                    "there is not enough free space on this device (%s needed, %s free)", human(size - have), human(free)));
        }
        MessageDigest md;
        try {
            md = MessageDigest.getInstance("SHA-256");
        } catch (Exception e) {
            throw new ImportException(name, "this device cannot check a file's fingerprint");
        }
        byte[] buf = new byte[1 << 20];
        if (have > 0) {   // the part fetched before counts towards the fingerprint
            progress.onProgress(have, size, "resume");
            try (InputStream in = new FileInputStream(part)) {
                int r;
                long done = 0;
                while (done < have && (r = in.read(buf, 0, (int) Math.min(buf.length, have - done))) > 0) {
                    md.update(buf, 0, r);
                    done += r;
                    if (stop.get()) throw new Cancelled();
                }
            } catch (IOException e) {
                //noinspection ResultOfMethodCallIgnored
                part.delete();
                have = 0;
                md.reset();
            }
        }
        String lastErr = "";
        for (int attempt = 1; attempt <= 6 && have < size; attempt++) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(url).openConnection();
                c.setConnectTimeout(20000);
                c.setReadTimeout(60000);
                c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", "Ingenium");
                if (have > 0) c.setRequestProperty("Range", "bytes=" + have + "-");
                int code = c.getResponseCode();
                if (code == 200 && have > 0) {   // the server sent the whole file again
                    md.reset();
                    have = 0;
                } else if (code != 200 && code != 206) {
                    lastErr = "the server answered " + code;
                    if (code == 404 || code == 403 || code == 401) break;
                    continue;
                }
                try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(part, have > 0)) {
                    long lastTick = 0;
                    int r;
                    while ((r = in.read(buf)) > 0) {
                        if (have + r > size) throw new IOException("the file is larger than expected");
                        out.write(buf, 0, r);
                        md.update(buf, 0, r);
                        have += r;
                        if (stop.get()) throw new Cancelled();
                        long now = SystemClock.uptimeMillis();
                        if (now - lastTick > 300) {
                            lastTick = now;
                            progress.onProgress(have, size, "download");
                        }
                    }
                }
            } catch (Cancelled x) {
                throw x;
            } catch (java.net.UnknownHostException e) {
                lastErr = "Hugging Face could not be reached (is this device online?)";
            } catch (IOException e) {
                lastErr = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
            } finally {
                if (c != null) c.disconnect();
            }
            if (have < size) {
                if (stop.get()) throw new Cancelled();
                SystemClock.sleep(Math.min(16000, 1000L << attempt));
            }
        }
        if (have != size) {
            throw new ImportException(name, "the download stopped part way (" + (lastErr.isEmpty() ? "no reason given" : lastErr)
                    + "). Install again to carry on from where it stopped.");
        }
        progress.onProgress(have, size, "verify");
        StringBuilder got = new StringBuilder();
        for (byte x : md.digest()) got.append(String.format(Locale.ROOT, "%02x", x));
        if (!sha.contentEquals(got)) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the downloaded file does not match its SHA-256 fingerprint, so it was deleted");
        }
        String id = "l" + sha.substring(0, 12);
        File dest = new File(dir, id + ".gguf");
        if (!part.renameTo(dest)) {
            throw new ImportException(name, "the download could not be finished");
        }
        JSONObject meta = null;
        if (NativeEngine.available) {
            byte[] js = NativeEngine.inspectPath(dest.getAbsolutePath().getBytes(StandardCharsets.UTF_8));
            if (js != null) {
                try {
                    meta = new JSONObject(new String(js, StandardCharsets.UTF_8));
                } catch (JSONException ignored) {
                }
            }
        }
        try {
            JSONObject e = new JSONObject();
            e.put("id", id);
            e.put("file", dest.getName());
            e.put("fileName", file);
            e.put("name", name);
            e.put("size", size);
            e.put("sha256", sha);
            e.put("lineup", key);
            JSONArray tiers = spec.optJSONArray("tiers");
            if (tiers != null) e.put("tiers", tiers);
            copyMeta(meta, e);
            synchronized (this) {
                JSONObject idx = readIndex();
                JSONArray ms = idx.optJSONArray("models");
                if (ms == null) ms = new JSONArray();
                ms.put(e);
                idx.put("models", ms);
                writeIndex(idx);
            }
            return e;
        } catch (JSONException | IOException ex) {
            //noinspection ResultOfMethodCallIgnored
            dest.delete();
            throw new ImportException(name, "the model list could not be updated (" + ex.getMessage() + ")");
        }
    }

    // ------------------------------------------------------------------ R72: converted models

    /* A model the page converted (from safetensors, PyTorch or MLX files) comes
     * in pieces: begin, write... end. The pieces go into a .part file, so an app
     * closed part way leaves nothing behind; at the end the file must be the
     * size announced and start like a GGUF, and it joins the library like an
     * imported model. */
    private final java.util.HashMap<String, OutputStream> writers = new java.util.HashMap<>();
    private final java.util.HashMap<String, File> writerFiles = new java.util.HashMap<>();
    private final java.util.HashMap<String, String> writerNames = new java.util.HashMap<>();
    private final java.util.HashMap<String, Long> writerSizes = new java.util.HashMap<>();

    synchronized String writeBegin(String name, long size) throws IOException {
        if (size > 0 && dir.getUsableSpace() < size + 64L * 1024 * 1024)
            throw new IOException("there is not enough free space: the converted model needs about " + human(size));
        String id = "c" + Long.toHexString(System.currentTimeMillis()) + Integer.toHexString((int) (Math.random() * 0xfff));
        File part = new File(dir, id + ".gguf.part");
        writers.put(id, new java.io.BufferedOutputStream(new FileOutputStream(part), 1 << 20));
        writerFiles.put(id, part);
        writerNames.put(id, name == null || name.trim().isEmpty() ? "Converted model" : name.trim());
        writerSizes.put(id, size);
        return id;
    }

    synchronized long writeChunk(String id, byte[] data) throws IOException {
        OutputStream o = writers.get(id);
        if (o == null) throw new IOException("that conversion is no longer open");
        o.write(data);
        return writerFiles.get(id).length();
    }

    synchronized void writeAbort(String id) {
        OutputStream o = writers.remove(id);
        File f = writerFiles.remove(id);
        writerNames.remove(id);
        writerSizes.remove(id);
        try {
            if (o != null) o.close();
        } catch (IOException ignored) {
        }
        //noinspection ResultOfMethodCallIgnored
        if (f != null) f.delete();
    }

    JSONObject writeEnd(String id) throws ImportException {
        File part;
        String name;
        long size;
        synchronized (this) {
            OutputStream o = writers.remove(id);
            part = writerFiles.remove(id);
            name = writerNames.remove(id);
            Long sz = writerSizes.remove(id);
            size = sz == null ? 0 : sz;
            if (o == null || part == null) throw new ImportException("The model", "the conversion was not open");
            try {
                o.close();
            } catch (IOException e) {
                //noinspection ResultOfMethodCallIgnored
                part.delete();
                throw new ImportException(name, "the file could not be finished (" + e.getMessage() + ")");
            }
        }
        if (size > 0 && part.length() != size) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the converted file came out the wrong size");
        }
        byte[] magic = new byte[4];
        try (java.io.FileInputStream in = new java.io.FileInputStream(part)) {
            if (in.read(magic) != 4 || magic[0] != 'G' || magic[1] != 'G' || magic[2] != 'U' || magic[3] != 'F')
                throw new IOException("not a GGUF file");
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the converted file is not a GGUF file");
        }
        File dest = new File(dir, id + ".gguf");
        if (!part.renameTo(dest)) {
            //noinspection ResultOfMethodCallIgnored
            part.delete();
            throw new ImportException(name, "the converted file could not be put in place");
        }
        JSONObject meta = null;
        if (NativeEngine.available) {
            byte[] js = NativeEngine.inspectPath(dest.getAbsolutePath().getBytes(StandardCharsets.UTF_8));
            if (js != null) {
                try {
                    meta = new JSONObject(new String(js, StandardCharsets.UTF_8));
                } catch (JSONException ignored) {
                }
            }
            if (meta == null) {
                //noinspection ResultOfMethodCallIgnored
                dest.delete();
                throw new ImportException(name, "the engine could not read the converted file");
            }
        }
        try {
            JSONObject e = new JSONObject();
            e.put("id", id);
            e.put("file", dest.getName());
            e.put("fileName", name + ".gguf");
            e.put("name", name);
            e.put("size", dest.length());
            e.put("converted", true);
            copyMeta(meta, e);
            synchronized (this) {
                JSONObject idx = readIndex();
                JSONArray ms = idx.optJSONArray("models");
                if (ms == null) ms = new JSONArray();
                ms.put(e);
                idx.put("models", ms);
                writeIndex(idx);
            }
            return e;
        } catch (JSONException | IOException ex) {
            //noinspection ResultOfMethodCallIgnored
            dest.delete();
            throw new ImportException(name, "the model list could not be updated (" + ex.getMessage() + ")");
        }
    }

    // ------------------------------------------------------------------ helpers

    private static void copyMeta(JSONObject meta, JSONObject e) {
        if (meta == null) return;
        try {
            e.put("arch", meta.optString("arch", ""));
            e.put("ctxTrain", meta.optLong("ctx_train", 0));
            e.put("layers", meta.optLong("layers", 0));
            e.put("sizeLabel", meta.optString("size_label", ""));
        } catch (JSONException ignored) {
        }
    }

    static String niceName(String fileName, JSONObject meta) {
        if (meta != null) {
            String base = meta.optString("basename", "").trim();
            String size = meta.optString("size_label", "").trim();
            if (!base.isEmpty()) {
                boolean has = size.isEmpty() || base.toLowerCase(Locale.US).contains(size.toLowerCase(Locale.US));
                return (has ? base : base + " " + size).replace('-', ' ').replace('_', ' ');
            }
            String nm = meta.optString("name", "").trim();
            if (!nm.isEmpty() && !nm.matches("[0-9a-fA-F]{24,}")) return nm;
        }
        String n = fileName.replaceAll("(?i)\\.gguf$", "");
        n = n.replaceAll("(?i)[-_.](i?q\\d[a-z0-9_]*|f16|f32|bf16|fp16)$", "");
        n = n.replace('-', ' ').replace('_', ' ').trim();
        return n.isEmpty() ? "New model" : n;
    }

    static String human(long b) {
        if (b >= 1L << 30) return String.format(Locale.US, "%.1f GB", b / (double) (1L << 30));
        return String.format(Locale.US, "%.0f MB", b / (double) (1L << 20));
    }

    private JSONObject readAssetJson(String path) {
        try (InputStream in = ctx.getAssets().open(path)) {
            return new JSONObject(new String(readAll(in), StandardCharsets.UTF_8));
        } catch (Exception e) {
            return null;
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        try (InputStream i = in; ByteArrayOutputStream bo = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int r;
            while ((r = i.read(buf)) > 0) bo.write(buf, 0, r);
            return bo.toByteArray();
        }
    }
}
