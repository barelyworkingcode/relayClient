import AppIntents
import UIKit

struct VoiceChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Listening"
    static var description: IntentDescription = IntentDescription(
        "Opens Relay Client in voice chat mode",
        categoryName: "Voice"
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: "relayclient://voice_chat") else {
            throw VoiceChatIntentError.invalidURL
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}

enum VoiceChatIntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidURL

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidURL:
            return "Failed to create voice chat URL"
        }
    }
}

struct RelayClientShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VoiceChatIntent(),
            phrases: [
                "Start listening with \(.applicationName)",
                "Voice chat with \(.applicationName)",
                "Talk to Eve with \(.applicationName)"
            ],
            shortTitle: "Start Listening",
            systemImageName: "mic.fill"
        )
    }
}
