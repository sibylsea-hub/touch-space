// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
#if os(iOS)
import CoreHaptics
#else
import AppKit
#endif

/// 触感空间的震动。
/// - iOS：Core Haptics。按下一下 transient，强度和算出来的轻重成正比；抚的时候一条循环的 continuous，
///   强度跟着此刻的轻重走（和力度成比例），速度只管锐度（越快越脆）和一点点力度；摸好点 ✓ 放进输入框时一下；离手一下轻弹。模拟器与不支持的机型上 `supportsHaptics` 为假，全部不响。
/// - Mac：没有 Core Haptics，用 `NSHapticFeedbackManager` 尽量对应（只有 Force Touch 触控板上有感觉）。
/// 强度都乘调参面板的「触感强度」（0.5 = 基准，1 = 两倍，封顶 1；出厂 0.53）。
@MainActor
final class TouchHaptics {
    private let strength: () -> Double
    private let report: (String) -> Void

    init(strength: @escaping () -> Double, report: @escaping (String) -> Void) {
        self.strength = strength
        self.report = report
    }

    private func scaled(_ intensity: Double) -> Float {
        Float(min(1, intensity * strength() * 2))
    }

    #if os(iOS)
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var stroke: CHHapticAdvancedPatternPlayer?

    /// 进空间时备好引擎（第一下轻点不必等它启动）。
    func prepare() {
        guard supported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // 被系统停掉 / 重置（来电、退到后台）：丢掉，下一次用时重建。
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil; self?.stroke = nil }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine = nil; self?.stroke = nil }
            }
            try engine.start()
            self.engine = engine
        } catch {
            report("Core Haptics 引擎起不来：\(error)")
        }
    }

    /// 按下：强度和轻重成正比（很轻也留一点底，不至于完全没感觉）。
    func tap(_ pressure: CGFloat) { transient(intensity: 0.12 + 0.8 * Double(pressure), sharpness: 0.35) }
    func release(_ holdGain: Float) { transient(intensity: 0.22 + 0.25 * Double(holdGain), sharpness: 0.6) }
    func placed() { transient(intensity: 0.5, sharpness: 0.2) }
    /// 实时触摸发出去一批。
    func sent() { transient(intensity: 0.3, sharpness: 0.5) }

    /// 抚：此刻的轻重 → 强度（成正比），速度（pt/s）→ 锐度和一点力度。第一次调时起一条循环的 continuous。
    func stroke(speed: Float, pressure: CGFloat) {
        prepare()
        guard let engine else { return }
        do {
            if stroke == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ], relativeTime: 0, duration: 10)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                try player.start(atTime: CHHapticTimeImmediate)
                stroke = player
            }
            let v = min(Double(speed) / 1500, 1)
            let p = min(max(Double(pressure), 0), 1)
            try stroke!.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                         value: scaled((0.05 + 0.6 * p) * (0.7 + 0.3 * v)), relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(-0.2 + 0.6 * v), relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            report("抚的触感放不出来：\(error)")
        }
    }

    /// 所有手指都离开了：停掉抚的那一条。
    func strokeEnded() {
        guard let stroke else { return }
        self.stroke = nil
        do {
            try stroke.stop(atTime: CHHapticTimeImmediate)
        } catch {
            report("抚的触感停不下来：\(error)")
        }
    }

    private func transient(intensity: Double, sharpness: Float) {
        prepare()
        guard let engine else { return }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: scaled(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            report("触感放不出来：\(error)")
        }
    }
    #else
    private var travelled: Float = 0

    func prepare() {}
    func tap(_ pressure: CGFloat) { perform(.generic) }
    func release(_ holdGain: Float) { perform(.alignment) }
    func placed() { perform(.levelChange) }
    func sent() { perform(.alignment) }

    /// 触控板没有连续震动、也调不了力度：每抚过约 60pt 轻敲一下。
    func stroke(speed: Float, pressure: CGFloat) {
        travelled += speed / 120
        if travelled > 60 {
            travelled = 0
            perform(.alignment)
        }
    }

    func strokeEnded() { travelled = 0 }

    private func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard strength() > 0.05 else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    #endif
}
