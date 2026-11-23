import Foundation
import WebKit

/// Everything a browsing session shares between tabs. All of it lives in
/// memory: nothing here is written to disk, and `burn()` throws it all away.
final class BrowserSession {
    static let shared = BrowserSession()

    private(set) var dataStore = WKWebsiteDataStore.nonPersistent()
    private(set) var ruleList: WKContentRuleList?
    private(set) var ruleListError: String?

    /// Hosts the user has explicitly allowed over plain HTTP this session.
    var httpAllowedHosts = Set<String>()
    /// Per-host JavaScript overrides for this session (default is on).
    var jsOverrides = [String: Bool]()

    private init() {}

    /// Compiles the blocklist. Call once at launch before opening a tab.
    func prepare(_ completion: @escaping () -> Void) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "palisade-blocklist-v\(Blocklist.version)",
            encodedContentRuleList: Blocklist.contentRulesJSON()
        ) { list, error in
            DispatchQueue.main.async {
                self.ruleList = list
                self.ruleListError = error?.localizedDescription
                completion()
            }
        }
    }

    func isHTTPAllowed(_ host: String) -> Bool {
        loopbackHosts.contains(host) || httpAllowedHosts.contains(host)
    }

    func isJavaScriptAllowed(on host: String) -> Bool {
        jsOverrides[host] ?? true
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Look like stock Safari so the browser itself is not a fingerprint.
        config.applicationNameForUserAgent = "Version/27.2 Safari/605.1.15"

        if let ruleList { config.userContentController.add(ruleList) }
        // Global Privacy Control: tell sites not to sell or share data.
        config.userContentController.addUserScript(WKUserScript(
            source: """
            try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl',
                  { get: function () { return true; }, configurable: false }); } catch (e) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        return config
    }

    /// Erases cookies, caches and site storage and forgets every exception.
    /// Tabs created afterwards get a brand new data store.
    func burn() {
        let old = dataStore
        dataStore = WKWebsiteDataStore.nonPersistent()
        old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                       modifiedSince: .distantPast) {}
        httpAllowedHosts.removeAll()
        jsOverrides.removeAll()
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }
}
