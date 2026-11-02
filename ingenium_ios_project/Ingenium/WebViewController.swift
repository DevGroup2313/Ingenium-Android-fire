// INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
// NO LICENCE IS GRANTED. See LICENCE.txt.
//
// The window the app runs in on iPhone and iPad. The whole interface is the
// bundled ingenium.html, served from ingenium://app/ (a private address of
// the app's own, so the page's storage behaves as it does on a web origin).
// The engine and the model library are native: see EngineBridge.

import UIKit
import UniformTypeIdentifiers
import WebKit

/// Serves the app's bundled files at ingenium://app/<name>.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ingenium"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/ingenium.html" }
        let file = Bundle.main.bundleURL.appendingPathComponent(String(path.dropFirst()))
        // stay inside the app bundle, and never hand out the models this way
        guard file.standardizedFileURL.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path),
              !path.hasPrefix("/Models/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let bridge = EngineBridge()
    private var selfTestStarted = false
    private let paper = UIColor(red: 0xf5 / 255.0, green: 0xf3 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    private let nightPaper = UIColor(red: 0x15 / 255.0, green: 0x10 / 255.0, blue: 0x1d / 255.0, alpha: 1)
    /// The page's theme, as it last said: dark text in the status bar by day, light at night.
    private var darkPage = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        config.userContentController.add(bridge, name: "ingenium")
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = paper
        webView.scrollView.backgroundColor = paper
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        bridge.webView = webView
        bridge.host = self

        // The page fills the whole screen, under the status bar and the home
        // indicator, and keeps its own bar and keys clear of them with the
        // safe-area insets WebKit hands it (CSS env(safe-area-inset-*)). Its
        // top bar then runs under the status bar, as a native app's does.
        // With the scroll view's automatic insets, WebKit would report those
        // insets as zero, so they are turned off.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.underPageBackgroundColor = paper

        let root = UIView()
        root.backgroundColor = paper
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: URL(string: "\(AppSchemeHandler.scheme)://app/ingenium.html")!))
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { darkPage ? .lightContent : .darkContent }

    /// The page says its theme and its colours (CSS rgb() strings); the status bar's
    /// text and the colour behind the page follow, so nothing shows a seam.
    func setAppearance(dark: Bool, top: String, back: String) {
        darkPage = dark
        let bg = WebViewController.color(back) ?? WebViewController.color(top) ?? (dark ? nightPaper : paper)
        view.backgroundColor = bg
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        webView.underPageBackgroundColor = bg
        setNeedsStatusBarAppearanceUpdate()
    }

    /// "rgb(21, 16, 29)" or "rgba(21, 16, 29, 0.9)" to a colour; nil for anything else
    /// (a transparent colour included).
    static func color(_ css: String) -> UIColor? {
        let nums = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard css.hasPrefix("rgb"), nums.count >= 3 else { return nil }
        let a = nums.count >= 4 ? nums[3] : 1
        guard a > 0.5 else { return nil }
        return UIColor(red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: 1)
    }

    // MARK: navigation: the page stays in the app; web links go to Safari

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == AppSchemeHandler.scheme || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    // 6.9.1: a link the page opens in a new window (target=_blank, window.open) goes to Safari; the page stays
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startPulse()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ingenium_selftest"), !selfTestStarted {
            selfTestStarted = true
            webView.evaluateJavaScript(WebViewController.selfTestJS, completionHandler: nil)
        } else if args.contains("-ingenium_pagetest"), !selfTestStarted {
            selfTestStarted = true
            webView.evaluateJavaScript(WebViewController.pageTestJS, completionHandler: nil)
        } else if args.contains("-ingenium_shots"), !selfTestStarted {
            selfTestStarted = true
            webView.evaluateJavaScript(WebViewController.shotsJS, completionHandler: nil)
        }
    }

    /// If the page's process is ever ended by the system (memory), bring it back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: R151: a page that stops answering

    /// The owner's words (20 October 2026): "I want a refresh button added to Ingenium and the Forge, that refreshed
    /// the app if it glitches or freezes." The page's own Refresh key cannot be pressed while the page is frozen, so
    /// once the page has loaded the app asks it a trivial question every ten seconds. When no answer has come for
    /// twenty-five seconds, it asks the owner: wait, or start the page again. A pause while the app was in the
    /// background is never counted.
    private var pulse: Timer?
    private var lastAnswer = Date()
    private var lastBeat = Date()
    private var askingStuck = false

    private func startPulse() {
        pulse?.invalidate()
        lastAnswer = Date()
        lastBeat = Date()
        pulse = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.beat() }
    }

    private func beat() {
        let now = Date()
        // a long gap between beats means the app was asleep, not that the page was stuck
        if now.timeIntervalSince(lastBeat) > 20 || UIApplication.shared.applicationState != .active { lastAnswer = now }
        lastBeat = now
        webView.evaluateJavaScript("1") { [weak self] _, _ in self?.lastAnswer = Date() }
        if !askingStuck, now.timeIntervalSince(lastAnswer) > 25 { askStuck() }
    }

    private func askStuck() {
        guard presentedViewController == nil else { return }
        askingStuck = true
        let ask = UIAlertController(
            title: "Ingenium is not answering",
            message: "The page has stopped answering for a while. It may still be painting something large. You can wait, or start Ingenium again; your saved work stays where it is.",
            preferredStyle: .alert)
        ask.addAction(UIAlertAction(title: "Wait", style: .cancel) { [weak self] _ in
            self?.askingStuck = false
            self?.lastAnswer = Date()
        })
        ask.addAction(UIAlertAction(title: "Start again", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.askingStuck = false
            self.lastAnswer = Date()
            self.webView.load(URLRequest(url: URL(string: "\(AppSchemeHandler.scheme)://app/ingenium.html")!))
        })
        present(ask, animated: true)
    }

    // MARK: alert, confirm and prompt from the page

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // The cloud build starts the app in the simulator with -ingenium_selftest:
    // the page waits for the built-in model, asks one question and reports the
    // answer through the bridge, which prints it for the build to read.
    // A new app made with Ingenium's builder is not Ingenium's chat, so its cloud
    // test is simpler: the page must load and report its title.
    static let pageTestJS = """
    (function(){setTimeout(function(){try{webkit.messageHandlers.ingenium.postMessage(JSON.stringify({method:'log',
    args:{msg:'INGENIUM_SELFTEST PAGE '+JSON.stringify({title:document.title,text:((document.body&&document.body.innerText)||'').length})},
    callId:''}));}catch(e){}},3000);})();
    """

    // The cloud build's screenshots (simulator_shots.sh): the page shows one view
    // after another and says which; the script photographs the simulator's screen.
    static let shotsJS = """
    (function(){
    function say(m){try{webkit.messageHandlers.ingenium.postMessage(JSON.stringify({method:'log',args:{msg:'INGENIUM_SHOT '+m},callId:''}));}catch(e){}}
    var steps=[
    ['welcome',function(){}],
    ['home',function(){var e=document.getElementById('introEnter');if(e)e.click();go('home');}],
    ['chat',function(){go('chat');var ms=curMsgs();ms.push({role:'me',text:'What is the tallest mountain on Earth?'});
     var b={role:'bot',think:'The person asks for the tallest mountain.\\nMeasured from sea level, that is Mount Everest.\\nI will give its height too.',thinkMs:4200,
     text:'Mount Everest, at about 8,849 metres above sea level.'};ms.push(b);renderChat();if(typeof thinkOpen!=='undefined'&&thinkOpen)thinkOpen.set(b,true);renderChat();}],
    ['tabula',function(){go('tabula');}],['abacus',function(){go('abacus');}],['guide',function(){go('guide');}],
    ['settings',function(){go('settings');}],
    ['about',function(){window.scrollTo(0,0);document.getElementById('aboutBtn').click();}],
    ['night',function(){closeModal();state.theme='night';applyTheme();go('home');}],
    ['night_chat',function(){go('chat');}]];
    var i=0;function next(){if(i>=steps.length){say('done');return;}var s=steps[i++];try{s[1]();window.scrollTo(0,0);}catch(e){say('error_'+s[0]);}
     setTimeout(function(){say(s[0]);setTimeout(next,6000);},1500);}
    setTimeout(next,8000);})();
    """

    // R70: the test itself lives in the page (ingSelfTest), shared with the
    // Android app: Velox must answer a question, Scriba must think, and the app
    // must reach the internet. Its lines reach the build through the "log" request.
    static let selfTestJS = """
    (function(){var t0=Date.now();
    function log(m){try{webkit.messageHandlers.ingenium.postMessage(JSON.stringify({method:'log',args:{msg:'INGENIUM_SELFTEST '+m},callId:''}));}catch(e){}}
    function go2(){if(typeof ingSelfTest==='function'&&typeof Engine!=='undefined'){ingSelfTest();}
    else if(Date.now()-t0>120000){log('ERROR the page has no self-test');log('DONE');}else{setTimeout(go2,1000);}}
    go2();})();
    """
}
