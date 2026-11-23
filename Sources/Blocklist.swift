import Foundation

/// Built-in tracker and ad-network blocklist, compiled into a WebKit content
/// rule list. Rules only fire for third-party loads, so visiting one of these
/// sites directly still works.
enum Blocklist {
    /// Bump when `domains` changes so the compiled rule list is rebuilt.
    static let version = 1

    static let domains: [String] = [
        // Google ads and analytics
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "app-measurement.com",
        // Meta, Microsoft, X, LinkedIn, TikTok, Snap, Pinterest pixels
        "facebook.net", "connect.facebook.com", "bat.bing.com", "clarity.ms",
        "ads-twitter.com", "analytics.twitter.com", "ads.linkedin.com",
        "snap.licdn.com", "analytics.tiktok.com", "sc-static.net", "ct.pinterest.com",
        // Ad exchanges and SSPs
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "openx.net",
        "casalemedia.com", "indexww.com", "3lift.com", "lijit.com", "sovrn.com",
        "media.net", "adform.net", "smartadserver.com", "teads.tv", "yieldmo.com",
        "sharethrough.com", "bidswitch.net", "adsrvr.org", "mathtag.com", "turn.com",
        "serving-sys.com", "advertising.com", "zedo.com", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "moatads.com",
        // Data brokers and identity graphs
        "bluekai.com", "demdex.net", "omtrdc.net", "2o7.net", "everesttech.net",
        "krxd.net", "exelator.com", "agkn.com", "rlcdn.com", "scorecardresearch.com",
        "quantserve.com", "tapad.com", "liadm.com", "id5-sync.com",
        // Session recording and product analytics
        "hotjar.com", "fullstory.com", "mouseflow.com", "crazyegg.com",
        "mixpanel.com", "amplitude.com", "segment.io", "segment.com",
        "heapanalytics.com", "chartbeat.com", "chartbeat.net", "optimizely.com",
        "nr-data.net", "statcounter.com", "histats.com", "mc.yandex.ru",
        // Mobile attribution
        "branch.io", "appsflyer.com", "adjust.com", "kochava.com",
    ]

    static func contentRulesJSON() -> String {
        var rules: [[String: Any]] = [
            // Never send cookies to third parties.
            [
                "trigger": ["url-filter": ".*", "load-type": ["third-party"]],
                "action": ["type": "block-cookies"],
            ],
        ]
        for domain in domains {
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": [
                    "url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }
}
