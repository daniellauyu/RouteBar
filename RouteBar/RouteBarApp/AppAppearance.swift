import SwiftUI

/// 应用主题（外观）。存于 `@AppStorage("appearance")`，套用到所有场景的 `preferredColorScheme`。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    /// nil 表示跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    static func resolve(_ raw: String) -> AppAppearance {
        AppAppearance(rawValue: raw) ?? .system
    }
}
