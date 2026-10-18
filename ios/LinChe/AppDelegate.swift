import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = ClawdLoadingView.backdrop
        #if DEBUG
        if let style = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_SYSTEM_STYLE"] {
            window.overrideUserInterfaceStyle = style == "dark" ? .dark : .light
        }
        let layoutTest = ProcessInfo.processInfo.environment["LINCHE_UI_TEST_URL"]?.hasPrefix("http://127.0.0.1:8765/") == true && ProcessInfo.processInfo.environment["LINCHE_AUTH_TEST"] != "1"
        window.rootViewController = layoutTest ? WebViewController() : EntryViewController()
        #else
        window.rootViewController = EntryViewController()
        #endif
        self.window = window
        window.makeKeyAndVisible()
        if connectionOptions.urlContexts.contains(where: { $0.url.scheme == "linche" && $0.url.host == "garden" }) {
            (window.rootViewController as? EntryViewController)?.openGarden()
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard URLContexts.contains(where: { $0.url.scheme == "linche" && $0.url.host == "garden" }) else { return }
        (window?.rootViewController as? EntryViewController)?.openGarden()
    }
}
