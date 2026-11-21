// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import CoreGraphics

/// 触感模块的记录账：一批还没发出去的触摸（笔），发送时整批换成一段感觉式描述。
///
/// - 触摸只来自触感空间里的那块表面。
/// - 位置相对「它」（触感空间里的整块聊天屏幕，`form` = 画布整块）。
/// - 什么时候发由宿主决定（按发送时调用 `TouchSpace.takeForSending()` 取走这一批）；这里只记账。

// MARK: - 数据

struct TouchSample {
    /// 表面视图里的坐标（点，左上原点）。
    let point: CGPoint
    /// 系统开机以来的秒数（`UITouch.timestamp` / `NSEvent.timestamp` 同一时基）。
    let time: TimeInterval
    /// 0…1，怎么来的见 `TouchPressureSource`。
    let pressure: CGFloat
    /// 原始读数：接触半径（pt）/ 力 / 触控板压力。
    let raw: CGFloat
}

struct TouchStroke: Identifiable {
    let id = UUID()
    var samples: [TouchSample]
    var ended = false
    var endedAt: TimeInterval?
    /// 实时触摸：上一次发送时这根手指还按着，这一笔是接着那一下的（描述写「接着……」，不当成新的一点）。
    var continued = false

    var start: TimeInterval { samples.first!.time }
    var end: TimeInterval { endedAt ?? samples.last!.time }
}

enum TouchPressureSource: Equatable {
    /// 3D Touch / Apple Pencil 的力。
    case force
    /// 没有压感硬件：按接触半径估。
    case contactArea
    /// Mac 的鼠标 / Force Touch 触控板。
    case trackpad
}

/// 一次带走的触摸：一段描述，已包好 `<touch>` 标签（气泡的消息装饰靠标签把它收成一只手）。
public struct TouchPacket {
    let text: String

    static let openTag = "<touch"
    static let closeTag = "</touch>"

    /// 把一条用户消息拆成「触摸描述」与正文。没有触摸段时 `touch` 为 nil、正文原样。
    public static func split(_ text: String) -> (touch: String?, strokes: Int, rest: String) {
        guard text.hasPrefix(openTag), let close = text.range(of: closeTag) else { return (nil, 0, text) }
        let block = String(text[..<close.upperBound])
        let rest = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var strokes = 0
        if let attr = block.range(of: "strokes=\""),
           let quote = block[attr.upperBound...].firstIndex(of: "\""),
           let parsed = Int(block[attr.upperBound..<quote]) {
            strokes = parsed
        }
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
        return (body, strokes, rest)
    }
}

// MARK: - 账

@MainActor
final class TouchStore: ObservableObject {
    /// 上次发送以来记下的笔数。
    @Published private(set) var pendingCount = 0

    /// 「你」= 画布整块（描述里的位置相对它）。画布尺寸变了时由空间填。
    var form: CGRect = .zero
    /// 位置用哪套说法（屏幕 / 身体，调参面板里选）。由空间按手感参数填。
    var placeMap: TouchPlaceMap = .screen

    private var strokes: [TouchStroke] = []
    /// 正在进行的触摸 → `strokes` 里的下标。
    private var active: [AnyHashable: Int] = [:]

    var hasPending: Bool { pendingCount > 0 }
    /// 还有手指按着。
    var isTouching: Bool { !active.isEmpty }

    private static let sampleCap = 600
    private static let strokeCap = 200

    func began(_ key: AnyHashable, _ sample: TouchSample, source _: TouchPressureSource) {
        strokes.append(TouchStroke(samples: [sample]))
        if strokes.count > Self.strokeCap {
            let drop = strokes.count - Self.strokeCap
            strokes.removeFirst(drop)
            active = active.compactMapValues { $0 >= drop ? $0 - drop : nil }
        }
        active[key] = strokes.count - 1
        pendingCount = strokes.count
    }

    func moved(_ key: AnyHashable, _ samples: [TouchSample]) {
        guard let index = active[key] else { return }
        defer { pendingCount = strokes.count }
        for sample in samples {
            let last = strokes[index].samples.last!
            if hypot(sample.point.x - last.point.x, sample.point.y - last.point.y) < 1.5,
               abs(sample.pressure - last.pressure) < 0.03 { continue }
            if strokes[index].samples.count < Self.sampleCap { strokes[index].samples.append(sample) }
        }
    }

    func ended(_ key: AnyHashable, at time: TimeInterval) {
        guard let index = active.removeValue(forKey: key) else { return }
        strokes[index].ended = true
        strokes[index].endedAt = time
        pendingCount = strokes.count
    }

    /// 清掉这一批（长按胶囊）。
    func discard() {
        strokes = []
        active = [:]
        pendingCount = 0
    }

    /// 把此刻按着的那几笔从账上抹掉（三指长按打开调参面板时：那三根手指不是在摸「它」）。
    func dropActive() {
        let gone = Set(active.values)
        strokes = strokes.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        active = [:]
        pendingCount = strokes.count
    }

    /// 发送时调：把这一批整个带走。还按着的那几笔截到此刻带走（描述里写「还没松手」），
    /// 账上从最后一个采样接着记（实时触摸「边摸边发」时手指不用抬起来）。没有就返回 nil。
    func takePacket() -> TouchPacket? {
        guard !strokes.isEmpty else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var batch = strokes
        let holding = active
        // 还按着的那几笔截到此刻：一直按着不动时没有新采样，不截的话时长会算成 0。
        for index in holding.values { batch[index].endedAt = now }
        strokes = []
        active = [:]
        for (key, index) in holding {
            // 从截断这一刻接着记（同一个位置和轻重，时间换成此刻）：时长从这次发送算起。
            let last = batch[index].samples.last!
            var next = TouchStroke(samples: [TouchSample(point: last.point, time: now, pressure: last.pressure, raw: last.raw)])
            next.continued = true
            strokes.append(next)
            active[key] = strokes.count - 1
        }
        // 接着记的那几笔也算待发：一直按着不动也会在下一次发送时写成「接着按了……，还没松手」。
        // 普通用法（摸完放进输入框）发送时手指早就抬起来了，这里是 0。
        pendingCount = strokes.count
        return TouchPacket(text: TouchSummary.text(batch, form: TouchForm(rect: form, map: placeMap), sentAt: now))
    }
}
