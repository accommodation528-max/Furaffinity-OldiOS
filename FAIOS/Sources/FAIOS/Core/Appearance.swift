import SwiftUI
import Combine

/// 外观：跟随系统 / 强制浅色 / 强制深色。
///
/// 之所以做成设置而不只跟系统走：这个 App 图片占满屏、又大量用 `.regularMaterial`，
/// 深色下工具栏和材质的对比度需要单独看一眼。有了开关就能在真机上逐屏走查两套配色，
/// 也顺手给用户一个选择（有人就是喜欢深色看图）。
@MainActor
final class Appearance: ObservableObject {

    static let shared = Appearance()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private static let key = "fa.appearance"

    @Published var mode: Mode {
        didSet {
            guard oldValue != mode else { return }
            FAStore.set(mode.rawValue, for: Self.key)
        }
    }

    private init() {
        let stored = FAStore.string(Self.key) ?? ""
        mode = Mode(rawValue: stored) ?? .system
    }
}
