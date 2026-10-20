/*
   INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
   NO LICENCE IS GRANTED. See LICENCE.txt.

   The window the app runs in on Android and Fire OS. The whole interface is
   the bundled ingenium.html; the engine and the model library are native (see
   Bridge, NativeEngine and ModelLibrary).

     - The page is served from https://appassets.androidplatform.net/ by a
       WebViewAssetLoader, a secure local address with no network involved.
     - window.IngeniumNative is the bridge to the engine and the models.
     - Picking files works (a plain WebView ignores <input type="file">), and
       Save opens the system's own save dialog.

   The app asks for no permissions at all. There is no INTERNET permission, so
   Android itself keeps the app off the network; links to web pages open in
   the device's browser instead.
*/
package com.yannieforest.ingenium;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.webkit.ConsoleMessage;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.webkit.WebViewAssetLoader;

import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {

    private static final String TAG = "Ingenium";
    private static final String HOST = "appassets.androidplatform.net";
    private static final String APP_URL = "https://" + HOST + "/assets/ingenium.html";
    private static final int FILE_CHOOSER_REQUEST = 51426;
    private static final int SAVE_FILE_REQUEST = 51427;
    private static final int IMPORT_MODELS_REQUEST = 51428;

    /* The cloud build starts the app on an emulator with this flag: once the
       page is up, it waits for the built-in model, asks one question and writes
       the answer to the system log, proving page, bridge and engine end to end. */
    // R70: the test itself lives in the page (ingSelfTest), shared with the
    // iPhone app: Velox must answer a question, Scriba must think, and the app
    // must reach the internet. It writes INGENIUM_SELFTEST lines, ending in DONE.
    private static final String SELF_TEST_JS =
            "(function(){var t0=Date.now();function go2(){"
            + "if(typeof ingSelfTest==='function'&&typeof Engine!=='undefined'){ingSelfTest();}"
            + "else if(Date.now()-t0>120000){console.log('INGENIUM_SELFTEST ERROR the page has no self-test');"
            + "console.log('INGENIUM_SELFTEST DONE');}else{setTimeout(go2,1000);}}go2();})();";

    // A new app made with Ingenium's builder is not Ingenium's chat, so its cloud
    // test is simpler: the page must load and report its title.
    private static final String PAGE_TEST_JS =
            "(function(){setTimeout(function(){console.log('INGENIUM_SELFTEST PAGE '+JSON.stringify({title:document.title,"
            + "text:((document.body&&document.body.innerText)||'').length}));},3000);})();";

    private WebView webView;
    private Bridge bridge;
    private boolean selfTest, pageTest, selfTestStarted;
    private ValueCallback<Uri[]> filePathCallback;
    /* 6.0: the saves waiting their turn ({name, mime, base64}); the first is the one whose dialog is open.
       A single pending file was overwritten when the page saved several at once, while Android stacked
       their Save dialogs, so names and contents crossed. */
    private final java.util.ArrayDeque<String[]> saves = new java.util.ArrayDeque<>();
    private boolean saveOpen;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Window w = getWindow();
        if (Build.VERSION.SDK_INT >= 21) w.setStatusBarColor(Color.parseColor("#4e2c8a"));

        webView = new WebView(this);
        webView.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        webView.setBackgroundColor(Color.parseColor("#f5f3f7"));
        setContentView(webView);

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);          // the page keeps your work in local storage
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(true);
        // R102: the tablet's own font size made the page's text larger inside panels of a fixed size, so the chat's
        // keys and the conversations' list ran out of place on a Fire tablet. The page keeps its own sizes (Display,
        // Text size, in Ingenium) and is shown at its own scale.
        s.setTextZoom(100);

        selfTest = getIntent() != null && getIntent().getBooleanExtra("ingenium_selftest", false);
        pageTest = getIntent() != null && getIntent().getBooleanExtra("ingenium_pagetest", false);
        bridge = new Bridge(this, webView);
        // Only the app's own page is ever loaded, so only Ingenium's code can reach this.
        webView.addJavascriptInterface(bridge, "IngeniumNative");

        final WebViewAssetLoader assets = new WebViewAssetLoader.Builder()
                .setDomain(HOST)
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return assets.shouldInterceptRequest(request.getUrl());
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                if ((selfTest || pageTest) && !selfTestStarted) {
                    selfTestStarted = true;
                    view.evaluateJavascript(selfTest ? SELF_TEST_JS : PAGE_TEST_JS, null);
                }
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri u = request.getUrl();
                if (HOST.equals(u.getHost())) return false;
                // a link out of the app: hand it to the browser
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, u));
                } catch (ActivityNotFoundException ignored) {
                }
                return true;
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.println(m.messageLevel() == ConsoleMessage.MessageLevel.ERROR ? Log.ERROR : Log.INFO,
                        "IngeniumPage", m.message() + " (" + m.sourceId() + ":" + m.lineNumber() + ")");
                return true;
            }

            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (filePathCallback != null) filePathCallback.onReceiveValue(null);
                filePathCallback = callback;
                // A plain "*/*" open: model files have no registered type on Android,
                // so a filtered chooser would hide them.
                Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                if (params != null && params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
                    intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                }
                try {
                    startActivityForResult(intent, FILE_CHOOSER_REQUEST);
                } catch (ActivityNotFoundException e) {
                    filePathCallback = null;
                    return false;
                }
                return true;
            }
        });

        // always a fresh page: the page keeps your work in its own storage
        webView.loadUrl(APP_URL);
    }

    /** The system chooser for adding models to the library. */
    /** The page's theme and colours (CSS rgb() strings): the status bar and the
     *  navigation bar take them, so the app shows no seam at its edges. */
    void setAppearance(boolean dark, String top, String back) {
        Window w = getWindow();
        Integer bar = cssColor(top), bg = cssColor(back);
        if (bar != null) w.setStatusBarColor(bar);
        if (bg != null) {
            webView.setBackgroundColor(bg);
            if (Build.VERSION.SDK_INT >= 26) w.setNavigationBarColor(bg);
        }
        View d = w.getDecorView();
        int f = d.getSystemUiVisibility();
        f = dark ? (f & ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR) : (f | View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        if (Build.VERSION.SDK_INT >= 26) {
            f = (dark || bg == null) ? (f & ~View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR) : (f | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        d.setSystemUiVisibility(f);
    }

    /** "rgb(21, 16, 29)" or "rgba(...)" to a colour; null for anything else or a see-through one. */
    static Integer cssColor(String css) {
        if (css == null || !css.startsWith("rgb")) return null;
        String[] p = css.replaceAll("[^0-9.,]", "").split(",");
        try {
            if (p.length < 3) return null;
            if (p.length >= 4 && Double.parseDouble(p[3]) <= 0.5) return null;
            return Color.rgb((int) Math.round(Double.parseDouble(p[0])), (int) Math.round(Double.parseDouble(p[1])),
                    (int) Math.round(Double.parseDouble(p[2])));
        } catch (NumberFormatException e) {
            return null;
        }
    }

    boolean openModelPicker() {
        Intent open = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        open.addCategory(Intent.CATEGORY_OPENABLE);
        open.setType("*/*");
        open.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try {
            startActivityForResult(open, IMPORT_MODELS_REQUEST);
            return true;
        } catch (ActivityNotFoundException e) {
            Intent get = new Intent(Intent.ACTION_GET_CONTENT);
            get.addCategory(Intent.CATEGORY_OPENABLE);
            get.setType("*/*");
            get.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            try {
                startActivityForResult(Intent.createChooser(get, "Choose a model file"), IMPORT_MODELS_REQUEST);
                return true;
            } catch (ActivityNotFoundException e2) {
                return false;
            }
        }
    }

    /** The page's Save buttons: open the system Save dialog, then write there; one dialog at a time. */
    boolean saveFile(final String name, final String mime, final String b64) {
        if (b64 == null) return false;
        synchronized (saves) {
            saves.add(new String[]{ name == null || name.isEmpty() ? "ingenium-export.bin" : name,
                    mime == null || mime.isEmpty() ? "application/octet-stream" : mime, b64 });
        }
        runOnUiThread(this::nextSave);
        return true;
    }

    /** On the UI thread: the Save dialog for the first file waiting, when none is open. */
    private void nextSave() {
        String[] s;
        synchronized (saves) {
            if (saveOpen || saves.isEmpty()) return;
            saveOpen = true;
            s = saves.peekFirst();
        }
        try {
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType(s[1]);
            intent.putExtra(Intent.EXTRA_TITLE, s[0]);
            startActivityForResult(intent, SAVE_FILE_REQUEST);
        } catch (Exception e) {
            synchronized (saves) { saves.pollFirst(); saveOpen = false; }
            nextSave();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == IMPORT_MODELS_REQUEST) {
            List<Uri> uris = new ArrayList<>();
            if (resultCode == RESULT_OK && data != null) {
                ClipData clip = data.getClipData();
                if (clip != null) {
                    for (int i = 0; i < clip.getItemCount(); i++) {
                        Uri u = clip.getItemAt(i).getUri();
                        if (u != null) uris.add(u);
                    }
                } else if (data.getData() != null) {
                    uris.add(data.getData());
                }
            }
            bridge.onModelsPicked(uris);
            return;
        }
        if (requestCode == FILE_CHOOSER_REQUEST) {
            if (filePathCallback != null) {
                Uri[] results = null;
                // R72: several files at once (a model's folder, for the converter)
                // come back as ClipData, which parseResult does not read
                if (resultCode == RESULT_OK && data != null && data.getClipData() != null) {
                    ClipData clip = data.getClipData();
                    List<Uri> uris = new ArrayList<>();
                    for (int i = 0; i < clip.getItemCount(); i++) {
                        Uri u = clip.getItemAt(i).getUri();
                        if (u != null) uris.add(u);
                    }
                    results = uris.toArray(new Uri[0]);
                } else if (resultCode == RESULT_OK && data != null) {
                    results = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
                }
                filePathCallback.onReceiveValue(results);
                filePathCallback = null;
            }
            return;
        }
        if (requestCode == SAVE_FILE_REQUEST) {
            String[] s;
            synchronized (saves) { s = saves.pollFirst(); saveOpen = false; }
            String b64 = s == null ? null : s[2];
            if (resultCode == RESULT_OK && data != null && data.getData() != null && b64 != null) {
                try (OutputStream os = getContentResolver().openOutputStream(data.getData())) {
                    if (os != null) {
                        os.write(Base64.decode(b64, Base64.DEFAULT));
                        os.flush();
                    }
                } catch (Exception e) {
                    Log.w(TAG, "save failed: " + e);
                }
            }
            nextSave();
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (bridge != null) bridge.shutdown();
        if (webView != null) {
            webView.removeJavascriptInterface("IngeniumNative");
            webView.destroy();
        }
        super.onDestroy();
    }
}
