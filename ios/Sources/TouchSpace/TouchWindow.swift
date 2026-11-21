// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// iOS：触感空间画在**单独一层透明窗口**里（这样回话一到就能重拍下面的聊天页，回话直接出现在被摸的画面里）。
///
/// 原来空间是盖在聊天页同一个窗口里的一层：给聊天页拍照（`drawHierarchy`）只能拍整个窗口，会把胶囊、
/// 回话卡片一起拍进去，所以只能在进空间那一刻拍一次，之后聊天页再怎么变（模型回话了）空间里也看不到。
/// 现在空间在自己的窗口里（和键盘、系统弹窗一样是 App 里的另一层），拍聊天页那一层时上面的东西不会进去，
/// 回话一到就重拍（`TouchSpace.refreshSnapshotSoon`），回话真的出现在聊天记录里，也能被摸。
///
/// 怎么对准：`decorateRoot` 在根视图背后垫一个看不见的锚点（`TouchWindowAnchor`）。空间打开时在锚点
/// 所在的位置开一扇同样大的窗口（可以是整个聊天，也可以只是其中一块），开着期间每帧对一次位置
/// （进空间时宿主页面可能还在滑动）。锚点所在的那个窗口记在 `space.hostWindow`：截图、换算画布位置都对着它。
/// Mac 没有这一层，照旧盖在窗口里（`TouchSpaceLayer`）。
struct TouchWindowAnchor: UIViewRepresentable {
    let space: TouchSpace

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.space = space
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {}

    @MainActor
    final class AnchorView: UIView {
        weak var space: TouchSpace? {
            didSet { watch() }
        }
        private var overlay: UIWindow?
        private var openWatch: AnyCancellable?
        private var follow: CADisplayLink?
        private var hideTask: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            space?.hostWindow = window
        }

        private func watch() {
            openWatch = space?.$isOpen.removeDuplicates().sink { [weak self] open in
                // `@Published` 在 willSet 里发值：挪到下一拍，那时 `isOpen` 已经是新值。
                Task { @MainActor in open ? self?.present() : self?.dismiss() }
            }
        }

        /// 锚点在屏幕上的矩形（窗口的 frame 用屏幕坐标）。
        private var screenRect: CGRect? {
            guard let window else { return nil }
            return window.convert(convert(bounds, to: window), to: window.screen.coordinateSpace)
        }

        private func present() {
            hideTask?.cancel()
            guard let space, let window, let scene = window.windowScene, let rect = screenRect else { return }
            if overlay == nil {
                let overlay = UIWindow(windowScene: scene)
                overlay.windowLevel = window.windowLevel + 1
                overlay.backgroundColor = .clear
                let host = UIHostingController(rootView: TouchSpaceLayer(space: space))
                host.view.backgroundColor = .clear
                overlay.rootViewController = host
                self.overlay = overlay
            }
            overlay!.frame = rect
            // 不抢 key window：截图找的是聊天那一层；这一层照样收触摸。
            overlay!.isHidden = false
            let link = CADisplayLink(target: self, selector: #selector(followAnchor))
            // 对位置不用每帧：一秒十次够跟上页面滑动，画布静下来时也不至于一直叫醒主线程。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
            link.add(to: .main, forMode: .common)
            follow = link
        }

        private func dismiss() {
            follow?.invalidate()
            follow = nil
            // 等空间淡出（`TouchSpaceLayer` 的 0.35 秒）再收起这一层。
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
                self?.overlay?.isHidden = true
                self?.overlay = nil
            }
        }

        @objc private func followAnchor() {
            guard let overlay, let rect = screenRect, overlay.frame != rect else { return }
            overlay.frame = rect
        }
    }
}
#endif
