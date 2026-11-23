import Foundation

extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// Built-in pages. They run no script and load nothing from the network; the
/// CSP makes that a guarantee rather than a habit.
enum Pages {
    private static func shell(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title.htmlEscaped)</title>
        <style>
          :root { color-scheme: light dark; --ink: #1c1b19; --soft: #6b675f; --line: #dcd8cf; --bg: #f7f5f0; --accent: #2f6f4f; --warn: #a4501c; }
          @media (prefers-color-scheme: dark) {
            :root { --ink: #ece9e2; --soft: #a39e93; --line: #3a3833; --bg: #1b1a18; --accent: #7fc8a0; --warn: #e69a62; }
          }
          body { margin: 0; background: var(--bg); color: var(--ink);
                 font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
          main { max-width: 560px; margin: 14vh auto 0; padding: 0 24px; }
          h1 { font-size: 26px; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 6px; }
          p { margin: 0 0 14px; color: var(--soft); }
          ul { list-style: none; margin: 22px 0 0; padding: 0; border-top: 1px solid var(--line); }
          li { padding: 11px 0; border-bottom: 1px solid var(--line); display: flex; gap: 14px; }
          li b { flex: 0 0 150px; font-weight: 600; }
          li span { color: var(--soft); }
          code { font: 13px ui-monospace, Menlo, monospace; word-break: break-all; color: var(--ink); }
          .warn h1 { color: var(--warn); }
          .mark { color: var(--accent); font-weight: 600; letter-spacing: 0.08em; font-size: 12px; text-transform: uppercase; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func start(blockedDomainCount: Int, blocklistActive: Bool) -> String {
        let trackers = blocklistActive
            ? "\(blockedDomainCount) tracker and ad networks blocked, third-party cookies refused"
            : "Blocklist failed to load; tracker blocking is OFF"
        return shell(title: "New Tab", body: """
        <main>
          <div class="mark">Palisade</div>
          <h1>Nothing here is kept.</h1>
          <p>Type an address or a search above. This session lives in memory and ends when you quit or burn it.</p>
          <ul>
            <li><b>HTTPS only</b><span>Plain HTTP is upgraded, or refused if the site cannot do HTTPS.</span></li>
            <li><b>Trackers</b><span>\(trackers.htmlEscaped).</span></li>
            <li><b>Storage</b><span>Cookies, cache and history stay in memory. No profile on disk.</span></li>
            <li><b>Permissions</b><span>Camera, microphone and location are always denied. Pop-ups are blocked.</span></li>
            <li><b>Certificates</b><span>A bad certificate stops the page. There is no way to click through.</span></li>
            <li><b>Sandbox</b><span>The app runs in the macOS App Sandbox and can only touch a file you pick yourself.</span></li>
          </ul>
        </main>
        """)
    }

    static func error(heading: String, detail: String, url: URL?, hint: String? = nil) -> String {
        let urlLine = url.map { "<p><code>\($0.absoluteString.htmlEscaped)</code></p>" } ?? ""
        let hintLine = hint.map { "<p>\($0.htmlEscaped)</p>" } ?? ""
        return shell(title: heading, body: """
        <main class="warn">
          <div class="mark">Palisade stopped this page</div>
          <h1>\(heading.htmlEscaped)</h1>
          <p>\(detail.htmlEscaped)</p>
          \(urlLine)
          \(hintLine)
        </main>
        """)
    }
}
