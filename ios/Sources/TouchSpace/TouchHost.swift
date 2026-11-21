// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftUI

/// 触感空间接进你自己的聊天前端，只需要这几样。
///
/// 1. 让你的聊天模型（或任何对象）遵守 `TouchChatHost`，创建一个 `TouchSpace(host:)`，自己留着它。
/// 2. 根视图加上 `.touchSpace(space)`：触感空间开着时盖住整块聊天页。
/// 3. 输入框旁边放 `TouchEntryButton(space: space)`：点它进入触感空间；攒着的触摸显示成「手 + 笔数」。
/// 4. 按发送时：`let touch = space.takeForSending()`，有的话排在正文前面、合成同一个文本块发出去。
///    `space.hasPending` 为真时，一个字不写也应该允许发送。
/// 5. 模型回复时调用 `space.replyDelta(新来的那段)`，结束时调用 `space.replyFinished(完整回复)`。
///    触感空间靠它重拍聊天页（回话出现在被摸的画面里），实时模式也靠它等模型说完再发。
/// 6. 聊天气泡里：`TouchPacket.split(用户消息)` 拆出触摸段，用 `TouchChip` 折成「手 + 笔数」，剩下的正文照常显示。
@MainActor
public protocol TouchChatHost: AnyObject {
    /// 模型是不是正在回复（实时模式下，回复期间的触摸先攒着）。
    var isReplying: Bool { get }
    /// 实时模式：立刻发出一条只带触摸的消息。`text` 是翻译好的 `<touch …>` 段。
    func sendTouchNow(_ text: String)
    /// 出错时报给你（截图失败、震动引擎起不来之类）。可以只打日志。
    func touchSpaceReport(_ source: String, _ message: String)
}

public extension TouchChatHost {
    func touchSpaceReport(_ source: String, _ message: String) {
        print("[touch-space] \(source)：\(message)")
    }
}

public extension View {
    /// 把触感空间挂到根视图上。iOS：根视图背后放一个锚点，触感空间画在单独一层窗口里；
    /// Mac：盖在根视图上的一层。
    func touchSpace(_ space: TouchSpace) -> some View {
        #if os(iOS)
        // 锚点铺到安全区外：窗口才会盖住状态栏那一条。
        background(TouchWindowAnchor(space: space).ignoresSafeArea())
        #else
        overlay { TouchSpaceLayer(space: space) }
        #endif
    }
}
