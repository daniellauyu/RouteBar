import AppKit
import SwiftUI

/// 日志页筛选栏的共用尺寸。
///
/// 集中放这里，是为了让几个并排的筛选控件在以后单独调整某一个时不会各自漂移——
/// 一排选择器只要高度差一两点，看上去就是歪的。
enum LogListLayout {
    static let horizontalInset: CGFloat = 20
    static let filterVerticalInset: CGFloat = 10
    /// 筛选控件之间的间距。
    ///
    /// 12 而不是 10：`NSPopUpButton` 的圆角外框会画到分配给它的边框之外一点，
    /// 10 的时候相邻两个的外框直接连成一片，看着像一个控件——实测过。
    static let controlSpacing: CGFloat = 12
    static let groupSpacing: CGFloat = 16
    static let controlHeight: CGFloat = 24
    static let datePickerWidth: CGFloat = 108
    static let timePickerWidth: CGFloat = 116
    static let secondaryPickerWidth: CGFloat = 100
    static let searchMaximumWidth: CGFloat = 220
    static let actionMenuWidth: CGFloat = 24

    /// 日志行的列宽。
    static let levelColumn: CGFloat = 16
    static let timeColumn: CGFloat = 62
    static let sourceColumn: CGFloat = 56
    static let categoryColumn: CGFloat = 96
}

struct FilterMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// 定宽的原生弹出按钮。
///
/// 不用 SwiftUI 的 menu 样式 Picker：它在固定 frame 里仍保留自己的内边框，
/// 于是尾部留下一段随所选文字长度变化的空白——并排放四个的时候，切换选项会让
/// 后面的搜索框跟着左右跳。AppKit 的弹出按钮会铺满分配到的宽度，位置是稳的。
struct FilterMenu<Value: Hashable>: View {
    let accessibilityLabel: String
    @Binding var selection: Value
    let options: [FilterMenuOption<Value>]
    let width: CGFloat

    var body: some View {
        FilterPopUpButton(accessibilityLabel: accessibilityLabel,
                          selection: $selection,
                          options: options)
            .frame(width: width, height: LogListLayout.controlHeight)
    }
}

private struct FilterPopUpButton<Value: Hashable>: NSViewRepresentable {
    let accessibilityLabel: String
    @Binding var selection: Value
    let options: [FilterMenuOption<Value>]

    func makeCoordinator() -> FilterPopUpCoordinator { FilterPopUpCoordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(FilterPopUpCoordinator.selectionChanged(_:))
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // 交给协调器的是「拿到序号该做什么」，不是这个视图的副本——原因见协调器上的注释。
        context.coordinator.onSelect = { index in
            guard options.indices.contains(index) else { return }
            selection = options[index].value
        }
        button.setAccessibilityLabel(accessibilityLabel)

        let titles = options.map(\.title)
        if button.itemArray.map(\.title) != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }

        if let selected = options.firstIndex(where: { $0.value == selection }),
           button.indexOfSelectedItem != selected {
            button.selectItem(at: selected)
        }
    }
}

/// 弹出按钮的 target/action 接收端。
///
/// 故意写成非泛型、且放在 `FilterPopUpButton` 外面：作为嵌套类持有泛型视图副本时，
/// 视图的每一次特化都会生成自己的一份 `Coordinator`，编译器内联那份泛型 `deinit`
/// 会陷入无限递归。改成传一个闭包进来，代价为零，而且只剩一个普通类。
final class FilterPopUpCoordinator: NSObject {
    var onSelect: (Int) -> Void = { _ in }

    @objc func selectionChanged(_ sender: NSPopUpButton) {
        onSelect(sender.indexOfSelectedItem)
    }
}
