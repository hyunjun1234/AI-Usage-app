import WebKit
import AppKit

enum ClaudeUsageResult {
    case ok(windows: [LimitWindow], plan: String?)
    case loggedOut
    case error(String)
}

/// Hosts a WKWebView signed into claude.ai and reads the real usage limits
/// from claude.ai's own API. The user signs in once in the window; the session
/// persists across launches.
final class ClaudeWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var hasLoaded = false
    private var fetchInFlight = false
    private var loginPollTimer: Timer?
    private var popupWindows: [NSWindow] = []
    /// True once we've observed a logged-out state since the login window
    /// was opened. The window only auto-closes if we saw logged-out → ok
    /// (a real login). Opening the window while already logged in keeps it
    /// open so the user can browse claude.ai.
    private var sawLoggedOutInWindow = false
    /// claude.ai sits behind a Cloudflare "managed challenge". The web view can
    /// pass it, but only on a *fresh* load (which mints a short-lived
    /// cf_clearance cookie). When that clearance expires the usage fetch starts
    /// getting 403 challenges, so we reload the page to re-solve it. `pending…`
    /// marks a reload whose `didFinish` should re-fetch; `lastChallengeReload`
    /// throttles reloads so a perpetually-failing challenge can't spin the view.
    private var pendingRetryAfterReload = false
    private var lastChallengeReload: Date?

    // Present as real Safari — Google blocks OAuth from webviews whose UA
    // lacks the Version/Safari tokens.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    /// Called with every usage fetch result.
    var onResult: ((ClaudeUsageResult) -> Void)?

    override init() {
        super.init()
        webView = makeWebView(width: 460, height: 680)
        window = NSWindow(contentRect: webView.frame,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Claude.ai 로그인"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    private func makeWebView(width: CGFloat, height: CGFloat,
                             configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let config = configuration ?? {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()        // persistent — login survives restarts
            return c
        }()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                           configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = userAgent
        return wv
    }

    /// Brings up the sign-in window and polls quickly so it self-closes after
    /// a successful login. If the user is already logged in when they open it,
    /// the window stays open (they explicitly wanted to look at claude.ai).
    func showLoginWindow() {
        sawLoggedOutInWindow = false
        lastChallengeReload = nil
        pendingRetryAfterReload = false
        // Always reload so the window shows a fresh, solvable claude.ai page
        // (the Cloudflare challenge or the logged-in home) — never a stale,
        // expired challenge that renders as a blank white window.
        reloadHome()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        loginPollTimer?.invalidate()
        loginPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
    }

    private func stopLoginPoll() {
        loginPollTimer?.invalidate()
        loginPollTimer = nil
    }

    /// Reloads claude.ai from scratch so the Cloudflare challenge runs fresh.
    private func reloadHome() {
        hasLoaded = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    /// On a Cloudflare challenge, reload to mint a fresh cf_clearance, then retry
    /// the usage fetch once the page finishes. Throttled to once per 20s (so a
    /// challenge that never solves can't spin the view, yet we keep retrying on
    /// later cycles), and skipped while the login window is open so we never
    /// wipe out a sign-in the user is typing.
    private func reloadAndRetry() {
        guard !window.isVisible else { return }
        if let last = lastChallengeReload, Date().timeIntervalSince(last) < 20 { return }
        lastChallengeReload = Date()
        pendingRetryAfterReload = true
        reloadHome()
    }

    func windowWillClose(_ notification: Notification) {
        stopLoginPoll()
    }

    /// Fetches real usage and reports via `onResult`. Hides the login window on success.
    func refreshUsage() {
        guard hasLoaded, (webView.url?.host ?? "").contains("claude.ai"), !fetchInFlight else { return }
        fetchInFlight = true
        var finished = false
        let finish: (ClaudeUsageResult) -> Void = { [weak self] result in
            guard let self = self, !finished else { return }
            finished = true
            self.fetchInFlight = false
            if case .loggedOut = result, self.window.isVisible {
                self.sawLoggedOutInWindow = true
            }
            if case .ok = result {
                self.stopLoginPoll()
                // Only auto-close after an actual login (logged-out → ok).
                if self.window.isVisible && self.sawLoggedOutInWindow {
                    self.window.orderOut(nil)
                }
            }
            self.onResult?(result)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { finish(.error("timeout")) }

        let js = #"""
        const H = {'anthropic-client-platform':'web_claude_ai','anthropic-client-version':'1.0.0','Accept':'application/json'};
        function detectPlan(org) {
          const caps = org.capabilities || [];
          const tier = (org.rate_limit_tier || '').toLowerCase();
          const cs = caps.join(',').toLowerCase();
          if (caps.includes('claude_max') || cs.includes('max')) {
            if (tier.includes('max_20x')) return 'Max 20x';
            if (tier.includes('max_5x'))  return 'Max 5x';
            return 'Max';
          }
          if (caps.includes('pro') || cs.includes('pro')) return 'Pro';
          if (org.raven_type === 'enterprise') return 'Enterprise';
          if (org.raven_type === 'team')       return 'Team';
          if (caps.includes('free'))            return 'Free';
          if (caps.includes('api') && caps.length === 1) return 'API';
          return null;
        }
        try {
          const o = await fetch('/api/organizations', {credentials:'include', headers:H, cache:'no-store'});
          const ct = (o.headers.get('content-type') || '').toLowerCase();
          // A Cloudflare managed challenge answers with 403 + an HTML interstitial
          // ("Just a moment…"), not the JSON a real auth failure returns. Treat
          // it as a challenge (reload to re-solve), not as a logout.
          if (o.status === 403 && (o.headers.get('cf-mitigated') || ct.includes('text/html'))) {
            return JSON.stringify({state:'challenge'});
          }
          if (o.status === 401 || o.status === 403) return JSON.stringify({state:'loggedOut'});
          if (!o.ok) return JSON.stringify({state:'error', detail:'orgs ' + o.status});
          const orgs = await o.json();
          for (const org of (orgs || [])) {
            const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials:'include', headers:H, cache:'no-store'});
            if (u.ok) {
              const j = await u.json();
              if (j && (j.five_hour || j.seven_day ||
                  (Array.isArray(j.limits) && j.limits.some(l =>
                    l && ['session', 'weekly_all', 'weekly_scoped'].includes(l.kind) &&
                    typeof l.percent === 'number')))) {
                return JSON.stringify({state:'ok', usage:j, plan: detectPlan(org)});
              }
            }
          }
          return JSON.stringify({state:'error', detail:'no usage'});
        } catch (e) { return JSON.stringify({state:'error', detail:String(e)}); }
        """#

        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error):
                finish(.error(error.localizedDescription))
            case .success(let value):
                guard let string = value as? String,
                      let data = string.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let state = obj["state"] as? String else {
                    finish(.error("parse")); return
                }
                switch state {
                case "ok":
                    self.lastChallengeReload = nil
                    if let usage = obj["usage"] as? [String: Any],
                       let windows = ClaudeUsageParser.parse(usage) {
                        let plan = obj["plan"] as? String
                        finish(.ok(windows: windows, plan: plan))
                    } else {
                        finish(.error("usage parse"))
                    }
                case "loggedOut":
                    finish(.loggedOut)
                case "challenge":
                    // Cloudflare clearance expired — reload to re-solve, keep the
                    // last-known numbers (.error is treated as transient upstream).
                    NSLog("AIUsage: claude.ai Cloudflare challenge — reloading to refresh clearance")
                    self.reloadAndRetry()
                    finish(.error("challenge"))
                default:
                    finish(.error((obj["detail"] as? String) ?? "error"))
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        if pendingRetryAfterReload {
            pendingRetryAfterReload = false
            // Give the Cloudflare challenge a moment to settle, then re-fetch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshUsage()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("AIUsage: claude.ai load failed — \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("AIUsage: claude.ai navigation failed — \(error.localizedDescription)")
    }

    /// The WebContent process can be killed when the app sits in the background
    /// (menu-bar app, window hidden), leaving a blank view. Reload to recover.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("AIUsage: claude.ai web content process terminated — reloading")
        reloadHome()
    }

    // MARK: - WKUIDelegate (OAuth popups, e.g. "Continue with Google")

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open the popup in its own window so OAuth flows can complete.
        let popup = makeWebView(width: 500, height: 640, configuration: configuration)
        let popupWindow = NSWindow(contentRect: popup.frame,
                                   styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        popupWindow.title = "로그인"
        popupWindow.contentView = popup
        popupWindow.isReleasedWhenClosed = false
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        popupWindows.append(popupWindow)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let win = popupWindows.first(where: { $0.contentView === webView }) {
            win.orderOut(nil)
            popupWindows.removeAll { $0 === win }
        }
    }
}
