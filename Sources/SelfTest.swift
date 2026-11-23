import AppKit
import WebKit

/// `Palisade --selftest` drives a real, headless tab through each protection
/// and prints PASS/FAIL. The live checks need network access.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "   [\(detail)]")")
        if !ok { failures += 1 }
    }

    static func run() {
        Task { @MainActor in
            await runAll()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Runs `action`, then waits for the tab to finish loading whatever it ends up on.
    private static func settle(_ tab: BrowserWindowController, timeout: TimeInterval = 25,
                               _ action: () -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var done = false
            @MainActor func finish(_ ok: Bool) {
                guard !done else { return }
                done = true
                tab.onLoadSettled = nil
                continuation.resume(returning: ok)
            }
            tab.onLoadSettled = { finish(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
            action()
        }
    }

    private static func js(_ webView: WKWebView, _ body: String,
                           _ arguments: [String: Any] = [:]) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: String(describing: value))
                case .failure(let error): continuation.resume(returning: "ERROR: \(error.localizedDescription)")
                }
            }
        }
    }

    private static let probe = """
        const ctl = new AbortController();
        const timer = setTimeout(() => ctl.abort(), 12000);
        try {
            await fetch(url, { mode: 'no-cors', cache: 'no-store', signal: ctl.signal });
            return 'loaded';
        } catch (e) {
            return e.name === 'AbortError' ? 'timeout' : 'blocked';
        } finally { clearTimeout(timer); }
        """

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func runAll() async {
        let session = BrowserSession.shared
        func decide(_ text: String, main: Bool = true) -> NavigationDecision {
            NavigationPolicy.decide(url: URL(string: text)!, isMainFrame: main, isGET: true,
                                    httpAllowed: session.isHTTPAllowed)
        }
        func isBlocked(_ decision: NavigationDecision) -> Bool {
            if case .block = decision { return true }
            return false
        }

        print("-- address bar")
        check("bare domain goes to HTTPS",
              AddressParser.destination(for: "example.com")?.absoluteString == "https://example.com")
        check("localhost keeps HTTP",
              AddressParser.destination(for: "localhost:3000")?.absoluteString == "http://localhost:3000")
        for text in ["how do browsers work", "javascript:alert(1)", "file:///etc/passwd", "someone@example.com"] {
            let url = AddressParser.destination(for: text)
            check("\"\(text)\" becomes a search, not a navigation",
                  url?.host == "duckduckgo.com" && url?.scheme == "https", url?.absoluteString ?? "nil")
        }

        print("-- navigation policy")
        check("https allowed", decide("https://example.com/") == .allow)
        check("http main frame upgraded",
              decide("http://example.com/a?b=1") == .upgrade(URL(string: "https://example.com/a?b=1")!))
        check("http subframe blocked", isBlocked(decide("http://example.com/", main: false)))
        check("http to localhost allowed", decide("http://localhost:8080/") == .allow)
        check("file: blocked", isBlocked(decide("file:///etc/passwd")))
        check("javascript: blocked", isBlocked(decide("javascript:alert(1)")))
        check("app-launching scheme blocked", isBlocked(decide("zoommtg://join?id=1")))
        check("top-level data: blocked", isBlocked(decide("data:text/html,hi")))
        check("tracking parameters stripped",
              decide("https://a.com/p?utm_source=x&id=1&fbclid=abc") == .clean(URL(string: "https://a.com/p?id=1")!))
        check("clean URL left alone", decide("https://a.com/p?id=1") == .allow)

        print("-- session")
        check("blocklist compiled", session.ruleList != nil, session.ruleListError ?? "")
        check("data store is memory-only", !session.dataStore.isPersistent)
        let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        check("running inside the App Sandbox", container != nil, container ?? "no container")
        let documents = ("~/Documents" as NSString).expandingTildeInPath
        let realDocuments = "/Users/\(NSUserName())/Documents"
        check("cannot list the user's real Documents folder",
              (try? FileManager.default.contentsOfDirectory(atPath: realDocuments)) == nil,
              "home resolves to \(documents)")

        let tab = BrowserWindowController()
        let webView = tab.webView

        print("-- JavaScript switch (offline)")
        let scripted = "<script>document.title='js-ran'</script><p>test</p>"
        let base = URL(string: "https://example.com/")!
        _ = await settle(tab) { webView.loadHTMLString(scripted, baseURL: base) }
        await pause(0.3)
        check("JavaScript runs by default", webView.title == "js-ran", webView.title ?? "nil")
        session.jsOverrides["example.com"] = false
        _ = await settle(tab) { webView.loadHTMLString(scripted, baseURL: base) }
        await pause(0.3)
        check("JavaScript off for the host stops page scripts", webView.title != "js-ran", webView.title ?? "nil")
        session.jsOverrides.removeAll()

        print("-- live pages (network)")
        var ok = await settle(tab) { tab.load(URL(string: "http://example.com/")!) }
        check("http://example.com loads as HTTPS",
              ok && !tab.isShowingError && webView.url?.scheme == "https" && webView.url?.host == "example.com",
              webView.url?.absoluteString ?? "nil")

        let tracker = "https://www.google-analytics.com/analytics.js"
        var result = await js(webView, probe, ["url": tracker])
        check("tracker request blocked", result == "blocked", result)
        result = await js(webView, probe, ["url": "https://example.org/"])
        check("ordinary third-party request still loads", result == "loaded", result)

        ok = await settle(tab) { tab.setTrackerBlocking(false) }
        result = await js(webView, probe, ["url": tracker])
        check("same tracker loads once blocking is switched off (the rule is what blocked it)",
              ok && result == "loaded", result)
        _ = await settle(tab) { tab.setTrackerBlocking(true) }

        result = await js(webView, """
            if (!navigator.mediaDevices) return 'unavailable';
            try { await navigator.mediaDevices.getUserMedia({ video: true }); return 'granted'; }
            catch (e) { return e.name; }
            """)
        check("camera access denied", result != "granted", result)
        result = await js(webView, "return String(navigator.globalPrivacyControl)")
        check("Global Privacy Control signal set", result == "true", result)

        ok = await settle(tab) { tab.load(URL(string: "https://example.com/?utm_source=news&id=7&gclid=zz")!) }
        check("tracking parameters removed from a live navigation",
              ok && webView.url?.absoluteString == "https://example.com/?id=7",
              webView.url?.absoluteString ?? "nil")

        ok = await settle(tab) { tab.load(URL(string: "https://expired.badssl.com/")!) }
        check("expired certificate stops the page", ok && tab.isShowingError,
              "error page: \(tab.isShowingError)")
        ok = await settle(tab) { tab.load(URL(string: "https://self-signed.badssl.com/")!) }
        check("self-signed certificate stops the page", ok && tab.isShowingError,
              "error page: \(tab.isShowingError)")

        print("-- burn")
        let cookie = HTTPCookie(properties: [
            .name: "sid", .value: "secret", .domain: "example.com", .path: "/", .secure: "TRUE",
        ])!
        let before = session.dataStore
        await before.httpCookieStore.setCookie(cookie)
        let stored = await before.httpCookieStore.allCookies().count
        session.httpAllowedHosts.insert("example.com")
        session.burn()
        let after = await session.dataStore.httpCookieStore.allCookies().count
        check("burn replaces the data store and forgets exceptions",
              stored >= 1 && after == 0 && session.dataStore !== before
                  && session.httpAllowedHosts.isEmpty && !session.dataStore.isPersistent,
              "cookies before: \(stored), after: \(after)")
    }
}
