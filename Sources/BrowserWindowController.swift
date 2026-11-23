import AppKit
import WebKit

/// One tab: a window (tabbed natively by macOS) holding a toolbar and a web view.
final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    let webView: WKWebView
    /// Fires each time a page (or an error page) finishes loading. Used by the self-test.
    var onLoadSettled: (() -> Void)?
    private(set) var trackerBlockingEnabled = true
    /// The URL that failed, while the error page for it is showing.
    private(set) var failedURL: URL?
    var isShowingError: Bool { failedURL != nil }

    private let session = BrowserSession.shared
    private let addressField = NSTextField()
    private let securityIcon = NSImageView()
    private let progress = NSProgressIndicator()
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var shieldButton: NSButton!
    private var observations = [NSKeyValueObservation]()
    private var upgradedHosts = Set<String>()
    private var downloadTargets = [ObjectIdentifier: URL]()

    // MARK: Setup

    init(configuration: WKWebViewConfiguration? = nil) {
        webView = WKWebView(frame: .zero,
                            configuration: configuration ?? BrowserSession.shared.makeConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "PalisadeBrowser"
        window.minSize = NSSize(width: 480, height: 320)
        window.title = "New Tab"
        window.center()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false

        buildInterface()
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.url) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.refreshChrome() },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in self?.refreshChrome() },
        ]
        refreshChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func buildInterface() {
        backButton = makeButton("chevron.left", "Back", #selector(navigateBack(_:)))
        forwardButton = makeButton("chevron.right", "Forward", #selector(navigateForward(_:)))
        reloadButton = makeButton("arrow.clockwise", "Reload", #selector(reloadPage(_:)))
        shieldButton = makeButton("shield.lefthalf.filled", "Protections for this site",
                                  #selector(showShieldMenu(_:)))
        let burnButton = makeButton("flame", "Burn session: close everything and erase all site data",
                                    #selector(AppDelegate.burnSession(_:)))
        burnButton.target = NSApp.delegate

        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        addressField.placeholderString = "Search or enter address"
        addressField.bezelStyle = .roundedBezel
        addressField.font = .systemFont(ofSize: 13)
        addressField.usesSingleLineMode = true
        addressField.lineBreakMode = .byTruncatingTail
        addressField.cell?.isScrollable = true
        addressField.cell?.sendsActionOnEndEditing = false
        addressField.target = self
        addressField.action = #selector(addressEntered(_:))
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton,
                                      securityIcon, addressField, shieldButton, burnButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small

        let content = NSView()
        for view in [bar, webView, progress] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.centerYAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        window?.contentView = content
    }

    // MARK: Loading

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func showStartPage() {
        failedURL = nil
        webView.loadHTMLString(
            Pages.start(blockedDomainCount: Blocklist.domains.count,
                        blocklistActive: session.ruleList != nil),
            baseURL: nil)
        window?.makeFirstResponder(addressField)
    }

    func setTrackerBlocking(_ enabled: Bool) {
        trackerBlockingEnabled = enabled
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if enabled, let list = session.ruleList { controller.add(list) }
        reloadPage(nil)
    }

    private func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Host of the page being shown (or the one that failed), if it is a web page.
    private var currentHost: String? {
        let url = failedURL ?? webView.url
        return isWeb(url) ? url?.host?.lowercased() : nil
    }

    // MARK: Chrome

    private func refreshChrome() {
        let shown = failedURL ?? webView.url
        let web = isWeb(shown)

        if failedURL != nil {
            window?.title = "Page blocked"
        } else if let title = webView.title, !title.isEmpty {
            window?.title = title
        } else {
            window?.title = web ? (shown?.host ?? "Loading") : "New Tab"
        }
        if addressField.currentEditor() == nil {
            // URL hosts are shown as WebKit reports them: internationalised
            // names appear in punycode, so look-alike domains are visible.
            addressField.stringValue = web ? (shown?.absoluteString ?? "") : ""
        }
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.image = NSImage(
            systemSymbolName: webView.isLoading ? "xmark" : "arrow.clockwise",
            accessibilityDescription: webView.isLoading ? "Stop" : "Reload")
        progress.doubleValue = webView.estimatedProgress
        progress.isHidden = !webView.isLoading

        let symbol: String, tint: NSColor, tip: String
        if failedURL != nil {
            (symbol, tint, tip) = ("exclamationmark.triangle.fill", .systemOrange, "This page was stopped")
        } else if web, shown?.scheme?.lowercased() == "https", webView.hasOnlySecureContent {
            (symbol, tint, tip) = ("lock.fill", .secondaryLabelColor, "Encrypted connection")
        } else if web {
            (symbol, tint, tip) = ("exclamationmark.triangle.fill", .systemOrange,
                                   "Not fully encrypted: anyone on the network can read or change this page")
        } else {
            (symbol, tint, tip) = ("magnifyingglass", .tertiaryLabelColor, "")
        }
        securityIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        securityIcon.contentTintColor = tint
        securityIcon.toolTip = tip
    }

    // MARK: Actions

    @objc private func addressEntered(_ sender: NSTextField) {
        guard let url = AddressParser.destination(for: sender.stringValue) else { return }
        window?.makeFirstResponder(webView)
        load(url)
    }

    @objc func focusAddressBar(_ sender: Any?) {
        window?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    @objc func navigateBack(_ sender: Any?) { webView.goBack() }
    @objc func navigateForward(_ sender: Any?) { webView.goForward() }

    @objc func reloadPage(_ sender: Any?) {
        if webView.isLoading, sender != nil {
            webView.stopLoading()
        } else if let failed = failedURL {
            load(failed)
        } else if isWeb(webView.url) {
            webView.reload()
        }
    }

    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset(_ sender: Any?) { webView.pageZoom = 1 }

    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newTab(sender)
    }

    @objc private func showShieldMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ action: Selector?, checked: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            item.isEnabled = enabled && action != nil
            menu.addItem(item)
        }

        add(trackerBlockingEnabled ? "Block trackers and ads in this tab"
                                   : "Block trackers and ads in this tab (off)",
            #selector(toggleTrackerBlocking(_:)),
            checked: trackerBlockingEnabled, enabled: session.ruleList != nil)
        if let host = currentHost {
            add("JavaScript on \(host)", #selector(toggleJavaScript(_:)),
                checked: session.isJavaScriptAllowed(on: host))
            if !loopbackHosts.contains(host) {
                add("Allow insecure HTTP on \(host) (this session)", #selector(toggleHTTP(_:)),
                    checked: session.httpAllowedHosts.contains(host))
            }
        }
        menu.addItem(.separator())
        add("Cookies and site data are kept in memory only", nil)
        add("Camera, microphone and location are always denied", nil)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleTrackerBlocking(_ sender: Any?) {
        setTrackerBlocking(!trackerBlockingEnabled)
    }

    @objc private func toggleJavaScript(_ sender: Any?) {
        guard let host = currentHost else { return }
        session.jsOverrides[host] = !session.isJavaScriptAllowed(on: host)
        reloadPage(nil)
    }

    @objc private func toggleHTTP(_ sender: Any?) {
        guard let host = currentHost else { return }
        if session.httpAllowedHosts.contains(host) {
            session.httpAllowedHosts.remove(host)
            reloadPage(nil)
        } else {
            session.httpAllowedHosts.insert(host)
            if let base = failedURL ?? webView.url,
               var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                parts.scheme = "http"
                if let insecure = parts.url { load(insecure) }
            }
        }
    }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let isGET = (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET"
        let decision = NavigationPolicy.decide(url: url, isMainFrame: isMainFrame, isGET: isGET,
                                               httpAllowed: session.isHTTPAllowed)
        switch decision {
        case .allow:
            if isMainFrame, let host = url.host?.lowercased() {
                preferences.allowsContentJavaScript = session.isJavaScriptAllowed(on: host)
            }
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow, preferences)
        case .upgrade(let secure):
            decisionHandler(.cancel, preferences)
            if let host = secure.host?.lowercased() { upgradedHosts.insert(host) }
            DispatchQueue.main.async { webView.load(URLRequest(url: secure)) }
        case .clean(let cleaned):
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async { webView.load(URLRequest(url: cleaned)) }
        case .block:
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isWeb(webView.url) { failedURL = nil }
        refreshChrome()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshChrome()
        onLoadSettled?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let url = webView.url
        failedURL = isWeb(url) ? url : nil
        webView.loadHTMLString(
            Pages.error(heading: "This page crashed",
                        detail: "The process rendering it quit. Nothing else was affected. Reload to try again.",
                        url: url),
            baseURL: nil)
    }

    private func showFailure(_ error: Error) {
        let nsError = error as NSError
        // Cancellations are ours (upgrades, cleaned URLs, blocked schemes);
        // WebKit 102 means the load turned into a download.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 || nsError.code == 204 { return }

        let url = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        let host = url?.host?.lowercased() ?? ""
        let tlsCodes = [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                        NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                        NSURLErrorClientCertificateRequired]
        let isTLS = nsError.domain == NSURLErrorDomain && tlsCodes.contains(nsError.code)

        let heading: String, detail: String
        var hint: String?
        if isTLS {
            heading = "This connection is not private"
            detail = "The site's certificate could not be verified, so someone may be impersonating it. "
                + "Palisade will not load it and there is no override. (\(nsError.localizedDescription))"
        } else {
            heading = "Can't open this page"
            detail = nsError.localizedDescription
        }
        if upgradedHosts.contains(host), !session.httpAllowedHosts.contains(host) {
            hint = "This address was requested over plain HTTP and upgraded to HTTPS. If the site truly "
                + "has no HTTPS, you can allow insecure HTTP for it from the shield menu."
        }
        failedURL = isWeb(url) ? url : nil
        webView.loadHTMLString(Pages.error(heading: heading, detail: detail, url: url, hint: hint),
                               baseURL: nil)
        refreshChrome()
    }

    // MARK: Windows, dialogs and permissions

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only reached for user-initiated opens; script-initiated pop-ups are
        // already blocked by javaScriptCanOpenWindowsAutomatically = false.
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        let tab = app.openTab(configuration: configuration, from: self)
        tab.trackerBlockingEnabled = trackerBlockingEnabled
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    private func dialog(from frame: WKFrameInfo, message: String) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = String(message.prefix(2000))
        return alert
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window else { return completionHandler() }
        dialog(from: frame, message: message).beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window else { return completionHandler(false) }
        let alert = dialog(from: frame, message: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let alert = dialog(from: frame, message: prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.message = "\(frame.securityOrigin.host) wants you to choose a file to upload."
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Nothing is saved without the user choosing where. Files written by a
    /// sandboxed app are quarantined by macOS, so Gatekeeper checks them on open.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let window else { return completionHandler(nil) }
        var name = (suggestedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name.hasPrefix(".") { name = "download" + name }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.message = "Download from \(response.url?.host ?? "this site"). Only open files you trust."
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let destination = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: destination)
            self?.downloadTargets[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let destination = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Window lifecycle

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        observations.removeAll()
        (NSApp.delegate as? AppDelegate)?.tabDidClose(self)
    }
}
