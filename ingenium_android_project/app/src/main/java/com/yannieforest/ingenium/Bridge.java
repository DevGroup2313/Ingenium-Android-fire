/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   window.IngeniumNative: how the page speaks to the app. The page sends
   {method, args, callId} to call(); every answer comes back as an event,
   window.__ingNativeEvent({type:"reply", callId, ok, result|error}), and
   streaming work (load progress, reply text) arrives as events in between.
   All engine work runs on one thread; abort() may come from any thread.
*/
package com.yannieforest.ingenium;

import android.app.ActivityManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

final class Bridge {
    private static final String TAG = "Ingenium";

    private final MainActivity act;
    private final WebView web;
    private final ModelLibrary lib;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService engine = Executors.newSingleThreadExecutor(r -> new Thread(r, "ingenium-engine"));
    private final ExecutorService io = Executors.newSingleThreadExecutor(r -> new Thread(r, "ingenium-io"));
    // the internet, when the page asks: a connection (Claude, Ollama), web search, GitHub
    private final ExecutorService net = Executors.newCachedThreadPool(r -> new Thread(r, "ingenium-net"));
    private final ConcurrentHashMap<String, HttpURLConnection> netLive = new ConcurrentHashMap<>();
    // R70: downloads of Ingenium's lineup, one at a time, each with its stop switch
    private final ExecutorService downloads = Executors.newSingleThreadExecutor(r -> new Thread(r, "ingenium-download"));
    private final ConcurrentHashMap<String, AtomicBoolean> installStops = new ConcurrentHashMap<>();

    private volatile long handle;     // the loaded model, 0 when none
    private String loadedId;          // engine thread only
    private int loadedCtx;
    private JSONObject loadedInfo;
    private String importCallId;      // ui thread only

    Bridge(MainActivity act, WebView web) {
        this.act = act;
        this.web = web;
        this.lib = new ModelLibrary(act);
    }

    // ---------------------------------------------------------------- page side

    /** Kept from the earlier app: the page's Save buttons call this directly. */
    @JavascriptInterface
    public boolean saveFile(String name, String mime, String b64) {
        return act.saveFile(name, mime, b64);
    }

    @JavascriptInterface
    public void call(String json) {
        final String callId, method;
        final JSONObject args;
        try {
            JSONObject o = new JSONObject(json);
            callId = o.optString("callId");
            method = o.optString("method");
            JSONObject a = o.optJSONObject("args");
            args = a != null ? a : new JSONObject();
        } catch (JSONException e) {
            return;
        }
        switch (method) {
            case "saveFile": {
                // 6.7: saving comes through the same channel as every other call (the web message listener)
                boolean saved = act.saveFile(args.optString("name"), args.optString("mime"), args.optString("b64"));
                if (!callId.isEmpty()) { if (saved) replyOk(callId, ok()); else replyErr(callId, "the file was not saved"); }
                break;
            }
            case "info":
                io.execute(() -> replyOk(callId, info()));
                break;
            case "listModels":
                io.execute(() -> {
                    try {
                        replyOk(callId, lib.list());
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            case "load":
                engine.execute(() -> doLoad(callId, args));
                break;
            case "generate":
                engine.execute(() -> doGenerate(callId, args));
                break;
            case "abort": {
                long h = handle;
                if (h != 0) NativeEngine.abort(h);
                replyOk(callId, ok());
                break;
            }
            case "unload":
                engine.execute(() -> {
                    freeModel();
                    replyOk(callId, ok());
                });
                break;
            case "deleteModel":
                engine.execute(() -> {
                    String id = args.optString("id");
                    if (id.equals(loadedId)) freeModel();
                    try {
                        lib.delete(id);
                        replyOk(callId, ok());
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            case "restoreBuiltIn":
                io.execute(() -> {
                    try {
                        lib.restoreBuiltIn();
                        replyOk(callId, ok());
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            case "net":
                net.execute(() -> doNet(callId, args));
                break;
            // 6.9.1: an https address opened in the device's own browser (GitHub's own sign-in page, a build on GitHub)
            case "openUrl": {
                final String u = args.optString("url", "");
                if (!u.startsWith("https://") || u.indexOf(' ') >= 0 || u.indexOf('"') >= 0 || u.indexOf('\'') >= 0 || u.indexOf('<') >= 0) {
                    replyErr(callId, "only an https address can be opened");
                    break;
                }
                ui.post(() -> {
                    try {
                        act.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(u)));
                        replyOk(callId, ok());
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            }
            case "appearance": {
                final boolean dark = args.optBoolean("dark", false);
                final String top = args.optString("top", ""), back = args.optString("back", "");
                ui.post(() -> act.setAppearance(dark, top, back));
                replyOk(callId, new JSONObject());
                break;
            }
            // R78: the page's own edit panel reads and writes the clipboard
            // through the app; a web view refuses the page's own request
            case "clipboardRead":
                ui.post(() -> {
                    try {
                        ClipboardManager cm = (ClipboardManager) act.getSystemService(Context.CLIPBOARD_SERVICE);
                        String text = "";
                        if (cm != null && cm.hasPrimaryClip()) {
                            ClipData clip = cm.getPrimaryClip();
                            if (clip != null && clip.getItemCount() > 0) {
                                CharSequence t = clip.getItemAt(0).coerceToText(act);
                                if (t != null) text = t.toString();
                            }
                        }
                        JSONObject r = new JSONObject();
                        r.put("text", text);
                        replyOk(callId, r);
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            case "clipboardWrite": {
                final String text = args.optString("text", "");
                ui.post(() -> {
                    try {
                        ClipboardManager cm = (ClipboardManager) act.getSystemService(Context.CLIPBOARD_SERVICE);
                        if (cm == null) throw new IllegalStateException("no clipboard on this device");
                        cm.setPrimaryClip(ClipData.newPlainText("Ingenium", text));
                        replyOk(callId, ok());
                    } catch (Exception e) {
                        replyErr(callId, message(e));
                    }
                });
                break;
            }
            case "netAbort": {
                HttpURLConnection c = netLive.remove(args.optString("req"));
                if (c != null) net.execute(c::disconnect);
                replyOk(callId, ok());
                break;
            }
            case "installModel": {
                final String key = args.optString("key");
                final AtomicBoolean stop = new AtomicBoolean(false);
                if (installStops.putIfAbsent(key, stop) != null) {
                    replyErr(callId, "That model is already being installed.");
                    break;
                }
                downloads.execute(() -> {
                    final long[] last = {0};
                    try {
                        JSONObject m = lib.install(args, (got, total, phase) -> {
                            long now = SystemClock.uptimeMillis();
                            if (now - last[0] >= 250 || !"download".equals(phase)) {
                                last[0] = now;
                                emit(event("install-progress", "key", key, "received", got, "total", total, "phase", phase));
                            }
                        }, stop);
                        JSONObject r = new JSONObject();
                        r.put("model", m);
                        replyOk(callId, r);
                    } catch (ModelLibrary.Cancelled e) {
                        replyErr(callId, "Stopped.");
                    } catch (ModelLibrary.ImportException e) {
                        replyErr(callId, e.reason);
                    } catch (Throwable t) {
                        replyErr(callId, message(t));
                    } finally {
                        installStops.remove(key);
                    }
                });
                break;
            }
            // R72: a model the page converts arrives in pieces (base64), in order
            case "convertBegin":
                io.execute(() -> {
                    try {
                        JSONObject r = new JSONObject();
                        r.put("id", lib.writeBegin(args.optString("name"), args.optLong("size", 0)));
                        replyOk(callId, r);
                    } catch (Throwable t) {
                        replyErr(callId, message(t));
                    }
                });
                break;
            case "convertWrite":
                io.execute(() -> {
                    try {
                        byte[] data = android.util.Base64.decode(args.optString("data"), android.util.Base64.DEFAULT);
                        JSONObject r = new JSONObject();
                        r.put("written", lib.writeChunk(args.optString("id"), data));
                        replyOk(callId, r);
                    } catch (Throwable t) {
                        lib.writeAbort(args.optString("id"));
                        replyErr(callId, message(t));
                    }
                });
                break;
            case "convertEnd":
                io.execute(() -> {
                    try {
                        JSONObject r = new JSONObject();
                        r.put("model", lib.writeEnd(args.optString("id")));
                        replyOk(callId, r);
                    } catch (ModelLibrary.ImportException e) {
                        replyErr(callId, e.reason);
                    } catch (Throwable t) {
                        replyErr(callId, message(t));
                    }
                });
                break;
            case "convertAbort":
                io.execute(() -> {
                    lib.writeAbort(args.optString("id"));
                    replyOk(callId, ok());
                });
                break;
            case "cancelInstall": {
                AtomicBoolean stop = installStops.get(args.optString("key"));
                if (stop != null) stop.set(true);
                replyOk(callId, ok());
                break;
            }
            case "importModels":
                ui.post(() -> {
                    if (importCallId != null) {
                        replyErr(callId, "A file chooser is already open.");
                        return;
                    }
                    importCallId = callId;
                    if (!act.openModelPicker()) {
                        importCallId = null;
                        replyErr(callId, "This device has no file chooser that the app can open.");
                    }
                });
                break;
            default:
                replyErr(callId, "Unknown request: " + method);
        }
    }

    // ---------------------------------------------------------------- engine work

    private void doLoad(String callId, JSONObject args) {
        String id = args.optString("id");
        int nCtx = Math.max(512, Math.min(args.optInt("n_ctx", 4096), maxCtx()));
        if (handle != 0 && id.equals(loadedId) && loadedCtx == nCtx && loadedInfo != null) {
            replyOk(callId, loadedInfo);
            return;
        }
        freeModel();
        if (!NativeEngine.available) {
            replyErr(callId, "The engine could not start on this device (" + NativeEngine.loadError + ").");
            return;
        }
        final long[] last = {0};
        NativeEngine.Callback cb = new NativeEngine.Callback() {
            @Override public void onPiece(int kind, byte[] utf8) {}
            @Override public boolean onProgress(float p) {
                long now = SystemClock.uptimeMillis();
                if (now - last[0] > 150 || p >= 1f) {
                    last[0] = now;
                    emit(event("load-progress", "fraction", p));
                }
                return true;
            }
        };
        long h = 0;
        String err = null;
        try (ModelLibrary.Source src = lib.open(id)) {
            if (src.afd != null) {
                h = NativeEngine.loadFd(src.afd.getParcelFileDescriptor().getFd(), src.afd.getStartOffset(),
                        nCtx, threads(), true, cb);
            } else {
                h = NativeEngine.loadPath(src.path.getBytes(StandardCharsets.UTF_8), nCtx, threads(), true, cb);
            }
        } catch (Throwable t) {
            err = message(t);
        }
        if (h == 0) {
            replyErr(callId, err != null ? err : "The model could not be loaded.");
            return;
        }
        handle = h;
        loadedId = id;
        loadedCtx = nCtx;
        loadedInfo = parse(NativeEngine.modelInfo(h));
        Log.i(TAG, "loaded " + id + ": " + loadedInfo);
        replyOk(callId, loadedInfo);
    }

    private void doGenerate(String callId, JSONObject args) {
        long h = handle;
        if (h == 0) {
            replyErr(callId, "No model is loaded.");
            return;
        }
        final String req = args.optString("req");
        JSONArray msgs = args.optJSONArray("messages");
        JSONObject params = args.optJSONObject("params");
        final StringBuilder answer = new StringBuilder(), thinking = new StringBuilder();
        final long[] lastFlush = {SystemClock.uptimeMillis()};
        NativeEngine.Callback cb = new NativeEngine.Callback() {
            @Override public void onPiece(int kind, byte[] utf8) {
                (kind == 1 ? thinking : answer).append(new String(utf8, StandardCharsets.UTF_8));
                long now = SystemClock.uptimeMillis();
                if (now - lastFlush[0] >= 60) {
                    lastFlush[0] = now;
                    flush(req, answer, thinking);
                }
            }
            @Override public boolean onProgress(float p) { return true; }
        };
        try {
            byte[] stats = NativeEngine.generate(h,
                    (msgs != null ? msgs.toString() : "[]").getBytes(StandardCharsets.UTF_8),
                    (params != null ? params.toString() : "{}").getBytes(StandardCharsets.UTF_8), cb);
            flush(req, answer, thinking);
            replyOk(callId, parse(stats));
        } catch (Throwable t) {
            flush(req, answer, thinking);
            replyErr(callId, message(t));
        }
    }

    private void flush(String req, StringBuilder answer, StringBuilder thinking) {
        if (thinking.length() > 0) {
            emit(event("piece", "req", req, "kind", 1, "text", thinking.toString()));
            thinking.setLength(0);
        }
        if (answer.length() > 0) {
            emit(event("piece", "req", req, "kind", 0, "text", answer.toString()));
            answer.setLength(0);
        }
    }

    private void freeModel() {
        long h = handle;
        handle = 0;
        loadedId = null;
        loadedInfo = null;
        if (h != 0) NativeEngine.free(h);
    }

    // ---------------------------------------------------------------- the internet

    private static final String NET_UA =
            "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36";

    /** One request for the page, from the app itself: no website rule refuses it, and a
     *  streamed reply (Claude, Ollama) comes back to the page piece by piece. */
    private void doNet(String callId, JSONObject args) {
        final String req = args.optString("req", callId);
        final String url = args.optString("url");
        final String method = args.optString("method", "GET").toUpperCase(Locale.ROOT);
        final boolean stream = args.optBoolean("stream", false);
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            replyErr(callId, "Only web addresses (http and https) can be fetched.");
            return;
        }
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            netLive.put(req, c);
            c.setRequestMethod(method);
            c.setConnectTimeout(20000);
            c.setReadTimeout(Math.max(5, Math.min(args.optInt("timeout", 120), 900)) * 1000);
            c.setInstanceFollowRedirects(true);
            c.setRequestProperty("User-Agent", NET_UA);
            JSONObject h = args.optJSONObject("headers");
            if (h != null) {
                for (Iterator<String> it = h.keys(); it.hasNext(); ) {
                    String k = it.next();
                    String low = k.toLowerCase(Locale.ROOT);
                    if (low.equals("host") || low.equals("content-length") || low.equals("connection")) continue;
                    c.setRequestProperty(k, h.optString(k));
                }
            }
            String body = args.isNull("body") ? null : args.optString("body", null);
            if (body != null && !method.equals("GET") && !method.equals("HEAD")) {
                byte[] b = body.getBytes(StandardCharsets.UTF_8);
                c.setDoOutput(true);
                c.setFixedLengthStreamingMode(b.length);
                if (c.getRequestProperty("Content-Type") == null) c.setRequestProperty("Content-Type", "application/json");
                try (OutputStream os = c.getOutputStream()) {
                    os.write(b);
                }
            }
            int status = c.getResponseCode();
            InputStream in = status >= 400 ? c.getErrorStream() : c.getInputStream();
            StringBuilder all = new StringBuilder();
            if (in != null) {
                try (InputStreamReader rd = new InputStreamReader(in, StandardCharsets.UTF_8)) {
                    char[] buf = new char[8192];
                    int n;
                    while ((n = rd.read(buf)) > 0) {
                        if (stream && status < 400) {
                            emit(event("net-chunk", "req", req, "text", new String(buf, 0, n)));
                        } else {
                            all.append(buf, 0, n);
                            if (all.length() > 8_000_000) break;
                        }
                    }
                }
            }
            JSONObject r = new JSONObject();
            r.put("status", status);
            r.put("contentType", c.getContentType() == null ? "" : c.getContentType());
            r.put("body", all.toString());
            replyOk(callId, r);
        } catch (Exception e) {
            replyErr(callId, netLive.containsKey(req) ? netReason(e) : "Stopped.");
        } finally {
            netLive.remove(req);
            if (c != null) c.disconnect();
        }
    }

    private static String netReason(Exception e) {
        String m = message(e);
        String low = m.toLowerCase(Locale.ROOT);
        if (e instanceof java.net.UnknownHostException) return "That name could not be found. Is this device online?";
        if (e instanceof java.net.SocketTimeoutException) return "That address did not answer in time.";
        if (low.contains("refused")) return "Nothing answered at that address (is the program there running?).";
        if (e instanceof javax.net.ssl.SSLException) return "That site's security certificate could not be checked (" + m + ").";
        return m;
    }

    // ---------------------------------------------------------------- importing

    /** From MainActivity, on the ui thread, once the chooser closes. */
    void onModelsPicked(List<Uri> uris) {
        final String callId = importCallId;
        importCallId = null;
        if (callId == null) return;
        if (uris.isEmpty()) {
            JSONObject r = new JSONObject();
            try {
                r.put("added", new JSONArray());
                r.put("failed", new JSONArray());
                r.put("cancelled", true);
            } catch (JSONException ignored) {
            }
            replyOk(callId, r);
            return;
        }
        io.execute(() -> {
            JSONArray added = new JSONArray(), failed = new JSONArray();
            for (Uri u : uris) {
                try {
                    added.put(lib.importUri(u, (name, f) ->
                            emit(event("import-progress", "name", name, "fraction", f))));
                } catch (ModelLibrary.ImportException e) {
                    JSONObject f = new JSONObject();
                    try {
                        f.put("name", e.name);
                        f.put("reason", e.reason);
                    } catch (JSONException ignored) {
                    }
                    failed.put(f);
                }
            }
            JSONObject r = new JSONObject();
            try {
                r.put("added", added);
                r.put("failed", failed);
            } catch (JSONException ignored) {
            }
            replyOk(callId, r);
        });
    }

    // ---------------------------------------------------------------- device facts

    private JSONObject info() {
        JSONObject o = new JSONObject();
        try {
            String v = NativeEngine.available ? NativeEngine.version() : "unavailable: " + NativeEngine.loadError;
            o.put("engine", v);
            o.put("engineShort", v.contains(" | ") ? v.substring(0, v.indexOf(" | ")) : v);
            o.put("available", NativeEngine.available);
            o.put("platform", "android");
            o.put("threads", threads());
            o.put("gpu", false);
            o.put("maxCtx", maxCtx());
            o.put("net", true);
            JSONObject d = new JSONObject();
            d.put("ramGB", Math.round(totalRam() / (double) (1L << 30) * 10) / 10.0);
            d.put("cores", Runtime.getRuntime().availableProcessors());
            d.put("model", Build.MODEL);
            d.put("maker", Build.MANUFACTURER);
            d.put("abi", Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "");
            d.put("os", "Android " + Build.VERSION.RELEASE);
            o.put("device", d);
        } catch (JSONException ignored) {
        }
        return o;
    }

    private long totalRam() {
        try {
            ActivityManager am = (ActivityManager) act.getSystemService(Context.ACTIVITY_SERVICE);
            ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
            am.getMemoryInfo(mi);
            return mi.totalMem;
        } catch (Exception e) {
            return 0;
        }
    }

    /** Phones and tablets mix fast and slow cores; four threads is the usual sweet spot. */
    private int threads() {
        int n = Runtime.getRuntime().availableProcessors();
        return Math.max(1, Math.min(4, n));
    }

    /** How much conversation the model may hold, by the device's memory. */
    private int maxCtx() {
        long gb = totalRam() >> 30;
        if (gb >= 6) return 16384;
        if (gb >= 3) return 8192;
        return 4096;
    }

    // ---------------------------------------------------------------- plumbing

    private static JSONObject ok() {
        JSONObject o = new JSONObject();
        try {
            o.put("ok", true);
        } catch (JSONException ignored) {
        }
        return o;
    }

    /** An event for the page: a type, then name/value pairs. */
    private static JSONObject event(String type, Object... kv) {
        JSONObject o = new JSONObject();
        try {
            o.put("type", type);
            for (int i = 0; i + 1 < kv.length; i += 2) o.put((String) kv[i], kv[i + 1]);
        } catch (JSONException ignored) {
        }
        return o;
    }

    private static JSONObject parse(byte[] utf8) {
        try {
            return utf8 == null ? new JSONObject() : new JSONObject(new String(utf8, StandardCharsets.UTF_8));
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static String message(Throwable t) {
        String m = t.getMessage();
        return m != null && !m.isEmpty() ? m : t.getClass().getSimpleName();
    }

    private void replyOk(String callId, Object result) {
        JSONObject o = event("reply");
        try {
            o.put("callId", callId);
            o.put("ok", true);
            o.put("result", result == null ? JSONObject.NULL : result);
        } catch (JSONException ignored) {
        }
        emit(o);
    }

    private void replyErr(String callId, String error) {
        JSONObject o = event("reply");
        try {
            o.put("callId", callId);
            o.put("ok", false);
            o.put("error", error);
        } catch (JSONException ignored) {
        }
        emit(o);
    }

    private void emit(JSONObject ev) {
        // U+2028 and U+2029 are line breaks to older JavaScript engines
        final String js = "window.__ingNativeEvent&&window.__ingNativeEvent("
                + JSONObject.quote(ev.toString()).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029") + ")";
        ui.post(() -> {
            try {
                web.evaluateJavascript(js, null);
            } catch (Exception e) {
                Log.w(TAG, "event not delivered: " + e);
            }
        });
    }

    void shutdown() {
        long h = handle;
        if (h != 0) NativeEngine.abort(h);
        engine.execute(this::freeModel);
        engine.shutdown();
        io.shutdown();
        for (AtomicBoolean st : installStops.values()) st.set(true);
        downloads.shutdownNow();
        for (HttpURLConnection c : netLive.values()) {
            try {
                c.disconnect();
            } catch (Exception ignored) {
            }
        }
        net.shutdownNow();
        try {
            engine.awaitTermination(2, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
        }
    }
}
