// 触感空间 · iOS 参考代码：记下每一笔。
// 一根手指从按下到抬起是一笔，期间记位置、时间、轻重。几根手指同时按着就是同时有几笔。
// 所有手指离开后，等一会儿（比如 2 秒）没人再摸，把这一批交给 TouchTranslator。

import UIKit

struct TouchSample {
    /// 在这个视图里的坐标（pt，左上原点）。
    let point: CGPoint
    /// 系统开机以来的秒数（UITouch.timestamp）。
    let time: TimeInterval
    /// 轻重 0…1。
    let pressure: CGFloat
}

struct TouchStroke {
    var samples: [TouchSample]
    var ended = false
    var endedAt: TimeInterval?
    /// 实时发送用：上一次发送时这根手指还按着，这一笔是接着那一下的。
    var continued = false

    var start: TimeInterval { samples.first!.time }
    var end: TimeInterval { endedAt ?? samples.last!.time }
}

/// 收多指触摸的视图。把它铺满屏幕（或者铺在聊天页上面），实现 `onBatch` 拿到一批触摸。
final class TouchSurfaceView: UIView {
    /// 所有手指离开、`pause` 秒内没再摸时调用，交出这一批。
    var onBatch: (([TouchStroke]) -> Void)?
    /// 每个采样都回调一次（给画面效果、震动用）。
    var onSample: ((ObjectIdentifier, TouchSample, _ phase: UITouch.Phase) -> Void)?
    var pause: TimeInterval = 2

    private var strokes: [TouchStroke] = []
    private var active: [ObjectIdentifier: Int] = [:]
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        timer?.invalidate()
        for touch in touches {
            let s = sample(touch)
            strokes.append(TouchStroke(samples: [s]))
            active[ObjectIdentifier(touch)] = strokes.count - 1
            onSample?(ObjectIdentifier(touch), s, .began)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = active[ObjectIdentifier(touch)] else { continue }
            // 合并触摸：120Hz 屏上一帧里攒下的中间点也要，轨迹才顺。
            for t in event?.coalescedTouches(for: touch) ?? [touch] {
                let s = sample(t)
                let last = strokes[index].samples.last!
                // 几乎没动、轻重也没变的点不记，省得一笔里攒几千个点。
                if hypot(s.point.x - last.point.x, s.point.y - last.point.y) < 1.5, abs(s.pressure - last.pressure) < 0.03 { continue }
                strokes[index].samples.append(s)
                onSample?(ObjectIdentifier(touch), s, .moved)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = active.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            strokes[index].ended = true
            strokes[index].endedAt = touch.timestamp
            onSample?(ObjectIdentifier(touch), sample(touch), .ended)
        }
        guard active.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            guard let self, !self.strokes.isEmpty else { return }
            let batch = self.strokes
            self.strokes = []
            self.onBatch?(batch)
        }
    }

    /// 轻重：现在的 iPhone 没有压感（3D Touch 的硬件已经拆了，force 恒为 0），
    /// 只能按手指贴在屏幕上的面积估：轻轻点大约半径 12–20pt，按实了能到 40pt 上下。
    /// Apple Pencil 有真压力。
    private func sample(_ touch: UITouch) -> TouchSample {
        let point = touch.preciseLocation(in: self)
        let hasForce = touch.maximumPossibleForce > 0
            && (touch.type == .pencil || traitCollection.forceTouchCapability == .available)
        let p: CGFloat
        if hasForce {
            p = min(1, touch.force / touch.maximumPossibleForce)
        } else {
            p = min(1, max(0, (touch.majorRadius - 12) / 32))
        }
        return TouchSample(point: point, time: touch.timestamp, pressure: p)
    }
}
