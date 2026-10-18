import UIKit
import WebKit
import LocalAuthentication

extension Notification.Name {
    static let nativeAuthenticationRequired = Notification.Name("LinCheNativeAuthenticationRequired")
}

@MainActor
final class EntryViewController: UIViewController {
    private let auth = DeviceAuthentication()
    private let panel = UIStackView()
    private let titleLabel = UILabel()
    private let message = UILabel()
    private let code = UITextField()
    private let primary = UIButton(type: .system)
    private let repair = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let launchSpinner = ClawdLoadingView()
    private var web: WebViewController?
    private var expiryTimer: Timer?
    private var inFlight = false
    private var loadedToken: String?
    private var panelCenter: NSLayoutConstraint!
    private var failurePanelTop: NSLayoutConstraint!
    private enum Action { case pair, renew, retry }
    private var action: Action = .retry

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ClawdLoadingView.backdrop
        titleLabel.text = "Lin & Che"
        titleLabel.font = .systemFont(ofSize: 32, weight: .light)
        titleLabel.textAlignment = .center
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .secondaryLabel
        code.placeholder = "输入一次性配对码"
        code.accessibilityIdentifier = "pairing-code"
        code.borderStyle = .roundedRect
        code.autocorrectionType = .no
        code.autocapitalizationType = .allCharacters
        code.textContentType = .oneTimeCode
        code.returnKeyType = .done
        primary.addTarget(self, action: #selector(performAction), for: .touchUpInside)
        primary.accessibilityIdentifier = "authenticate-device"
        repair.setTitle("重新配对", for: .normal)
        repair.addTarget(self, action: #selector(confirmRepair), for: .touchUpInside)
        spinner.hidesWhenStopped = true
        // Authentication controls stay hidden until stored credentials have
        // been checked. A paired cold launch only shows the loading indicator.
        panel.isHidden = true
        launchSpinner.accessibilityIdentifier = "session-loading"
        launchSpinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launchSpinner)
        panel.axis = .vertical
        panel.spacing = 22
        for child in [titleLabel, message, code, primary, repair, spinner] { panel.addArrangedSubview(child) }
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let center = panel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        center.priority = .defaultHigh
        panelCenter = center
        failurePanelTop = panel.topAnchor.constraint(equalTo: view.centerYAnchor, constant: 120)
        failurePanelTop.priority = .defaultHigh
        let width = panel.widthAnchor.constraint(equalToConstant: 340)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            launchSpinner.topAnchor.constraint(equalTo: view.topAnchor),
            launchSpinner.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            launchSpinner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launchSpinner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            center,
            width,
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -20),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            code.heightAnchor.constraint(equalToConstant: 48),
            primary.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(expired), name: .nativeAuthenticationRequired, object: nil)
        resume()
    }

    private func showAuthenticationPanel() {
        launchSpinner.stopAnimating()
        failurePanelTop.isActive = false
        panelCenter.isActive = true
        titleLabel.isHidden = false
        web?.view.isHidden = true
        panel.isHidden = false
    }

    private func show(_ action: Action, _ text: String) {
        self.action = action
        showAuthenticationPanel()
        message.text = text
        code.isHidden = action != .pair
        primary.isHidden = false
        primary.setTitle(action == .pair ? "配对这台设备" : action == .renew ? "使用 Face ID 继续" : "重新连接", for: .normal)
        repair.isHidden = action == .pair
    }

    @objc private func expired() {
        expiryTimer?.invalidate()
        web?.view.isHidden = true
        show(.renew, "登录已到期，验证身份后可继续使用 30 天。")
    }

    @objc private func resume() {
        guard !inFlight else { return }
        run {
            guard let deviceId = try self.auth.deviceId(), !deviceId.isEmpty else {
                self.show(.pair, "首次使用，请输入配对码。以后覆盖更新无需重新配对。")
                return
            }
            guard let session = try self.auth.savedSession(), session.expiry > Date() else { self.expired(); return }
            do { try await self.auth.validate(session) }
            catch DeviceAuthError.server("authentication_required") { self.expired(); return }
            catch {
                // Keep an already-open, unexpired session visible during transient
                // network failures. Protected API requests still enforce revocation.
                if self.loadedToken == session.token && self.web?.view.isHidden == false { return }
                throw error
            }
            try await self.open(session)
        }
    }

    @objc private func performAction() {
        guard !inFlight else { return }
        view.endEditing(true)
        if action == .retry { resume(); return }
        let pairing = action == .pair
        let value = code.text ?? ""
        run {
            let session = try await (pairing ? self.auth.pair(code: value) : self.auth.renew())
            self.code.text = nil
            try await self.open(session)
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !inFlight else { return }
        inFlight = true
        primary.isEnabled = false
        repair.isEnabled = false
        spinner.startAnimating()
        if launchSpinner.isShowingFailure {
            panel.isHidden = true
            failurePanelTop.isActive = false
            panelCenter.isActive = true
            launchSpinner.startAnimating()
        } else if web == nil && panel.isHidden { launchSpinner.startAnimating() }
        Task {
            defer {
                inFlight = false
                primary.isEnabled = true
                repair.isEnabled = true
                spinner.stopAnimating()
                if !launchSpinner.isShowingFailure { launchSpinner.stopAnimating() }
            }
            do { try await operation() }
            catch {
                let cancelled = (error as? LAError)?.code == .userCancel || (error as? LAError)?.code == .systemCancel
                let text = cancelled ? "已取消验证。准备好后可以重试。" : error.localizedDescription
                if !cancelled && !launchSpinner.isHidden {
                    action = .retry
                    message.text = text
                    titleLabel.isHidden = true
                    code.isHidden = true
                    repair.isHidden = true
                    primary.isHidden = false
                    primary.setTitle("重新连接", for: .normal)
                    panelCenter.isActive = false
                    failurePanelTop.isActive = true
                    panel.isHidden = false
                    launchSpinner.fail()
                } else {
                    show(action, text)
                }
            }
        }
    }

    private func open(_ session: DeviceSession) async throws {
        // Foreground checks must not reload, hide, or disturb the current page.
        if loadedToken == session.token, let web = web {
            web.view.isHidden = false
            panel.isHidden = true
            return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let lifetime = max(0, Int(session.expiry.timeIntervalSinceNow))
        let header = "\(auth.cookieName)=\(session.token); Path=/; Max-Age=\(lifetime); Secure; HttpOnly; SameSite=Strict"
        // Secure __Host- cookies must be parsed against an HTTPS origin, including
        // in simulator tests whose loopback fixture transport itself uses HTTP.
        var cookieOrigin = URLComponents(url: auth.origin, resolvingAgainstBaseURL: false)!
        cookieOrigin.scheme = "https"
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: cookieOrigin.url!).first else {
            throw DeviceAuthError.server("invalid_session")
        }
        guard cookie.isHTTPOnly && cookie.isSecure else { throw DeviceAuthError.server("invalid_session") }
        await store.setCookie(cookie)
        if web == nil {
            panel.isHidden = true
            launchSpinner.startAnimating()
            await NativeAppearanceMigration().transfer(to: auth.origin)
            let controller = WebViewController()
            controller.loadingStartedAt = launchSpinner.startedAt
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(controller.view, at: 0)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            controller.didMove(toParent: self)
            web = controller
        } else if loadedToken != session.token {
            web?.reloadAfterAuthentication()
        }
        loadedToken = session.token
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: max(1, session.expiry.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expired() }
        }
        message.text = nil
        web?.view.isHidden = false
        panel.isHidden = true
    }

    @objc private func confirmRepair() {
        let alert = UIAlertController(title: "重新配对这台设备？", message: "将替换本机的登录凭证，需要一个新的配对码。聊天和服务器数据不会删除。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重新配对", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            do {
                try self.auth.resetPairing()
                self.expiryTimer?.invalidate()
                self.show(.pair, "请输入新的配对码。")
            } catch { self.show(.retry, error.localizedDescription) }
        })
        present(alert, animated: true)
    }
}
