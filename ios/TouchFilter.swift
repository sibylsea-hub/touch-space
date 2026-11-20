// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// 触感空间 · iOS 参考代码：画面效果的「物理」和截图。
// TouchSnapshot：进触感空间时把聊天页拍成一张图（之后在着色器里扭它）。
// TouchFilter：水纹的滴、皮肤的手指槽，每帧推一次，打包成着色器的统一参数（布局见 TouchFilter.metal 开头）。
// 渲染器没有放进来：一个 MTKView、一个全屏三角形、一张纹理，静下来（isBusy == false）就 isPaused = true。

import Foundation
import QuartzCore
import CoreGraphics
import simd
import UIKit

enum TouchLook: String, CaseIterable, Identifiable {
    /// 水纹（缺省）：手指下起一两道圈，往外走、变宽、变淡。
    case ripple
    /// 皮肤：按下去陷、被手指黏着拖、松手晃两下弹回、按久了转暖。
    case skin

    static let defaultsKey = "touch.look"
    static let standard = TouchLook.ripple

    var id: String { rawValue }

    /// 着色器里的模式号（与 `touch_filter_fragment` 的分支一致）。
    var shaderMode: Float {
        switch self {
        case .ripple: 0
        case .skin: 1
        }
    }

    var symbol: String {
        switch self {
        case .ripple: "water.waves"
        case .skin: "hand.tap"
        }
    }

    var label: String {
        switch self {
        case .ripple: "水纹"
        case .skin: "皮肤"
        }
    }
}

/// 进空间前给窗口截的那张图，连同它在「截图坐标」下的尺寸（pt）。
/// 截的是聊天那一层窗口，坐标 = 窗口坐标（左上原点）。
struct TouchSnapshot {
    let id = UUID()
    /// sRGB、BGRA 8 位（着色器原样取色写进 `bgra8Unorm` 画布 = 和截图前看到的一样）。
    let image: CGImage
    let size: CGSize

    enum Failure: Error, CustomStringConvertible {
        case noKeyWindow
        case incomplete
        case convert

        var description: String {
            switch self {
            case .noKeyWindow: "找不到 key window"
            case .incomplete: "drawHierarchy 报告没画完整（窗口还没上屏？）"
            case .convert: "建不出 sRGB 位图"
            }
        }
    }

    @MainActor
    static func capture(in host: AnyObject? = nil) throws -> TouchSnapshot {
        // 拍聊天那一层（传进来的 host 窗口）；没有就拍 key window。触感空间自己最好在另一层窗口里，才不会被拍进去。
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = (host as? UIWindow) ?? windows.first(where: \.isKeyWindow) else { throw Failure.noKeyWindow }
        let format = UIGraphicsImageRendererFormat()
        // 最多 2 倍：画布也按 2 倍画（3 倍屏上片元少一半多，是省电的主要一刀）。
        format.scale = min(window.screen.scale, 2)
        // 标准范围 = 8 位 sRGB。缺省的 .automatic 在广色域屏上给 16 位扩展范围，进 8 位纹理会偏色。
        format.preferredRange = .standard
        format.opaque = true
        var complete = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard complete else { throw Failure.incomplete }
        return TouchSnapshot(image: try srgb(image.cgImage!), size: window.bounds.size)
    }

    /// 画进一张 sRGB 的 BGRA 位图（统一成着色器原样取色的格式）。
    private static func srgb(_ image: CGImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { throw Failure.convert }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = context.makeImage() else { throw Failure.convert }
        return out
    }
}

/// 画面的手指物理。坐标一律是画布里的点（pt，左上原点，y 向下；Metal 的片元坐标也是左上原点，不用翻）。
///
/// - 水纹：按下落一滴（强度 1），划动每 22pt 落一滴，强度 0.35 + min(速度 / 2200, 0.5)；最多 40 滴，1.6 秒散完。
/// - 皮肤：最多 5 个手指槽，固定子步 1/240 秒推弹簧。
@MainActor
final class TouchFilter {
    static let maxDrops = 40
    static let maxFingers = 5
    static let dropLife: Double = 1.6
    /// 统一参数（一串 float4）的布局，与 `.metal` 里 `kFilter*` 一起改：
    ///   u[0] = 画布像素宽高、时间（秒）、模式
    ///   u[1] = 渲染缩放（像素 / pt）、幅度（减弱动态效果时 0.5）、皮肤范围倍数、0
    ///   u[2] = 画布在截图里的 UV 子矩形：原点 xy、尺寸 zw
    ///   u[3] = 暖色 rgb、0；u[4] = 空着
    ///   u[5 + i]  = 第 i 滴水：x、y（像素）、起始时刻、强度
    ///   u[45 + i] = 第 i 根手指：x、y（像素）、深度 / 吸力、暖
    ///   u[50 + i] = 第 i 根手指（皮肤）被拖着走的位移 x、y（像素）、0、0
    static let dropBase = 5
    static let fingerBase = dropBase + maxDrops
    static let offsetBase = fingerBase + maxFingers
    static let uniformCount = offsetBase + maxFingers

    private struct Drop {
        var x: Double, y: Double, t: Double, amp: Double
    }

    private struct Pointer {
        var x: Double, y: Double
        /// 上一个采样（算速度）。
        var lx: Double, ly: Double, lt: Double
        /// 上一滴落下的位置（水纹：每 22pt 一滴）。
        var ex: Double, ey: Double
        var slot: Int?
        let downAt: Double
        /// 平滑过的速度（pt/s），给抚的震动用（同原来表面的 0.6 / 0.4 平滑）。
        var hapticSpeed: Double = 0
    }

    private struct Slot {
        var key: AnyHashable
        var active = true
        var downAt: Double
        var fx: Double, fy: Double
        var cx: Double, cy: Double
        var gx: Double, gy: Double, gvx = 0.0, gvy = 0.0
        var ox = 0.0, oy = 0.0, ovx = 0.0, ovy = 0.0
        var depth: Double, dv: Double
        var hold = 0.0
        var warm: Double

        var settled: Bool {
            abs(depth) < 0.002 && abs(dv) < 0.01 && hypot(ox, oy) < 0.05 && hypot(ovx, ovy) < 0.1 && warm < 0.01
        }
    }

    private(set) var look: TouchLook
    /// 皮肤范围倍数（调参面板「皮肤范围」，1 = 出厂）。凹陷半径和被拖的位移上限都乘它。
    var skinSize = 1.0
    private var drops: [Drop] = []
    private var dropHead = 0
    private var pointers: [AnyHashable: Pointer] = [:]
    private var slots: [Slot] = []
    private let epoch = CACurrentMediaTime()

    init(look: TouchLook) {
        self.look = look
    }

    private var now: Double { CACurrentMediaTime() - epoch }

    func reset(_ look: TouchLook) {
        self.look = look
        drops = []
        dropHead = 0
        pointers = [:]
        slots = []
    }

    /// 有手指按着，或者还有没散完的水滴 / 没回稳的手指槽。
    var isBusy: Bool {
        if !pointers.isEmpty { return true }
        switch look {
        case .ripple:
            let t = now
            return drops.contains { t - $0.t < Self.dropLife }
        case .skin:
            return slots.contains { $0.active || !$0.settled }
        }
    }

    /// 静下来那一刻：散完的水滴、回稳的空槽都拿掉，最后一帧就是原原本本的截图（不留零点几像素的残影）。
    func settle() {
        let t = now
        drops = drops.filter { t - $0.t < Self.dropLife }
        dropHead = 0
        slots = slots.filter { $0.active || !$0.settled }
    }

    // MARK: 手指

    func press(_ key: AnyHashable, at point: CGPoint, time: TimeInterval) {
        let x = Double(point.x), y = Double(point.y)
        var p = Pointer(x: x, y: y, lx: x, ly: y, lt: time, ex: x, ey: y, slot: nil, downAt: now)
        if look == .ripple {
            emitDrop(x, y, 1)
        } else {
            p.slot = newSlot(key, x, y)
        }
        pointers[key] = p
    }

    /// 返回这根手指平滑过的速度（pt/s），给抚的震动用。
    @discardableResult
    func drag(_ key: AnyHashable, to point: CGPoint, time: TimeInterval) -> Float {
        guard var p = pointers[key] else { return 0 }
        let x = Double(point.x), y = Double(point.y)
        let dt = max(time - p.lt, 1.0 / 240)
        let sp = hypot(x - p.lx, y - p.ly) / dt
        p.x = x; p.y = y; p.lx = x; p.ly = y; p.lt = time
        p.hapticSpeed = p.hapticSpeed * 0.6 + sp * 0.4
        if look == .ripple {
            // 划的时候每 22pt 落一滴，划得越快越大。
            if hypot(x - p.ex, y - p.ey) > 22 {
                emitDrop(x, y, 0.35 + min(sp / 2200, 0.5))
                p.ex = x; p.ey = y
            }
        } else if let i = p.slot, slots[i].key == key {
            slots[i].fx = x
            slots[i].fy = y
        }
        pointers[key] = p
        return Float(p.hapticSpeed)
    }

    /// 返回离手那一刻的「长按增益」（0.35 秒起算、2.6 秒爬满，同原来表面的离手触感），给离手的震动用。
    @discardableResult
    func release(_ key: AnyHashable) -> Float {
        guard let p = pointers.removeValue(forKey: key) else { return 0 }
        if let i = p.slot, slots[i].key == key { slots[i].active = false }
        let t = min(max((now - p.downAt - 0.35) / 2.6, 0), 1)
        return Float(1 - pow(1 - t, 3))
    }

    func releaseAll() {
        for key in Array(pointers.keys) { release(key) }
    }

    private func emitDrop(_ x: Double, _ y: Double, _ amp: Double) {
        let d = Drop(x: x, y: y, t: now, amp: amp)
        if drops.count < Self.maxDrops {
            drops.append(d)
        } else {
            drops[dropHead] = d
            dropHead = (dropHead + 1) % Self.maxDrops
        }
    }

    private func newSlot(_ key: AnyHashable, _ x: Double, _ y: Double) -> Int {
        let index: Int
        if let free = slots.firstIndex(where: { !$0.active && $0.settled }) {
            index = free
        } else if slots.count < Self.maxFingers {
            slots.append(Slot(key: key, downAt: now, fx: x, fy: y, cx: x, cy: y, gx: x, gy: y, depth: 0, dv: 0, warm: 0))
            return slots.count - 1
        } else {
            index = slots.indices.min { slots[$0].downAt < slots[$1].downAt }!
        }
        let old = slots[index]
        slots[index] = Slot(key: key, downAt: now, fx: x, fy: y, cx: x, cy: y, gx: x, gy: y,
                            depth: old.depth, dv: old.dv, warm: old.warm)
        return index
    }

    // MARK: 推进

    func advance(dt: Double) {
        guard look != .ripple, !slots.isEmpty else { return }
        let dt = min(dt, 1.0 / 20)
        let steps = max(1, Int((dt * 240).rounded()))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            for i in slots.indices { step(&slots[i], h) }
        }
    }

    private func step(_ s: inout Slot, _ h: Double) {
        if s.active { s.hold += h }
        let hr = ramp(s.hold, 0.35, 2.6)
        switch look {
        case .skin:
            if s.active {
                s.cx = s.fx; s.cy = s.fy
                // 皮肤贴着手指：抓住的那一点追上手指，中间被拉开的就是皮肤被拖着走的量。
                let k = 40.0, c = 2 * sqrt(k)
                s.gvx += (k * (s.fx - s.gx) - c * s.gvx) * h
                s.gvy += (k * (s.fy - s.gy) - c * s.gvy) * h
                s.gx += s.gvx * h; s.gy += s.gvy * h
                let dx = s.fx - s.gx, dy = s.fy - s.gy, l = hypot(dx, dy), m = 24.0 * skinSize
                let f = l > 0 ? m * tanh(l / m) / l : 0
                s.ox = dx * f; s.oy = dy * f; s.ovx = 0; s.ovy = 0
                s.warm += (hr - s.warm) * min(1, h * 1.5)
            } else {
                // 松手：欠阻尼弹回去，晃两下。
                let k = 110.0, c = 7.0
                s.ovx += (-k * s.ox - c * s.ovx) * h; s.ovy += (-k * s.oy - c * s.ovy) * h
                s.ox += s.ovx * h; s.oy += s.ovy * h
                s.warm -= s.warm * min(1, h * 0.45)
            }
            let target = s.active ? 0.55 + 0.45 * hr : 0
            s.dv += (220 * (target - s.depth) - 15 * s.dv) * h
            s.depth += s.dv * h
        case .ripple:
            break
        }
    }

    private func ramp(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: 统一参数

    /// - Parameters:
    ///   - uvRect: 画布在截图里的 UV 子矩形（0…1）。
    func uniforms(pixels: CGSize, scale: Double, uvRect: CGRect, dark: Bool, amp: Float) -> [SIMD4<Float>] {
        var u = [SIMD4<Float>](repeating: .zero, count: Self.uniformCount)
        let k = Float(scale)
        u[0] = SIMD4(Float(pixels.width), Float(pixels.height), Float(now), look.shaderMode)
        u[1] = SIMD4(k, amp, Float(skinSize), 0)
        u[2] = SIMD4(Float(uvRect.minX), Float(uvRect.minY), Float(uvRect.width), Float(uvRect.height))
        // 亮色 --warm #e9a58f；暗色 #b8604e。
        u[3] = dark ? Self.rgb(0xb8604e) : Self.rgb(0xe9a58f)
        for (i, d) in drops.enumerated() {
            u[Self.dropBase + i] = SIMD4(Float(d.x) * k, Float(d.y) * k, Float(d.t), Float(d.amp))
        }
        for (i, s) in slots.enumerated() {
            u[Self.fingerBase + i] = SIMD4(Float(s.cx) * k, Float(s.cy) * k, Float(s.depth), Float(s.warm))
            u[Self.offsetBase + i] = SIMD4(Float(s.ox) * k, Float(s.oy) * k, 0, 0)
        }
        return u
    }

    private static func rgb(_ hex: Int) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xff) / 255, Float((hex >> 8) & 0xff) / 255, Float(hex & 0xff) / 255, 0)
    }
}
