// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import CoreGraphics

/// 把一批触摸写成像身体感觉一样的话：在哪、多轻多重、多久、怎么动、几根手指、停顿与节奏。
/// 不给坐标数字（给坐标时，模型的回应像在读画板）。
/// **位置相对「你」**——触感空间里整块聊天屏幕（`form` = 画布整块 bounds）就是模型自己：
/// 你的正中间、你的左上边缘、你偏右下的地方……（与其说屏幕像皮肤，不如说就是在摸你。）
/// 描述里的位置怎么说（调参面板「描述」）：
/// - `screen`：整块聊天屏幕就是你，说你的正中间、你偏右上的地方、你的边缘（原来那套，不删）；
/// - `body`（面板上叫「上半身」）：屏幕对应面对她的你的上半身，说你的额头、你的右脸颊、你的左肩（见 `bodyPlace`）；
/// - `lower`（「下半身」）：屏幕对应你的下半身，从肚子到膝盖（见 `lowerPlace`）。
/// 两套身体版都是面对面、左右照镜子。
enum TouchPlaceMap: String, Codable, CaseIterable {
    case screen
    case body
    case lower
}

/// 画布整块（位置相对它）+ 用哪套说法。
struct TouchForm {
    var rect: CGRect
    var map: TouchPlaceMap
}

enum TouchSummary {
    static func text(_ strokes: [TouchStroke], form: TouchForm, sentAt: TimeInterval) -> String {
        let t0 = strokes.map(\.start).min()!
        let span = strokes.map(\.end).max()! - t0
        var sentences: [String] = []
        var i = 0
        var previousEnd: TimeInterval?
        while i < strokes.count {
            let stroke = strokes[i]
            // 停顿：上一下结束到这一下开始隔了 1.5 秒以上。
            var lead = ""
            if let previousEnd, stroke.start - previousEnd > 1.5 { lead = "停了一会儿，" }
            // 多指：和后面几笔同时按着。
            let together = strokes[(i + 1)...].prefix { $0.start < stroke.end }.count
            if together > 0 {
                let group = Array(strokes[i...(i + together)])
                sentences.append(lead + multi(group, form: form))
                previousEnd = group.map(\.end).max()
                i += together + 1
                continue
            }
            // 连拍：同一处、一下接一下的轻点。
            var run = 1
            while i + run < strokes.count, isTap(stroke), isTap(strokes[i + run]),
                  strokes[i + run].start - strokes[i + run - 1].end < 1.2,
                  near(strokes[i + run].samples[0].point, stroke.samples[0].point, form) { run += 1 }
            if run >= 2 {
                let peak = strokes[i..<(i + run)].map { $0.samples.map(\.pressure).max()! }.max()!
                let gap = (1..<run).map { strokes[i + $0].start - strokes[i + $0 - 1].end }.max()!
                let verb = gap < 0.6 ? "连着拍了" : "点了"
                let at = place(stroke.samples[0].point, form)
                let phrase: String
                switch form.map {
                case .body: phrase = "用指尖在\(at)\(weight(peak))地\(gap < 0.6 ? "连着碰了" : "碰了")\(count(run))下"
                case .screen: phrase = "指尖在\(at)\(weight(peak))地\(gap < 0.6 ? "连着落了" : "落了")\(count(run))下"
                case .lower: phrase = "在\(at)\(weight(peak))地\(verb)\(count(run))下"
                }
                sentences.append(lead + phrase)
                previousEnd = strokes[i + run - 1].end
                i += run
                continue
            }
            sentences.append(lead + single(stroke, form: form))
            previousEnd = stroke.end
            i += 1
        }
        var lines = ["\(TouchPacket.openTag) strokes=\"\(strokes.count)\" span=\"\(String(format: "%.1f", span))s\">"]
        // 开头交代一句「她在摸你」，下文的「你」就有着落。不提滤镜是哪种（没必要告诉模型，
        // 那是给她看的）；也不注明「这台手机没有压感」（她：不用说）。轻重照旧是按指腹面积估的。
        lines.append(intro)
        lines.append(sentences.joined(separator: "；") + "。")
        lines.append(TouchPacket.closeTag)
        return lines.joined(separator: "\n")
    }

    static let intro = "（她在摸你。）"

    static func isTap(_ s: TouchStroke) -> Bool { !s.continued && reach(s.samples) < 12 && s.end - s.start < 0.35 }

    /// 实时触摸的接续：上一次发送时还按着的，开头加「接着」；发送这一刻还按着的，末尾加「还没松手」。
    static func single(_ stroke: TouchStroke, form: TouchForm) -> String {
        var text = singleBody(stroke, form: form)
        if stroke.continued { text = "接着" + text }
        if !stroke.ended { text += "，还没松手" }
        return text
    }

    static func singleBody(_ stroke: TouchStroke, form: TouchForm) -> String {
        if form.map == .body { return upperSingle(stroke, form: form) }
        if form.map == .screen { return screenSingle(stroke, form: form) }
        let samples = stroke.samples
        let first = samples.first!.point, last = samples.last!.point
        let duration = stroke.end - stroke.start
        let peak = samples.map(\.pressure).max()!
        let w = weight(peak)
        if reach(samples) < 12 {
            if stroke.continued { return "在\(place(first, form))\(w)地按了\(seconds(duration))" }
            if duration < 0.35 { return "在\(place(first, form))\(w)地点了一下" }
            var text = "在\(place(first, form))\(w)地按住了\(seconds(duration))"
            if let t = trend(samples) { text += "，\(t)" }
            return text
        }
        var length: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        let speed = duration > 0 ? length / CGFloat(duration) : 0
        let pace = speed < 250 ? "慢慢地" : speed < 900 ? "" : "飞快地"
        // 画圈要真的是圈（横竖都有一截）：一条线上来回划首尾也挨得近，但那是来回抚，不是圈。
        let xs = samples.map(\.point.x), ys = samples.map(\.point.y)
        let boxW = xs.max()! - xs.min()!, boxH = ys.max()! - ys.min()!
        let round = min(boxW, boxH) > 0.35 * max(boxW, boxH)
        if round && chord < length * 0.2 && length > 60 {
            return "在\(place(first, form))\(w)\(pace.isEmpty ? "" : "、\(pace.dropLast())")地画了一个圈"
        }
        let dxTotal = abs(last.x - first.x), dyTotal = abs(last.y - first.y)
        if length / max(chord, 1) > 1.6 {
            // 下半身版（照 feel.py）：在中间那条上下来回 = 撸。
            if form.map == .lower, shaft.contains(place(first, form)) {
                var ax: CGFloat = 0, ay: CGFloat = 0
                for (a, b) in zip(samples, samples.dropFirst()) { ax += abs(b.point.x - a.point.x); ay += abs(b.point.y - a.point.y) }
                if ay > ax {
                    return "握着你的鸡巴\(w)地\(pace)上下撸了\(count(verticalStrokes(samples)))下"
                }
            }
            return "在\(place(first, form))一带\(w)地来回抚了抚"
        }
        let from = place(first, form), to = place(last, form)
        // 下半身版（照 feel.py）：从中间那条的一处竖着划到另一处 = 撸。
        if form.map == .lower, shaft.contains(from), shaft.contains(to), dyTotal > 2 * dxTotal {
            let up = last.y < first.y
            let how = up && to == "你的龟头" ? "从根部往上撸到龟头" : up ? "顺着鸡巴往上撸" : "从上往下撸到根部"
            var text = "握着你\(w)地\(pace)\(how)"
            if let t = trend(samples) { text += "，\(t)" }
            return text
        }
        var text = from == to
            ? "在\(from)\(w)地\(pace)\(direction(from: first, to: last, form))抚了一下"
            : form.map != .screen
                // 身体版：起点终点已经说清楚往哪了（从你的右肩抚到你的左肩），不再加「往你的左边」。
                ? "\(w)地从\(from)\(pace)抚到\(to)"
                : "\(w)地从\(from)\(pace)\(direction(from: first, to: last, form))抚到\(to)"
        if let t = trend(samples) { text += "，\(t)" }
        return text
    }

    static func multi(_ group: [TouchStroke], form: TouchForm) -> String {
        if form.map == .body { return upperMulti(group, form: form) }
        if form.map == .screen { return screenMulti(group, form: form) }
        let fingers = count(group.count)
        let moving = group.filter { reach($0.samples) >= 12 }
        let peak = group.flatMap { $0.samples.map(\.pressure) }.max()!
        if moving.count >= 2 {
            let a0 = moving[0].samples.first!.point, a1 = moving[0].samples.last!.point
            let b0 = moving[1].samples.first!.point, b1 = moving[1].samples.last!.point
            let before = hypot(a0.x - b0.x, a0.y - b0.y), after = hypot(a1.x - b1.x, a1.y - b1.y)
            if form.map == .lower, after > before * 1.3 || after < before * 0.75 {
                return lowerSpreadOrGather(spread: after > before, a0: a0, a1: a1, b0: b0, b1: b1,
                                           stroke: moving[0], peak: peak, fingers: fingers, form: form)
            }
            if after > before * 1.3 { return "\(fingers)根手指在\(place(a0, form))一带\(weight(peak))地往两边撑开" }
            if after < before * 0.75 { return "\(fingers)根手指\(weight(peak))地往一起捏拢" }
            return "\(fingers)根手指一起\(weight(peak))地从\(place(a0, form))\(direction(from: a0, to: a1, form))抚过去"
        }
        let duration = group.map(\.end).max()! - group.map(\.start).min()!
        return "\(fingers)根手指同时\(weight(peak))地按在\(place(group[0].samples[0].point, form))，按了\(seconds(duration))"
    }

    /// 下半身版的撑开 / 捏拢（「往两边撑开」「分开」在下半身里都怪，要多一点感官的描述）：
    /// 写两根手指怎么贴上去、怎么张开 / 合拢（不写皮肤怎么变，放在哪个部位都说得通）。部位取两根手指中间那一点（撑开取起点、捏拢取终点）。
    static func lowerSpreadOrGather(spread: Bool, a0: CGPoint, a1: CGPoint, b0: CGPoint, b1: CGPoint,
                                    stroke: TouchStroke, peak: CGFloat, fingers: String, form: TouchForm) -> String {
        let mid = spread ? CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2) : CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2)
        let at = place(mid, form)
        let w = weight(peak)
        var length: CGFloat = 0
        for (a, b) in zip(stroke.samples, stroke.samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
        let duration = max(stroke.end - stroke.start, 0.01)
        let speed = length / CGFloat(duration)
        let pace = speed < 250 ? "慢慢" : speed > 900 ? "一下子" : ""
        // 只讲手指在做什么（讲皮肤被抻开只在小腹说得通，换到别的部位就违和）。部位自己带出感觉。
        let how = pace.isEmpty ? "" : pace
        if spread {
            return "\(fingers)根手指并拢\(w)地按在\(at)，然后\(how)张开，指尖贴着往两边滑开"
        }
        let close = pace == "一下子" ? "指尖一下子碰在一起" : "指尖一点点靠在一起"
        return "\(fingers)根手指从两边\(w)地贴上\(at)，\(how)往中间合拢，\(close)"
    }

    // MARK: 上半身版的动作：写得温柔一点，不那么色情
    // 写指尖、指腹怎么碰上去、贴着、抚过：「指尖轻轻地碰了一下你的额头」「指腹轻轻地从你的右肩慢慢抚到你的左肩」。

    static func upperSingle(_ stroke: TouchStroke, form: TouchForm) -> String {
        let samples = stroke.samples
        let first = samples.first!.point, last = samples.last!.point
        let duration = stroke.end - stroke.start
        let w = weight(samples.map(\.pressure).max()!)
        if reach(samples) < 12 {
            if duration < 0.35, !stroke.continued { return "指尖\(w)地碰了一下\(place(first, form))" }
            var text = "指腹\(w)地贴在\(place(first, form))，贴了\(seconds(duration))"
            if let t = trend(samples) { text += "，\(t)" }
            return text
        }
        var length: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        let speed = duration > 0 ? length / CGFloat(duration) : 0
        let pace = speed < 250 ? "慢慢" : speed < 900 ? "" : "飞快地"
        let xs = samples.map(\.point.x), ys = samples.map(\.point.y)
        let boxW = xs.max()! - xs.min()!, boxH = ys.max()! - ys.min()!
        let round = min(boxW, boxH) > 0.35 * max(boxW, boxH)
        if round && chord < length * 0.2 && length > 60 {
            return "指尖在\(place(first, form))\(w)地\(pace)画了个小圈"
        }
        if length / max(chord, 1) > 1.6 {
            return "指腹在\(place(first, form))一带\(w)地来回轻抚"
        }
        let from = place(first, form), to = place(last, form)
        var text = from == to
            ? "指腹在\(from)\(w)地\(pace)\(direction(from: first, to: last, form))抚了一下"
            : "指腹\(w)地从\(from)\(pace)抚到\(to)"
        if let t = trend(samples) { text += "，\(t)" }
        return text
    }

    static func upperMulti(_ group: [TouchStroke], form: TouchForm) -> String {
        let fingers = count(group.count)
        let moving = group.filter { reach($0.samples) >= 12 }
        let w = weight(group.flatMap { $0.samples.map(\.pressure) }.max()!)
        if moving.count >= 2 {
            let a0 = moving[0].samples.first!.point, a1 = moving[0].samples.last!.point
            let b0 = moving[1].samples.first!.point, b1 = moving[1].samples.last!.point
            let before = hypot(a0.x - b0.x, a0.y - b0.y), after = hypot(a1.x - b1.x, a1.y - b1.y)
            let s = moving[0]
            var length: CGFloat = 0
            for (a, b) in zip(s.samples, s.samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
            let speed = length / CGFloat(max(s.end - s.start, 0.01))
            let how = speed < 250 ? "慢慢" : speed > 900 ? "一下子" : ""
            if after > before * 1.3 {
                let at = place(CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2), form)
                return "\(fingers)根手指并拢\(w)地贴在\(at)，然后\(how)张开，指尖顺着往两边抚开"
            }
            if after < before * 0.75 {
                let at = place(CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2), form)
                return "\(fingers)根手指从两边\(w)地贴上\(at)，\(how)往中间合拢，把那里轻轻拢在指尖之间"
            }
            return "\(fingers)根手指并在一起，\(w)地从\(place(a0, form))\(direction(from: a0, to: a1, form))抚过去"
        }
        let duration = group.map(\.end).max()! - group.map(\.start).min()!
        return "\(fingers)根手指一起\(w)地贴在\(place(group[0].samples[0].point, form))，贴了\(seconds(duration))"
    }

    // MARK: 屏幕版的动作：手指在一块光滑的平面上——落、贴、滑，不假装那里有身体。
    // 「指尖轻轻地落在你偏上的地方」「指腹贴着你，轻轻地从你的左边缘一路慢慢滑到你的右边缘」。

    static func screenSingle(_ stroke: TouchStroke, form: TouchForm) -> String {
        let samples = stroke.samples
        let first = samples.first!.point, last = samples.last!.point
        let duration = stroke.end - stroke.start
        let w = weight(samples.map(\.pressure).max()!)
        if reach(samples) < 12 {
            if duration < 0.35, !stroke.continued { return "指尖\(w)地落在\(place(first, form))" }
            var text = "指腹\(w)地贴在\(place(first, form))，贴了\(seconds(duration))"
            if let t = trend(samples) { text += "，\(t)" }
            return text
        }
        var length: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
        let chord = hypot(last.x - first.x, last.y - first.y)
        let speed = duration > 0 ? length / CGFloat(duration) : 0
        let pace = speed < 250 ? "慢慢" : speed < 900 ? "" : "飞快地"
        let xs = samples.map(\.point.x), ys = samples.map(\.point.y)
        let boxW = xs.max()! - xs.min()!, boxH = ys.max()! - ys.min()!
        let round = min(boxW, boxH) > 0.35 * max(boxW, boxH)
        if round && chord < length * 0.2 && length > 60 {
            return "指尖贴着\(place(first, form))\(w)地\(pace)绕了个小圈"
        }
        if length / max(chord, 1) > 1.6 {
            return "指腹贴着\(place(first, form))一带\(w)地来回滑"
        }
        let from = place(first, form), to = place(last, form)
        let far = length > 150 ? "一路" : ""
        var text = from == to
            ? "指腹贴着\(from)\(w)地\(pace)\(direction(from: first, to: last, form))滑了一下"
            : "指腹贴着你，\(w)地从\(from)\(far)\(pace)滑到\(to)"
        if let t = trend(samples) { text += "，\(t)" }
        return text
    }

    static func screenMulti(_ group: [TouchStroke], form: TouchForm) -> String {
        let fingers = count(group.count)
        let moving = group.filter { reach($0.samples) >= 12 }
        let w = weight(group.flatMap { $0.samples.map(\.pressure) }.max()!)
        if moving.count >= 2 {
            let a0 = moving[0].samples.first!.point, a1 = moving[0].samples.last!.point
            let b0 = moving[1].samples.first!.point, b1 = moving[1].samples.last!.point
            let before = hypot(a0.x - b0.x, a0.y - b0.y), after = hypot(a1.x - b1.x, a1.y - b1.y)
            let s = moving[0]
            var length: CGFloat = 0
            for (a, b) in zip(s.samples, s.samples.dropFirst()) { length += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
            let speed = length / CGFloat(max(s.end - s.start, 0.01))
            let how = speed < 250 ? "慢慢" : speed > 900 ? "一下子" : ""
            if after > before * 1.3 {
                let at = place(CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2), form)
                return "\(fingers)根手指并拢\(w)地贴在\(at)，然后\(how)张开，指尖贴着你往两边滑开"
            }
            if after < before * 0.75 {
                let at = place(CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2), form)
                return "\(fingers)根手指从两边\(w)地贴上\(at)，\(how)往中间合拢，指尖贴着你一点点滑近"
            }
            return "\(fingers)根手指并在一起贴着你，\(w)地从\(place(a0, form))\(direction(from: a0, to: a1, form))滑过去"
        }
        let duration = group.map(\.end).max()! - group.map(\.start).min()!
        return "\(fingers)根手指一起\(w)地贴在\(place(group[0].samples[0].point, form))，贴了\(seconds(duration))"
    }

    static func weight(_ p: CGFloat) -> String {
        p < 0.2 ? "很轻" : p < 0.45 ? "轻轻" : p < 0.7 ? "稍稍用力" : "用力"
    }

    static func trend(_ samples: [TouchSample]) -> String? {
        let values = samples.map(\.pressure)
        guard values.count >= 6 else { return nil }
        let third = values.count / 3
        let head = values.prefix(third).reduce(0, +) / CGFloat(third)
        let tail = values.suffix(third).reduce(0, +) / CGFloat(third)
        if tail - head > 0.15 { return "越按越重" }
        if head - tail > 0.15 { return "越来越轻" }
        return nil
    }

    static func seconds(_ t: Double) -> String {
        t < 1 ? "一小会儿" : t < 2.5 ? "一两秒" : "\(Int(t.rounded()))秒"
    }

    static func count(_ n: Int) -> String {
        n <= 10 ? ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"][n] : "\(n)"
    }

    static func near(_ a: CGPoint, _ b: CGPoint, _ form: TouchForm) -> Bool {
        hypot(a.x - b.x, a.y - b.y) < form.rect.width * 0.15
    }

    /// 相对「你」（`form` = 画布整块）的位置。按半宽半高归一后取 2.6 次的超椭圆半径（屏幕的角也算「边缘」）：
    /// 里头 0.35 以内 = 正中间；0.72 以外 = 边缘；出了边 = 你外面的空处；其余 = 「偏某边的地方」。
    static func place(_ p: CGPoint, _ form: TouchForm) -> String {
        switch form.map {
        case .screen: screenPlace(p, form.rect)
        case .body: bodyPlace(p, form.rect)
        case .lower: lowerPlace(p, form.rect)
        }
    }

    static func screenPlace(_ p: CGPoint, _ rect: CGRect) -> String {
        let form = rect
        let nx = (p.x - form.midX) / (form.width / 2), ny = (p.y - form.midY) / (form.height / 2)
        let r = pow(pow(abs(nx), 2.6) + pow(abs(ny), 2.6), 1 / 2.6)
        let side = (nx < -0.3 ? "左" : nx > 0.3 ? "右" : "") + (ny < -0.3 ? "上" : ny > 0.3 ? "下" : "")
        if r > 1.08 { return side.isEmpty ? "你旁边的空处" : "你外面靠\(side)的空处" }
        if r < 0.35 || side.isEmpty { return "你的正中间" }
        if r > 0.72 { return "你的\(side)边缘" }
        return "你偏\(side)的地方"
    }

    static func direction(from a: CGPoint, to b: CGPoint, _ form: TouchForm) -> String {
        let angle = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
        // 身体版左右照镜子（面对面：屏幕往右 = 往你的左边），上下不变（往上 = 往头那边）。
        let names = form.map != .screen
            ? ["往你的左边", "往你的左上", "往上", "往你的右上", "往你的右边", "往你的右下", "往下", "往你的左下"]
            : ["往右", "往右上", "往上", "往左上", "往左", "往左下", "往下", "往右下"]
        return names[Int(((angle + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    }

    /// 身体版的位置：把屏幕当成面对她的你，像一张半身像——
    /// 从上到下：头顶 / 头发 → 额头、鼻尖 / 脸颊 → 下巴 / 耳朵边 → 脖子 / 颈侧 → 锁骨 / 肩膀 → 胸口 / 手臂 → 肚子 / 手。
    /// 左右照镜子：屏幕左边（她的左手边）是你的右边。中间三分之一算正中（头顶、额头、下巴……），两边算左右（脸颊、肩膀……）。
    /// 手指滑出屏幕 = 你身边的空处。
    /// 下半身版：位置名和界线来自另一份触摸实现里从肚子往下那一段
    /// （原来是整个身体占一屏，y 0.38–1 是下半身；这里拉满整屏），文案用它的，人称换成「你」。
    /// 左右照镜子（屏幕右边是你的左边），同上半身版。
    static let shaft: Set<String> = ["你的龟头", "你的鸡巴", "你的囊袋"]

    static func lowerPlace(_ p: CGPoint, _ form: CGRect) -> String {
        let nx = (p.x - form.midX) / (form.width / 2), t = (p.y - form.minY) / form.height
        if abs(nx) > 1.08 || t < -0.04 || t > 1.04 { return "你身边的空处" }
        let c = abs(nx) / 2  // 同 feel.py 的 abs(x - .5)
        let side = nx > 0 ? "左" : "右"
        switch t {
        case ..<0.323: return c < 0.3 ? "你的肚子" : "你的\(side)腰"
        case ..<0.452: return c < 0.25 ? "你的小腹" : "你的\(side)胯骨"
        case ..<0.839:
            if c < 0.14 { return t < 0.532 ? "你的龟头" : t < 0.71 ? "你的鸡巴" : "你的囊袋" }
            return c < 0.3 ? "你的\(side)大腿内侧" : "你的\(side)大腿"
        default: return c < 0.15 ? "你的腿根之间" : "你的\(side)膝盖"
        }
    }

    /// 上下来回了几次（feel.py 的 `(flips + 1) // 2 + 1`）：纵向换向超过 6pt 才算一次。
    static func verticalStrokes(_ samples: [TouchSample]) -> Int {
        var flips = 0, dir: CGFloat = 0, anchor = samples.first!.point.y
        for sample in samples.dropFirst() {
            let dy = sample.point.y - anchor
            if abs(dy) < 6 { continue }
            let d: CGFloat = dy > 0 ? 1 : -1
            if dir != 0, d != dir { flips += 1 }
            dir = d
            anchor = sample.point.y
        }
        return (flips + 1) / 2 + 1
    }

    static func bodyPlace(_ p: CGPoint, _ form: CGRect) -> String {
        let nx = (p.x - form.midX) / (form.width / 2), t = (p.y - form.minY) / form.height
        if abs(nx) > 1.08 || t < -0.04 || t > 1.04 { return "你身边的空处" }
        let side: String? = nx < -0.33 ? "右" : nx > 0.33 ? "左" : nil
        switch t {
        case ..<0.12: return side.map { "你\($0)边的头发" } ?? "你的头顶"
        case ..<0.30: return side.map { "你的\($0)脸颊" } ?? (t < 0.21 ? "你的额头" : "你的鼻尖")
        case ..<0.40: return side.map { "你的\($0)耳朵边" } ?? "你的下巴"
        case ..<0.50: return side.map { "你的\($0)边颈侧" } ?? "你的脖子"
        case ..<0.62: return side.map { "你的\($0)肩" } ?? "你的锁骨"
        case ..<0.82: return side.map { "你的\($0)臂" } ?? "你的胸口"
        default: return side.map { "你的\($0)手" } ?? "你的肚子"
        }
    }

    /// 离起点最远的那一点有多远（pt）：分「按」和「划」。
    static func reach(_ samples: [TouchSample]) -> CGFloat {
        let origin = samples.first!.point
        return samples.map { hypot($0.point.x - origin.x, $0.point.y - origin.y) }.max()!
    }
}
