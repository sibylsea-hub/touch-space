// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 手感参数（调参面板的滑杆）。0…1 的旋钮。在真机上调好后点「复制当前参数」，
/// 把那串抄成新的出厂值（改下面的缺省值）。现在的出厂值是我们在真机上调出来的。
/// 两根：「触感强度」和「皮肤范围」。其余滤镜常数照网页草图，不开滑杆。
/// UserDefaults 里存着的 JSON 若多出别的键，解码时忽略，触感强度照旧读得回来。
struct TouchTuning: Codable, Equatable {
    /// 触感（震动）强度。
    var haptics = 0.53
    /// 皮肤效果的范围。0.5 = 基准（凹陷半径 34pt），0 = 一半，1 = 两倍；出厂 0.73 ≈ 1.38 倍（约 47pt）。
    var skinSize = 0.73

    /// 皮肤范围旋钮 → 倍数：2^((v − 0.5) × 2)，0.5…2。
    var skinSizeScale: Double { pow(2, (skinSize - 0.5) * 2) }

    /// 实时触摸的节奏：true = 边摸边发（每隔 `liveSeconds` 秒发一次，手指不用抬）；
    /// false = 停手后发（所有手指离开、`liveSeconds` 秒内没再摸才发）。
    /// 出厂是停手后发（边摸边每两秒发一包，读起来太零碎）。
    var liveWhileTouching = false
    /// 实时触摸的秒数：边摸边发时是间隔，停手后发时是停顿。0.3…3。
    var liveSeconds = 2.0
    static let liveSecondsRange: ClosedRange<Double> = 0.3...3

    /// 发给模型的描述里，位置用哪套说法：屏幕（你的正中间、你偏右上的地方）、上半身（你的额头、你的右肩）或下半身（你的小腹、你的左大腿）。
    var placeMap = TouchPlaceMap.screen

    static let factory = TouchTuning()

    init() {}

    /// 缺的键用出厂值（旧版本存的键少，合成的解码会整串报错、把调过的参数也丢掉）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        haptics = try c.decodeIfPresent(Double.self, forKey: .haptics) ?? Self.factory.haptics
        skinSize = try c.decodeIfPresent(Double.self, forKey: .skinSize) ?? Self.factory.skinSize
        liveWhileTouching = try c.decodeIfPresent(Bool.self, forKey: .liveWhileTouching) ?? Self.factory.liveWhileTouching
        liveSeconds = try c.decodeIfPresent(Double.self, forKey: .liveSeconds) ?? Self.factory.liveSeconds
        placeMap = (try? c.decodeIfPresent(TouchPlaceMap.self, forKey: .placeMap)) ?? Self.factory.placeMap
    }

    /// 面板上的顺序、名字与导出用的字段名（同 Codable 的键）。
    static let knobs: [(label: String, name: String, key: WritableKeyPath<TouchTuning, Double>)] = [
        ("触感强度", "haptics", \.haptics),
        ("皮肤范围", "skinSize", \.skinSize),
    ]
}

/// 参数存 UserDefaults（键 `touch.tuning`，JSON）。
@MainActor
final class TouchTuningStore: ObservableObject {
    static let defaultsKey = "touch.tuning"

    @Published var value: TouchTuning {
        didSet { save() }
    }

    init(report: (String) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            value = .factory
            return
        }
        do {
            value = try JSONDecoder().decode(TouchTuning.self, from: data)
        } catch {
            // 存的解不开 = 字段改过名。报告出来（附原文，好手抄回去），这次用出厂值。
            report("存着的手感参数解不开，这次用出厂值（\(error)）\n原文：\(String(decoding: data, as: UTF8.self))")
            value = .factory
        }
    }

    /// 「复制当前参数」复制的那一串（键排好序，两位小数）。
    var exportText: String {
        var fields = TouchTuning.knobs.map {
            "\"\($0.name)\": \(String(format: "%.2f", value[keyPath: $0.key]))"
        }
        fields.append("\"liveWhileTouching\": \(value.liveWhileTouching)")
        fields.append("\"liveSeconds\": \(String(format: "%.1f", value.liveSeconds))")
        fields.append("\"placeMap\": \"\(value.placeMap.rawValue)\"")
        return "touch.tuning {\(fields.joined(separator: ", "))}"
    }

    private func save() {
        // 只有 Double / Bool / 枚举字段的结构体，编码不会失败。
        UserDefaults.standard.set(try! JSONEncoder().encode(value), forKey: Self.defaultsKey)
    }
}

/// 藏着的调参面板（空间里三指长按 / Mac 上右键打开）。
struct TouchTuningPanel: View {
    @ObservedObject var tuning: TouchTuningStore
    @ObservedObject var space: TouchSpace
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手感参数").font(.headline)
                Spacer()
                Text(space.frameStats).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { space.panelOpen = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("收起面板")
            }
            ForEach(TouchTuning.knobs, id: \.name) { knob in
                HStack(spacing: 10) {
                    Text(knob.label).font(.callout).frame(width: 64, alignment: .leading)
                    Slider(value: $tuning.value[dynamicMember: knob.key], in: 0...1)
                    Text(String(format: "%.2f", tuning.value[keyPath: knob.key]))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Divider()
            // 发给模型的描述里，位置怎么说。
            HStack(spacing: 10) {
                Text("描述").font(.callout).frame(width: 64, alignment: .leading)
                Picker("位置的说法", selection: $tuning.value.placeMap) {
                    Text("屏幕").tag(TouchPlaceMap.screen)
                    Text("上半身").tag(TouchPlaceMap.body)
                    Text("下半身").tag(TouchPlaceMap.lower)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            // 实时触摸（胶囊里的「实时」开着时才用得上）。
            HStack(spacing: 10) {
                Text("实时").font(.callout).frame(width: 64, alignment: .leading)
                Picker("实时节奏", selection: $tuning.value.liveWhileTouching) {
                    Text("边摸边发").tag(true)
                    Text("停手后发").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 10) {
                Text(tuning.value.liveWhileTouching ? "每隔" : "停顿").font(.callout).frame(width: 64, alignment: .leading)
                Slider(value: $tuning.value.liveSeconds, in: TouchTuning.liveSecondsRange, step: 0.1)
                Text(String(format: "%.1f 秒", tuning.value.liveSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Button(copied ? "已复制" : "复制当前参数") {
                    #if os(iOS)
                    UIPasteboard.general.string = tuning.exportText
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuning.exportText, forType: .string)
                    #endif
                    copied = true
                }
                Spacer()
                Button("恢复出厂") { tuning.value = .factory }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(16)
        .onChange(of: tuning.value) { copied = false }
    }
}
