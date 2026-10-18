import WebKit

/// One-time, best-effort copy between the two origins in this app's existing
/// website data store. Never deletes the old storage or copies authentication cookies.
@MainActor
final class NativeAppearanceMigration: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var web: WKWebView!
    private var pending: CheckedContinuation<Bool, Never>?
    private var timeout: DispatchWorkItem?
    private var expectedHost = ""
    private var scriptResult: CheckedContinuation<Any, Error>?
    private var scriptTimeout: DispatchWorkItem?

    func transfer(to origin: URL) async {
        guard origin == DeviceAuthentication.productionOrigin,
              !UserDefaults.standard.bool(forKey: "native-appearance-migration-attempted-v1") else { return }
        UserDefaults.standard.set(true, forKey: "native-appearance-migration-attempted-v1")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: "appearanceMigration")
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: "appearanceMigration")
            web = nil
        }
        guard await load(URL(string: "https://app.lin-che.com/manifest.webmanifest")!) else { return }
        do {
            let exported = try await runJavaScript("""
                const preferences = {};
                for (let i = 0; i < localStorage.length; i++) {
                    const key = localStorage.key(i);
                    if (key.startsWith('linche.') || key.startsWith('linche-')) preferences[key] = localStorage.getItem(key);
                }
                const images = [];
                const databases = await indexedDB.databases();
                if (databases.some(db => db.name === 'linche-ui')) {
                    const db = await new Promise((resolve, reject) => {
                        const request = indexedDB.open('linche-ui');
                        request.onsuccess = () => resolve(request.result);
                        request.onerror = () => reject(request.error);
                    });
                    if (db.objectStoreNames.contains('appearance')) {
                        const entries = await new Promise((resolve, reject) => {
                            const tx = db.transaction('appearance', 'readonly');
                            const store = tx.objectStore('appearance');
                            const keys = store.getAllKeys();
                            const values = store.getAll();
                            tx.oncomplete = () => resolve(keys.result.map((key, i) => [key, values.result[i]]));
                            tx.onerror = () => reject(tx.error);
                        });
                        for (const [key, value] of entries) {
                            if (value instanceof Blob) {
                                const data = await new Promise((resolve, reject) => {
                                    const reader = new FileReader();
                                    reader.onload = () => resolve(reader.result.split(',')[1]);
                                    reader.onerror = reject;
                                    reader.readAsDataURL(value);
                                });
                                images.push({key, data, mime: value.type, type: 'blob'});
                            } else if (typeof value === 'string') images.push({key, data: value, type: 'string'});
                        }
                    }
                    db.close();
                }
                return {preferences, images};
                """, arguments: [:])
            guard let payload = exported as? [String: Any], await load(origin.appendingPathComponent("native-auth/status")) else { return }
            _ = try await runJavaScript("""
                // Keep any choices already made on the new origin.
                for (const [key, value] of Object.entries(payload.preferences)) {
                    if (localStorage.getItem(key) === null) localStorage.setItem(key, value);
                }
                if (!payload.images.length) return true;
                const db = await new Promise((resolve, reject) => {
                    const request = indexedDB.open('linche-ui', 1);
                    request.onupgradeneeded = () => request.result.createObjectStore('appearance');
                    request.onsuccess = () => resolve(request.result);
                    request.onerror = () => reject(request.error);
                });
                await new Promise((resolve, reject) => {
                    const tx = db.transaction('appearance', 'readwrite');
                    const store = tx.objectStore('appearance');
                    for (const image of payload.images) {
                        const existing = store.get(image.key);
                        existing.onsuccess = () => {
                            if (existing.result !== undefined) return;
                            const value = image.type === 'string' ? image.data : new Blob([Uint8Array.from(atob(image.data), c => c.charCodeAt(0))], {type: image.mime});
                            store.put(value, image.key);
                        };
                    }
                    tx.oncomplete = resolve;
                    tx.onerror = tx.onabort = () => reject(tx.error);
                });
                db.close();
                return true;
                """, arguments: ["payload": payload])
        } catch {
            // Local appearance migration must not prevent authentication. Old
            // origin data stays intact if its Access session has already expired.
        }
    }

    // Use the existing JavaScript callback bridge rather than the Swift WebKit
    // overlay, which is absent from some otherwise-supported iOS runtimes.
    private func runJavaScript(_ body: String, arguments: [String: Any]) async throws -> Any {
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let json = String(decoding: encoded, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            scriptResult = continuation
            let deadline = DispatchWorkItem { [weak self] in
                self?.finishScript(.failure(DeviceAuthError.server("migration_timeout")))
            }
            scriptTimeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
            let script = """
                Promise.resolve().then(async () => {
                    const {payload} = \(json);
                    \(body)
                }).then(value => window.webkit.messageHandlers.appearanceMigration.postMessage({value}),
                        () => window.webkit.messageHandlers.appearanceMigration.postMessage({error: true}));
                void 0;
                """
            web.evaluateJavaScript(script) { [weak self] _, error in
                if let error = error { self?.finishScript(.failure(error)) }
            }
        }
    }

    private func finishScript(_ result: Result<Any, Error>) {
        scriptTimeout?.cancel()
        let continuation = scriptResult
        scriptResult = nil
        continuation?.resume(with: result)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == expectedHost,
              let body = message.body as? [String: Any] else { return }
        if let value = body["value"] { finishScript(.success(value)) }
        else { finishScript(.failure(DeviceAuthError.server("migration_failed"))) }
    }

    private func load(_ url: URL) async -> Bool {
        expectedHost = url.host!
        return await withCheckedContinuation { continuation in
            pending = continuation
            let deadline = DispatchWorkItem { [weak self] in self?.finish(false) }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
            web.load(URLRequest(url: url))
        }
    }

    private func finish(_ success: Bool) {
        timeout?.cancel()
        let continuation = pending
        pending = nil
        continuation?.resume(returning: success)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(webView.url?.host == expectedHost) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url?.host == expectedHost && action.request.url?.scheme == "https"
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(false) }
    }
}
