import WidgetKit
import Foundation

@MainActor
enum GardenWidgetSync {
    private static var refreshTask: Task<Void, Never>?
    private static var lastRefresh = Date.distantPast

    static func refresh(_ session: DeviceSession) {
        let changed = GardenStore.credential()?.token != session.token
        guard GardenStore.saveCredential(GardenCredential(token: session.token, expiresAt: session.expiresAt)) else { return }
        guard changed || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        refreshTask?.cancel()
        refreshTask = Task {
            _ = try? await GardenStore.fetch()
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: GardenStore.kind)
        }
    }

    static func invalidate() {
        refreshTask?.cancel()
        lastRefresh = .distantPast
        GardenStore.invalidate()
        WidgetCenter.shared.reloadTimelines(ofKind: GardenStore.kind)
    }
}
