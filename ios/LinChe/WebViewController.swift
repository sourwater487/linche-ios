import UIKit
import WebKit

/// A persistent browser container for the existing site. No API keys, account
/// credentials, APNs entitlement, or privileged JavaScript bridge are embedded.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private let homeURL: URL = {
        #if DEBUG
        // Simulator UI tests use only a loopback fixture server, never user data.
        if let value = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_URL"],
           let url = URL(string: value), url.scheme == "http",
           url.host == "127.0.0.1", url.port == 8765 { return url }
        #endif
        return DeviceAuthentication.productionOrigin
    }()
    private var webView: WKWebView!
    private var nativeGlass: NativeGlassBackdrop?
    private var composerStorage: UIView?
    @available(iOS 26.0, *) private var nativeComposer: NativeComposerView? { composerStorage as? NativeComposerView }
    private var composerBottom: NSLayoutConstraint?
    private var composerExtras: CGFloat = 0
    private var composerLayoutKey = ""
    private var webTop: NSLayoutConstraint!
    private var webBottom: NSLayoutConstraint!
    private var fixedPageLayoutActive = false
    private var rootScrollObservation: NSKeyValueObservation?
    private var keyboardTop: CGFloat?
    private var lastPageGeometry = ""
    private let loading = ClawdLoadingView()
    var loadingStartedAt: CFTimeInterval = 0
    private let errorPanel = UIStackView()
    private let errorLabel = UILabel()
    private var downloadFiles: [ObjectIdentifier: URL] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ClawdLoadingView.backdrop
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // Native voice buttons forward an explicit tap into the web player.
        // WebKit cannot carry native user activation through evaluateJavaScript.
        configuration.mediaTypesRequiringUserActionForPlayback = [.video]
        configuration.applicationNameForUserAgent = "LinCheIOS/1.0"
        configuration.userContentController.add(self, name: "authenticationExpired")
        configuration.userContentController.add(self, name: "fixedPageLayout")
        configuration.userContentController.add(self, name: "pageReady")
        if #available(iOS 26.0, *) {
            configuration.userContentController.add(self, name: "nativeGlass")
            configuration.userContentController.add(self, name: "nativeComposer")
            configuration.userContentController.addUserScript(WKUserScript(source: """
                if (location.hostname === '\(homeURL.host!)' && window === window.top) {
                    window.lincheNativeGlassVersion = 2;
                    window.lincheNativePresentationVersion = 2;
                    window.lincheNativeComposerVersion = 2;
                }
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let backdrop = NativeGlassBackdrop(frame: view.bounds)
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(backdrop)
            nativeGlass = backdrop
            backdrop.onAction = { [weak self] id, kind, point in
                guard let self, let generation = self.nativeGlass?.generation else { return }
                self.sendNativeGlassEvent(["generation": generation, "status": "event", "id": id,
                                           "kind": kind, "x": point.x, "y": point.y])
            }
        }
        #if DEBUG
        if homeURL.host == "127.0.0.1" {
            let requestedTheme = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_THEME"] ?? "default"
            let theme = ["liquidGlass", "iosNative"].contains(requestedTheme) ? requestedTheme : "default"
            let appearance = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_APPEARANCE"] == "dark" ? "dark" : "light"
            let conversation = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_LONG_THREAD"] == "1" ? "keyboard-thread" : "test"
            configuration.userContentController.addUserScript(WKUserScript(source:
                "localStorage.setItem('linche.visualTheme', '\(theme)'); localStorage.setItem('linche.appearance', '\(appearance)'); localStorage.setItem('linche-active-conversation-id', '\(conversation)');",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif
        configuration.userContentController.addUserScript(WKUserScript(source: """
            if (location.hostname === '\(homeURL.host!)' && window === window.top) {
                const originalFetch = window.fetch.bind(window);
                window.fetch = async (...args) => {
                    const response = await originalFetch(...args);
                    if (new URL(response.url).origin === location.origin && response.headers.get('X-LinChe-Auth') === 'required') {
                        window.webkit.messageHandlers.authenticationExpired.postMessage('expired');
                    }
                    return response;
                };
            }
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let cssURL = Bundle.main.url(forResource: "NativeLayout", withExtension: "css"),
           let css = try? String(contentsOf: cssURL, encoding: .utf8),
           let encoded = try? JSONEncoder().encode(css),
           let literal = String(data: encoded, encoding: .utf8) {
            let script = """
            if (location.hostname === '\(homeURL.host!)') {
                document.documentElement.dataset.lincheClient = 'ios';
                document.documentElement.dataset.webInputZoomSafe = 'true';
                const style = document.createElement('style');
                style.id = 'linche-native-layout';
                style.textContent = \(literal);
                document.head.appendChild(style);
                if (window === window.top) {
                    let previousPinnedLayout;
                    const reportLayout = () => {
                        const pinned = document.documentElement.classList.contains('chat-route-active') || !!document.querySelector('.ombre-page');
                        if (pinned === previousPinnedLayout) return;
                        previousPinnedLayout = pinned;
                        window.webkit.messageHandlers.fixedPageLayout.postMessage(pinned);
                    };
                    reportLayout();
                    new MutationObserver(reportLayout).observe(document.documentElement, {attributes: true, attributeFilter: ['class']});
                    new MutationObserver(reportLayout).observe(document.body, {childList: true, subtree: true});
                    // Keyboard notifications do not fire when a multiline draft
                    // grows. Track the actual editor/tray height throughout Chat.
                    let observedComposer;
                    const refreshComposerHeight = () => {
                        if (!observedComposer?.isConnected) return;
                        const root = document.documentElement;
                        const height = observedComposer.getBoundingClientRect().height + 'px';
                        if (root.style.getPropertyValue('--linche-composer-height') === height) return;
                        const messages = document.querySelector('.chat-page .messages-area');
                        const previousScroll = messages?.scrollTop || 0;
                        const follow = messages && messages.scrollHeight - previousScroll - messages.clientHeight < 96;
                        root.style.setProperty('--linche-composer-height', height);
                        if (messages) messages.scrollTop = follow ? messages.scrollHeight : previousScroll;
                    };
                    const composerResize = new ResizeObserver(refreshComposerHeight);
                    const observeComposer = () => {
                        const next = document.querySelector('.chat-page .chat-composer');
                        if (next === observedComposer) return;
                        composerResize.disconnect();
                        observedComposer = next;
                        if (next) { composerResize.observe(next); refreshComposerHeight(); }
                    };
                    observeComposer();
                    new MutationObserver(observeComposer).observe(document.body, {childList: true, subtree: true});
                }
                // React creates/replaces the header after document load and on
                // route changes. Keep a single decorative layer per header.
                const installHeaderBlur = () => {
                    const header = document.querySelector('.chat-page .chat-topbar');
                    if (!header || header.querySelector('.linche-header-blur')) return;
                    const blur = document.createElement('div');
                    blur.className = 'linche-header-blur';
                    blur.setAttribute('aria-hidden', 'true');
                    for (let i = 0; i < 5; i++) blur.appendChild(document.createElement('span'));
                    header.prepend(blur);
                };
                installHeaderBlur();
                new MutationObserver(installHeaderBlur).observe(document.body, {childList: true, subtree: true});
                // Both web themes must paint edge-to-edge inside the IPA.
                // React may update this meta tag when the theme changes.
                const viewport = document.querySelector('meta[name="viewport"]');
                const cover = 'width=device-width, initial-scale=1, viewport-fit=cover';
                if (viewport) {
                    const keepCover = () => {
                        const chat = document.documentElement.classList.contains('chat-route-active');
                        const target = cover + (chat ? ', maximum-scale=1, user-scalable=no' : '');
                        if (viewport.content !== target) viewport.content = target;
                    };
                    keepCover();
                    new MutationObserver(keepCover).observe(viewport, { attributes: true, attributeFilter: ['content'] });
                    new MutationObserver(keepCover).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
                }
            }
            """
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        webView = LinCheWebView(frame: .zero, configuration: configuration)
        (webView as? LinCheWebView)?.nativeHitTest = { [weak self] point in
            self?.nativeGlass?.acceptsTouch(point) == true
        }
        webView.isOpaque = false
        webView.backgroundColor = ClawdLoadingView.backdrop
        webView.scrollView.backgroundColor = ClawdLoadingView.backdrop
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // Keep page backgrounds behind the status bar. Only individual web
        // controls receive safe-area padding, never the entire web viewport.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        webTop = webView.topAnchor.constraint(equalTo: view.topAnchor)
        // The keyboard covers the web surface; it must never shorten it. This
        // also keeps real page pixels behind the keyboard's rounded top corners.
        webBottom = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        rootScrollObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
            guard self?.fixedPageLayoutActive == true, scroll.contentOffset != .zero else { return }
            // Fixed Chat/Ombre pages scroll their DOM content. The outer focus pan
            // must not translate the wallpaper or the entire document.
            scroll.setContentOffset(.zero, animated: false)
        }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webTop,
            webBottom
        ])
        if #available(iOS 26.0, *) {
            let composer = NativeComposerView()
            composer.isHidden = true
            composer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(composer)
            composerStorage = composer
            view.keyboardLayoutGuide.usesBottomSafeArea = false
            let bottom = composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -max(10, view.safeAreaInsets.bottom))
            composerBottom = bottom
            NSLayoutConstraint.activate([
                composer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), bottom
            ])
            composer.onEvent = { [weak self] detail in self?.sendComposerEvent(detail) }
            composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
        }
        configureLoadingUI()
        webView.load(URLRequest(url: homeURL))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updatePageInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateNativeComposerLayout()
        updatePageInsets()
    }

    private func sendComposerEvent(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('linche:native-composer', {detail: \(literal)}));")
    }

    private func updateNativeComposerLayout() {
        guard #available(iOS 26.0, *), let composer = nativeComposer else { return }
        // With usesBottomSafeArea=false, reserve the home indicator only while
        // the keyboard is closed. An open keyboard needs just the visible gap.
        let keyboardVisible = (keyboardTop ?? view.bounds.height) < view.bounds.height - view.safeAreaInsets.bottom
        composerBottom?.constant = keyboardVisible ? -8 : -max(10, view.safeAreaInsets.bottom)
        nativeGlass?.setComposerFrame(composer.isHidden ? nil : composer.frame, extras: composerExtras)
        guard !composer.isHidden, !composer.generation.isEmpty else { return }
        let key = "\(composer.generation):\(composer.measuredHeight)"
        if key != composerLayoutKey {
            composerLayoutKey = key
            sendComposerEvent(["kind": "layout", "generation": composer.generation, "height": composer.measuredHeight])
        }
    }

    private func updatePageInsets() {
        guard webView != nil, webTop != nil else { return }
        // The site paints to the screen edges. Only third-party login pages
        // receive a native inset because they have no app safe-area styling.
        let isSite = webView.url?.host == homeURL.host
        webTop.constant = isSite ? 0 : view.safeAreaInsets.top
        webBottom.constant = isSite ? 0 : -view.safeAreaInsets.bottom
        if isSite {
            let top = Int(view.safeAreaInsets.top.rounded())
            let height = Int(view.bounds.height.rounded())
            let contentHeight = Int(min(view.bounds.height, max(0, keyboardTop ?? view.bounds.height)).rounded())
            let geometry = "\(top):\(height):\(contentHeight)"
            guard geometry != lastPageGeometry else { return }
            lastPageGeometry = geometry
            webView.evaluateJavaScript("""
                (() => {
                const root = document.documentElement;
                const messageArea = document.querySelector('.chat-page .messages-area');
                const composer = document.querySelector('.chat-page .chat-composer');
                let distance = messageArea ? Math.max(0, messageArea.scrollHeight - messageArea.scrollTop - messageArea.clientHeight) : 0;
                let followLatest = messageArea && distance < 96;
                const previousScroll = messageArea?.scrollTop;
                const composerHeight = composer?.getBoundingClientRect().height;
                const fromPadding = messageArea ? parseFloat(getComputedStyle(messageArea).paddingBottom) : 0;
                const glass = root.dataset.visualTheme === 'liquid-glass';
                const contentEnd = messageArea ? Array.from(messageArea.children)
                    .filter(child => !child.classList.contains('liquid-glass-refraction-canvas'))
                    .reduce((bottom, child) => Math.max(bottom, child.getBoundingClientRect().bottom - messageArea.getBoundingClientRect().top + messageArea.scrollTop), 0) : 0;
                if (messageArea && glass) {
                    distance = Math.max(0, contentEnd + fromPadding - messageArea.clientHeight - messageArea.scrollTop);
                    followLatest = distance < 96;
                }
                const targetBottom = \(height - contentHeight) > 0 ? 8 : Math.max(10, \(Int(view.safeAreaInsets.bottom.rounded())));
                root.style.setProperty('--linche-safe-top', '\(top)px');
                root.style.setProperty('--linche-background-height', '\(height)px');
                if (composerHeight) root.style.setProperty('--linche-composer-height', composerHeight + 'px');
                root.dataset.lincheKeyboard = \(height - contentHeight) > 0 ? 'open' : 'closed';
                // Apply the native keyboard geometry once. No JS animation,
                // timers or second timeline chasing the system keyboard.
                root.style.setProperty('--linche-content-height', '\(contentHeight)px');
                root.style.setProperty('--linche-keyboard-height', '\(height - contentHeight)px');
                root.style.setProperty('--linche-composer-bottom', targetBottom + 'px');
                if (messageArea && followLatest) {
                    const padding = parseFloat(getComputedStyle(messageArea).paddingBottom) || 0;
                    messageArea.scrollTop = Math.max(0, (glass ? contentEnd + padding : messageArea.scrollHeight) - messageArea.clientHeight - distance);
                } else if (messageArea) {
                    messageArea.scrollTop = previousScroll;
                }
                })();
                """, completionHandler: nil)
        }
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        let overlap = view.bounds.intersection(local)
        // Floating keyboards should not shrink the whole content column.
        keyboardTop = !overlap.isNull && overlap.width >= view.bounds.width * 0.9 ? overlap.minY : nil
        updatePageInsets()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastPageGeometry = ""
        updatePageInsets()
    }

    private func configureLoadingUI() {
        loading.startedAt = loadingStartedAt
        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        errorPanel.axis = .vertical
        errorPanel.spacing = 16
        errorPanel.alignment = .center
        errorPanel.backgroundColor = .systemBackground
        errorPanel.isLayoutMarginsRelativeArrangement = true
        errorPanel.layoutMargins = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        errorPanel.layer.cornerRadius = 16
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.font = .preferredFont(forTextStyle: .body)
        let retry = UIButton(type: .system)
        retry.setTitle("重新连接", for: .normal)
        retry.addTarget(self, action: #selector(retryLoading), for: .touchUpInside)
        errorPanel.addArrangedSubview(errorLabel)
        errorPanel.addArrangedSubview(retry)
        errorPanel.translatesAutoresizingMaskIntoConstraints = false
        errorPanel.isHidden = true
        view.addSubview(errorPanel)
        let errorTop = errorPanel.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 120)
        errorTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            loading.topAnchor.constraint(equalTo: view.topAnchor),
            loading.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loading.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loading.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorTop,
            errorPanel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            errorPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            errorPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            errorPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    @objc private func retryLoading() {
        errorPanel.isHidden = true
        // Restart from the site so expired Access login URLs are not replayed.
        let current = webView.url
        let url = current?.host == homeURL.host ? current! : homeURL
        webView.load(URLRequest(url: url))
    }

    func reloadAfterAuthentication() { retryLoading() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == homeURL.host else { return }
        if message.name == "nativeComposer", #available(iOS 26.0, *),
           let body = message.body as? [String: Any], let composer = nativeComposer {
            if body["command"] as? String == "focus" { composer.focus(body); return }
            if body["active"] as? Bool == false {
                guard body["generation"] as? String == composer.generation else { return }
                composer.reset(); composer.isHidden = true; composerLayoutKey = ""
            } else {
                composer.apply(body)
                composer.isHidden = body["visible"] as? Bool != true
                composerExtras = max(0, body["extrasHeight"] as? CGFloat ?? 0)
                if composer.isHidden { composer.editor.resignFirstResponder() }
            }
            view.setNeedsLayout()
            view.layoutIfNeeded()
            updateNativeComposerLayout()
        } else if message.name == "nativeGlass", #available(iOS 26.0, *),
           let body = message.body as? [String: Any], let backdrop = nativeGlass,
           let generation = body["generation"] as? String, generation.count < 80 {
            switch body["action"] as? String {
            case "begin":
                backdrop.prepare(body) { [weak self] success in
                    self?.replyToNativeGlass(generation, status: success ? "prepared" : "error")
                }
            case "state":
                guard backdrop.generation == generation else { return }
                let success = backdrop.apply(body)
                if success {
                    webView.backgroundColor = .clear
                    webView.scrollView.backgroundColor = .clear
                }
                replyToNativeGlass(generation, status: success ? "applied" : "error",
                                   sequence: body["sequence"] as? Int ?? 0)
            case "jump":
                guard backdrop.generation == generation, let id = body["messageId"] as? String else { return }
                backdrop.jump(to: id)
            case "clipboard":
                guard backdrop.generation == generation, let text = body["text"] as? String else { return }
                UIPasteboard.general.string = text
            case "stop":
                guard backdrop.generation == generation else { return }
                resetNativeGlass()
            default: break
            }
        } else if message.name == "fixedPageLayout", let active = message.body as? Bool {
            fixedPageLayoutActive = active
            webView.scrollView.bounces = !active
            if active { webView.scrollView.setContentOffset(.zero, animated: false) }
            lastPageGeometry = ""
            updatePageInsets()
        } else if message.name == "pageReady" {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LINCHE_UI_TEST_LOADING"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.loading.finish() }
                return
            }
            #endif
            loading.finish()
        } else if message.name == "authenticationExpired" {
            NotificationCenter.default.post(name: .nativeAuthenticationRequired, object: nil)
        }
    }

    private func showFailure(_ message: String) {
        if #available(iOS 26.0, *) { nativeComposer?.reset(); nativeComposer?.isHidden = true; composerLayoutKey = "" }
        resetNativeGlass()
        loading.fail()
        errorLabel.text = message
        errorPanel.isHidden = false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if #available(iOS 26.0, *) { nativeComposer?.reset(); nativeComposer?.isHidden = true; composerLayoutKey = "" }
        resetNativeGlass()
        errorPanel.isHidden = true
        loading.startAnimating()
    }

    private func resetNativeGlass() {
        nativeGlass?.stop()
        webView?.backgroundColor = ClawdLoadingView.backdrop
        webView?.scrollView.backgroundColor = ClawdLoadingView.backdrop
    }

    private func replyToNativeGlass(_ generation: String, status: String, sequence: Int = 0) {
        let detail: [String: Any] = ["generation": generation, "status": status, "sequence": sequence]
        sendNativeGlassEvent(detail)
    }

    private func sendNativeGlassEvent(_ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('linche-native-glass', {detail: \(literal)}));")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updatePageInsets()
        guard webView.url?.host == homeURL.host else { loading.finish(); return }
        webView.evaluateJavaScript("""
            (() => {
                const root = document.getElementById('root');
                const ready = () => requestAnimationFrame(() => requestAnimationFrame(() => window.webkit.messageHandlers.pageReady.postMessage(true)));
                if (!root || root.childElementCount) { ready(); return; }
                const observer = new MutationObserver(() => {
                    if (root.childElementCount) { observer.disconnect(); ready(); }
                });
                observer.observe(root, {childList: true});
            })();
            """, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        showFailure("暂时无法连接 Lin & Che。\n请检查网络后重试。")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure("页面已暂停。请重新连接以恢复。")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Embedded media/frames retain WebKit's normal origin restrictions.
        if let frame = action.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        let sameSiteScheme = url.host == homeURL.host && scheme == homeURL.scheme
        if sameSiteScheme {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if ["http", "https", "mailto", "tel"].contains(scheme) {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links have already passed the navigation policy.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse, http.url?.host == homeURL.host,
           http.value(forHTTPHeaderField: "X-LinChe-Auth") == "required" {
            decisionHandler(.cancel)
            NotificationCenter.default.post(name: .nativeAuthenticationRequired, object: nil)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        loading.stopAnimating()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        loading.stopAnimating()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = (suggestedFilename as NSString).lastPathComponent
            let destination = directory.appendingPathComponent(filename.isEmpty ? "download" : filename)
            downloadFiles[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch { completionHandler(nil) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadFiles.removeValue(forKey: ObjectIdentifier(download))
        let alert = UIAlertController(title: "下载未完成", message: "请检查网络后重试。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // Preserve the website's confirmation dialogs, including destructive actions.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        present(alert, animated: true)
    }
}
