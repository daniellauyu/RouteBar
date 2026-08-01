import Foundation

public struct WindowDimensions: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public nonisolated var label: String {
        "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }
}

/// 主窗口首次创建时使用的默认尺寸；用户仍可在打开后自由调整窗口。
public enum DefaultWindowSize: String, CaseIterable, Identifiable, Sendable {
    case small = "小"
    case medium = "中"
    case large = "大"
    case custom = "自定义"

    public nonisolated var id: String { rawValue }

    public nonisolated var width: Double {
        switch self {
        case .small: 1_180
        case .medium: 1_440
        case .large: 1_760
        case .custom: 1_180
        }
    }

    public nonisolated var height: Double {
        switch self {
        case .small: 760
        case .medium: 900
        case .large: 1_100
        case .custom: 760
        }
    }

    public nonisolated var dimensionsLabel: String { "\(Int(width)) × \(Int(height))" }

    public nonisolated func dimensions(custom: WindowDimensions) -> WindowDimensions {
        self == .custom ? custom : WindowDimensions(width: width, height: height)
    }

    public nonisolated static func resolve(_ raw: String) -> DefaultWindowSize {
        DefaultWindowSize(rawValue: raw) ?? .small
    }
}
