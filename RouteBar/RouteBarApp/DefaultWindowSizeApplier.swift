import AppKit
import SwiftUI

/// 在主窗口创建时应用用户选择的默认尺寸。
///
/// SwiftUI 的 `defaultSize` 会被 macOS 的窗口恢复尺寸覆盖，因此需要在窗口连接后应用一次。
/// 同一尺寸只应用一次，不影响用户随后手动调整。
struct DefaultWindowSizeApplier: NSViewRepresentable {
    let dimensions: WindowDimensions
    let onResize: (WindowDimensions) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    private func apply(to view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            coordinator.observe(window: window, onResize: onResize)
            guard coordinator.appliedDimensions != dimensions else { return }
            coordinator.appliedDimensions = dimensions
            window.setContentSize(NSSize(width: dimensions.width, height: dimensions.height))
            if !coordinator.hasCentered {
                window.center()
                coordinator.hasCentered = true
            }
            coordinator.report(window: window, onResize: onResize)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var appliedDimensions: WindowDimensions?
        var hasCentered = false
        private weak var observedWindow: NSWindow?
        private var onResize: ((WindowDimensions) -> Void)?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(window: NSWindow, onResize: @escaping (WindowDimensions) -> Void) {
            guard observedWindow !== window else { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            self.onResize = onResize
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification,
                object: window
            )
            report(window: window, onResize: onResize)
        }

        @objc private func windowDidResize() {
            guard let window = observedWindow, let onResize else { return }
            report(window: window, onResize: onResize)
        }

        /// 用 contentRect（与 setContentSize 同口径），而非 contentLayoutRect（扣掉工具栏的可用区）
        /// ——否则「设为默认」回写时会把可用区当内容区再设一次，窗口每存一次就矮一截。
        func report(window: NSWindow, onResize: (WindowDimensions) -> Void) {
            let size = window.contentRect(forFrameRect: window.frame).size
            onResize(WindowDimensions(width: size.width, height: size.height))
        }
    }
}
