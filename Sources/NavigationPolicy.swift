import Foundation

/// Hosts where plain HTTP is always acceptable (traffic never leaves the machine).
let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

// MARK: - Address bar input

enum AddressParser {
    /// Turns address-bar text into a destination: a web URL if it looks like
    /// one, otherwise a search. Never returns anything but http(s).
    static func destination(for raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        return directURL(input) ?? searchURL(input)
    }

    static func directURL(_ input: String) -> URL? {
        guard !input.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = input.lowercased()
        for scheme in ["javascript:", "data:", "file:", "blob:", "about:", "view-source:"]
        where lower.hasPrefix(scheme) {
            return nil
        }
        let hasScheme = input.contains("://")
        guard var parts = URLComponents(string: hasScheme ? input : "https://" + input),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        // "user@host" is either an email address or a phishing trick; search it instead.
        guard parts.user == nil, parts.password == nil else { return nil }
        let isLoopback = loopbackHosts.contains(host)
        guard isLoopback || host.contains(".") || host.contains(":") else { return nil }
        if !hasScheme && isLoopback { parts.scheme = "http" }
        return parts.url
    }

    static func searchURL(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://duckduckgo.com/?q=\(encoded)")
    }
}

// MARK: - Tracking parameters

enum TrackingParams {
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid",
        "mc_eid", "mc_cid", "igshid", "yclid", "twclid", "ttclid", "li_fat_id",
        "_hsenc", "_hsmi", "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id",
        "vero_id", "s_cid", "_openstat", "srsltid",
    ]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || exact.contains(lower)
    }

    /// The URL without click-tracking query parameters, or nil if it had none.
    static func stripped(from url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.percentEncodedQueryItems, !items.isEmpty
        else { return nil }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return nil }
        parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return parts.url
    }
}

// MARK: - Navigation decisions

enum NavigationDecision: Equatable {
    case allow
    /// Insecure request; retry at this HTTPS URL instead.
    case upgrade(URL)
    /// Same page with tracking parameters removed.
    case clean(URL)
    case block(String)
}

enum NavigationPolicy {
    /// The single place that decides whether a navigation may proceed.
    static func decide(url: URL, isMainFrame: Bool, isGET: Bool,
                       httpAllowed: (String) -> Bool) -> NavigationDecision {
        switch (url.scheme ?? "").lowercased() {
        case "https":
            break
        case "http":
            let host = (url.host ?? "").lowercased()
            if !httpAllowed(host) {
                guard isMainFrame,
                      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else { return .block("insecure HTTP content inside a page") }
                parts.scheme = "https"
                if parts.port == 80 { parts.port = nil }
                guard let secure = parts.url else { return .block("malformed URL") }
                return .upgrade(secure)
            }
        case "about":
            let text = url.absoluteString.lowercased()
            return text.hasPrefix("about:blank") || text.hasPrefix("about:srcdoc")
                ? .allow : .block("internal page")
        case "blob":
            return .allow
        case "data":
            return isMainFrame ? .block("top-level data: URL") : .allow
        default:
            // file:, javascript:, mailto:, tel: and every app-launching custom
            // scheme. A web page never gets to open another app or a local file.
            return .block("scheme \(url.scheme ?? "?") is not allowed")
        }
        if isMainFrame, isGET, let cleaned = TrackingParams.stripped(from: url) {
            return .clean(cleaned)
        }
        return .allow
    }
}
