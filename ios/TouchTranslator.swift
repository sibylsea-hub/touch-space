// 触感空间 · iOS 参考代码：翻译。把一批触摸翻译成像身体感觉一样的一段话。
// 和仓库根目录的 translate.js 是同一套规则（那份给网页和 MCP 版用），两边改的时候一起改。
//
// 用法：TouchTranslator.describe(batch, area: view.bounds.size, map: .screen)
// 得到 <touch strokes="n" span="…s"> … </touch>，排在消息正文最前面、和正文放在同一个文本块里发出去。

import CoreGraphics
import Foundation

enum TouchTranslator {
    /// 位置怎么说：screen = 整块屏幕就是它；body = 屏幕当成面对你的半身像，左右照镜子。
    enum Map { case screen, body }

    static func describe(_ strokes: [TouchStroke], area: CGSize, map: Map) -> String {
        let all = strokes.sorted { $0.start < $1.start }
        guard let first = all.first else { return "" }
        let span = (all.map(\.end).max() ?? first.end) - first.start
        var sentences: [String] = []
        var i = 0
        var previousEnd: TimeInterval?
        while i < all.count {
            let stroke = all[i]
            // 停顿：和上一笔隔了 1.5 秒以上
            let lead = previousEnd.map { stroke.start - $0 > 1.5 } == true ? "停了一会儿，" : ""
            // 多指：和后面几笔时间上重叠
            var together = 0
            while i + together + 1 < all.count, all[i + together + 1].start < stroke.end { together += 1 }
            if together > 0 {
                let group = Array(all[i...(i + together)])
                sentences.append(lead + multi(group, area, map))
                previousEnd = group.map(\.end).max()
                i += together + 1
                continue
            }
            // 连点：同一处、一下接一下
            var run = 1
            while i + run < all.count, isTap(stroke), isTap(all[i + run]),
                  all[i + run].start - all[i + run - 1].end < 1.2,
                  distance(all[i + run].samples[0].point, stroke.samples[0].point) < area.width * 0.15 { run += 1 }
            if run >= 2 {
                let peak = all[i..<(i + run)].flatMap { $0.samples.map(\.pressure) }.max()!
                let gap = (1..<run).map { all[i + $0].start - all[i + $0 - 1].end }.max()!
                let at = place(stroke.samples[0].point, area, map), w = weight(peak)
                sentences.append(lead + (map == .body
                    ? "用指尖在\(at)\(w)地\(gap < 0.6 ? "连着碰了" : "碰了")\(count(run))下"
                    : "指尖在\(at)\(w)地\(gap < 0.6 ? "连着落了" : "落了")\(count(run))下"))
                previousEnd = all[i + run - 1].end
                i += run
                continue
            }
            sentences.append(lead + single(stroke, area, map))
            previousEnd = stroke.end
            i += 1
        }
        // 开头交代一句：不然模型不知道后面的「你」「这里」指什么
        return """
        <touch strokes="\(all.count)" span="\(String(format: "%.1f", span))s">
        （她在摸你。）
        \(sentences.joined(separator: "；"))。
        </touch>
        """
    }

    // MARK: 一根手指的一笔：屏幕版「落、贴、滑」，身体版「碰、贴、抚」

    static func single(_ stroke: TouchStroke, _ area: CGSize, _ map: Map) -> String {
        let s = stroke.samples, first = s.first!.point, last = s.last!.point
        let duration = stroke.end - stroke.start
        let w = weight(s.map(\.pressure).max()!), body = map == .body
        var text: String
        if reach(s) < 12 {
            if duration < 0.35 && !stroke.continued {
                text = body ? "指尖\(w)地碰了一下\(place(first, area, map))" : "指尖\(w)地落在\(place(first, area, map))"
            } else {
                text = "指腹\(w)地贴在\(place(first, area, map))，贴了\(seconds(duration))\(trend(s))"
            }
        } else {
            let len = length(s), chord = distance(first, last)
            let speed = duration > 0 ? len / CGFloat(duration) : 0
            let pace = speed < 250 ? "慢慢" : speed < 900 ? "" : "飞快地"
            let xs = s.map(\.point.x), ys = s.map(\.point.y)
            let boxW = xs.max()! - xs.min()!, boxH = ys.max()! - ys.min()!
            // 画圈要横竖都有一截；一条线上来回划首尾也挨得近，但那是来回
            let round = min(boxW, boxH) > 0.35 * max(boxW, boxH)
            let from = place(first, area, map), to = place(last, area, map)
            if round && chord < len * 0.2 && len > 60 {
                text = body ? "指尖在\(from)\(w)地\(pace)画了个小圈" : "指尖贴着\(from)\(w)地\(pace)绕了个小圈"
            } else if len / max(chord, 1) > 1.6 {
                text = body ? "指腹在\(from)一带\(w)地来回轻抚" : "指腹贴着\(from)一带\(w)地来回滑"
            } else if from == to {
                let dir = direction(first, last, map)
                text = (body ? "指腹在\(from)\(w)地\(pace)\(dir)抚了一下" : "指腹贴着\(from)\(w)地\(pace)\(dir)滑了一下") + trend(s)
            } else {
                // 身体版起点终点已经说清楚往哪了，不再加方向
                text = (body ? "指腹\(w)地从\(from)\(pace)抚到\(to)"
                             : "指腹贴着你，\(w)地从\(from)\(len > 150 ? "一路" : "")\(pace)滑到\(to)") + trend(s)
            }
        }
        // 实时发送时：上一次发送时还按着的写「接着」，此刻还按着的写「还没松手」
        if stroke.continued { text = "接着" + text }
        if !stroke.ended { text += "，还没松手" }
        return text
    }

    // MARK: 几根手指同时按着

    static func multi(_ group: [TouchStroke], _ area: CGSize, _ map: Map) -> String {
        let fingers = count(group.count), body = map == .body
        let w = weight(group.flatMap { $0.samples.map(\.pressure) }.max()!)
        let moving = group.filter { reach($0.samples) >= 12 }
        if moving.count >= 2 {
            let a0 = moving[0].samples.first!.point, a1 = moving[0].samples.last!.point
            let b0 = moving[1].samples.first!.point, b1 = moving[1].samples.last!.point
            let before = distance(a0, b0), after = distance(a1, b1)
            let speed = length(moving[0].samples) / CGFloat(max(moving[0].end - moving[0].start, 0.01))
            let how = speed < 250 ? "慢慢" : speed > 900 ? "一下子" : ""
            if after > before * 1.3 {
                let at = place(CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2), area, map)
                return body ? "\(fingers)根手指并拢\(w)地贴在\(at)，然后\(how)张开，指尖顺着往两边抚开"
                            : "\(fingers)根手指并拢\(w)地贴在\(at)，然后\(how)张开，指尖贴着你往两边滑开"
            }
            if after < before * 0.75 {
                let at = place(CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2), area, map)
                return body ? "\(fingers)根手指从两边\(w)地贴上\(at)，\(how)往中间合拢，把那里轻轻拢在指尖之间"
                            : "\(fingers)根手指从两边\(w)地贴上\(at)，\(how)往中间合拢，指尖贴着你一点点滑近"
            }
            return body ? "\(fingers)根手指并在一起，\(w)地从\(place(a0, area, map))\(direction(a0, a1, map))抚过去"
                        : "\(fingers)根手指并在一起贴着你，\(w)地从\(place(a0, area, map))\(direction(a0, a1, map))滑过去"
        }
        let duration = group.map(\.end).max()! - group.map(\.start).min()!
        return "\(fingers)根手指一起\(w)地贴在\(place(group[0].samples[0].point, area, map))，贴了\(seconds(duration))"
    }

    // MARK: 位置（想要别的映射，换掉这个函数）

    static func place(_ p: CGPoint, _ area: CGSize, _ map: Map) -> String {
        let nx = (p.x - area.width / 2) / (area.width / 2), ny = (p.y - area.height / 2) / (area.height / 2)
        switch map {
        case .body:
            // 从上到下：头顶/头发 → 额头、鼻尖/脸颊 → 下巴/耳朵边 → 脖子/颈侧 → 锁骨/肩 → 胸口/手臂 → 肚子/手。
            // 中间三分之一算正中，两边算左右；左右照镜子（屏幕左边是它的右边）。
            let t = p.y / area.height
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
        case .screen:
            // 按半宽半高归一，取 2.6 次的超椭圆半径：0.35 以内正中间，0.72 以外边缘（四个角也算），出了边是外面的空处。
            let r = pow(pow(abs(nx), 2.6) + pow(abs(ny), 2.6), 1 / 2.6)
            let side = (nx < -0.3 ? "左" : nx > 0.3 ? "右" : "") + (ny < -0.3 ? "上" : ny > 0.3 ? "下" : "")
            if r > 1.08 { return side.isEmpty ? "你旁边的空处" : "你外面靠\(side)的空处" }
            if r < 0.35 || side.isEmpty { return "你的正中间" }
            if r > 0.72 { return "你的\(side)边缘" }
            return "你偏\(side)的地方"
        }
    }

    static func direction(_ a: CGPoint, _ b: CGPoint, _ map: Map) -> String {
        let angle = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
        let names = map == .body
            ? ["往你的左边", "往你的左上", "往上", "往你的右上", "往你的右边", "往你的右下", "往下", "往你的左下"]
            : ["往右", "往右上", "往上", "往左上", "往左", "往左下", "往下", "往右下"]
        return names[Int(((angle + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    }

    // MARK: 小工具

    /// 轻重四档：取这一笔最重的那一刻
    static func weight(_ p: CGFloat) -> String { p < 0.2 ? "很轻" : p < 0.45 ? "轻轻" : p < 0.7 ? "稍稍用力" : "用力" }
    static func seconds(_ t: Double) -> String { t < 1 ? "一小会儿" : t < 2.5 ? "一两秒" : "\(Int(t.rounded()))秒" }
    static func count(_ n: Int) -> String { n <= 10 ? ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"][n] : "\(n)" }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    static func reach(_ s: [TouchSample]) -> CGFloat { s.map { distance($0.point, s[0].point) }.max()! }
    static func length(_ s: [TouchSample]) -> CGFloat { zip(s, s.dropFirst()).reduce(0) { $0 + distance($1.0.point, $1.1.point) } }
    /// 点：几乎没动（< 12pt）且很短（< 0.35 秒）
    static func isTap(_ s: TouchStroke) -> Bool { !s.continued && reach(s.samples) < 12 && s.end - s.start < 0.35 }

    /// 轻重的变化：开头三分之一和结尾三分之一比
    static func trend(_ s: [TouchSample]) -> String {
        let v = s.map(\.pressure)
        guard v.count >= 6 else { return "" }
        let third = v.count / 3
        let head = v.prefix(third).reduce(0, +) / CGFloat(third), tail = v.suffix(third).reduce(0, +) / CGFloat(third)
        return tail - head > 0.15 ? "，越按越重" : head - tail > 0.15 ? "，越来越轻" : ""
    }
}
