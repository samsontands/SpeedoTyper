import Foundation
import Combine

/// Observable wrapper around Config that persists every mutation to the shared store.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet { store.write(config) }
    }
    @Published var permissions: Permissions

    struct Permissions: Equatable {
        var accessibility: Bool
        var model: Bool
        var screen: Bool
    }

    private let store: ConfigStore

    init(store: ConfigStore) {
        self.store = store
        self.config = store.config
        self.permissions = Permissions(
            accessibility: hasAccessibilityPermission(prompt: false),
            model: store.resolveModel() != nil,
            screen: false
        )
    }

    func refreshPermissions() {
        permissions.accessibility = hasAccessibilityPermission(prompt: false)
        permissions.model = store.resolveModel() != nil
    }
}
