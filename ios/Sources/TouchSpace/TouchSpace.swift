// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftUI
import Combine
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 触感空间：点输入区那只手进入的全屏空间。空间里就是整块聊天页本身——进空间前截一张图铺满，
/// 在手指下按两种「看法」之一变形（水纹 / 皮肤，`TouchLook`），不变暗。
///
/// 交互规则：摸完放进输入框，她还能打字：
/// - 在空间里 = 开着。顶上一枚胶囊：一只手（有没放进去的触摸时是实心）+ 两个效果图标 + ✓ / ✕。
/// - 摸完点 ✓：回到聊天，这一批留在输入框里（输入区那只手旁边一枚「手 + 笔数」的小标签），
///   跟她打的字一起、按发送时发出（宿主调用 `takeForSending()`）；一个字不写也能发。没摸过时那个钮是 ✕，只是回去。
/// - 小标签上的 × 或长按胶囊 →「清掉这一批」；点小标签回到空间接着摸，笔数接着加。
/// - 新建页一样能进；在新建页按发送就用这一批开新会话（与「第一句话」同一条路径）。
/// - 模型的回复：iOS 直接出现在聊天记录里（空间在单独一层窗口，回话一到就重拍聊天页，见 `TouchWindow.swift`）；
///   Mac 照旧以很淡的文字浮在空间里几秒。
/// - **实时**（胶囊里的「实时」开关，存 UserDefaults `touch.live`）：不用点 ✓，摸着摸着就自动发，
///   回话浮在空间里，她不用离开接着摸。节奏在调参面板里选：边摸边发（每隔 N 秒发一次，还按着的那一笔截到此刻、
///   下一次写「接着……」）或停手后发（停 N 秒才发）。模型还在说话时新的触摸先攒着，它说完再一起发，不打断、
///   不排一串。开着实时点 ✕ 回去：没发的立刻发。手底下的震动、画面照旧即时。
@MainActor
public final class TouchSpace: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var panelOpen = false
    /// 空间里浮出来的回复（流式累加，落账后换成完整的那条）。
    @Published private(set) var reply = ""
    @Published private(set) var replyVisible = false
    /// 调参面板角上的帧率（渲染每秒结一次；停帧时写「静止 · 0 fps」）。
    @Published var frameStats = ""
    /// 当前的效果（存 UserDefaults `touch.look`，下次进空间沿用）。
    @Published private(set) var look: TouchLook
    /// 实时触摸开着（存 UserDefaults `touch.live`）。
    @Published private(set) var live = UserDefaults.standard.bool(forKey: TouchSpace.liveKey)
    /// 实时：胶囊上那一圈正在画（从 `since` 起 `duration` 秒画满 = 发）；`waiting` = 攒好了，等模型说完。
    @Published private(set) var liveRing: (since: Date, duration: Double)?
    @Published private(set) var liveWaiting = false

    /// 你的聊天前端（见 `TouchHost.swift`）。实时模式靠它发消息、问模型是不是还在回复。
    public weak var host: (any TouchChatHost)?
    let store = TouchStore()
    let tuning: TouchTuningStore
    let filter: TouchFilter
    /// 进空间前截的聊天页（关空间时丢掉；空间开着期间不重截）。截失败时为 nil：空间照样能进、能摸、能发，只是不变形。
    private(set) var snapshot: TouchSnapshot?
    /// 画布（pt）。触摸描述里的位置相对它（`store.form` = 画布整块）。
    private(set) var canvasSize: CGSize = .zero
    /// 画布的渲染器：有新手指 / 换效果时叫醒它（静下来时它停帧）。
    weak var renderer: TouchRenderer?
    #if os(iOS)
    /// 聊天那一层窗口（锚点所在的窗口，`TouchWindowAnchor` 填）。截图拍它，画布位置也换算到它。
    weak var hostWindow: UIWindow?
    #endif
    private var refreshTask: Task<Void, Never>?
    /// 试摸：点 ✓ 回去时这一批直接清掉、不放进输入框。
    /// 只为录屏 / 调材质时不往会话里灌消息；正常使用不设。
    var dryRun = false
    private(set) var haptics: TouchHaptics!

    /// 回复落账后在空间里停留多久再淡掉。
    static let replyLinger: Duration = .seconds(5)

    private var placeMapWatch: AnyCancellable?
    static let liveKey = "touch.live"
    private var liveTask: Task<Void, Never>?
    private static let liveLog = Logger(subsystem: "touch-space", category: "touch.live")
    private var replyFade: Task<Void, Never>?
    private var replyStreaming = false

    public init(host: (any TouchChatHost)? = nil) {
        self.host = host
        tuning = TouchTuningStore(report: { [weak host] in Self.reportVia(host, "touch.tuning", $0) })
        let look: TouchLook
        if let stored = UserDefaults.standard.string(forKey: TouchLook.defaultsKey) {
            if let parsed = TouchLook(rawValue: stored) {
                look = parsed
            } else {
                Self.reportVia(host, TouchLook.defaultsKey, "存着的触感效果「\(stored)」不认得，这次用水纹")
                look = .standard
            }
        } else {
            look = .standard
        }
        self.look = look
        filter = TouchFilter(look: look)
        haptics = TouchHaptics(
            strength: { [unowned self] in tuning.value.haptics },
            report: { [weak host] in Self.reportVia(host, "touch.haptics", $0) })
        // 描述里位置的说法跟着调参面板走。
        store.placeMap = tuning.value.placeMap
        placeMapWatch = tuning.$value.map(\.placeMap).removeDuplicates()
            .sink { [unowned store] in store.placeMap = $0 }
    }

    // MARK: 给宿主用

    /// 有没有攒着、还没发出去的触摸（宿主拿它决定发送键能不能按：一个字不写也能发）。
    public var hasPending: Bool { store.hasPending }

    /// 宿主按发送时调用：取走攒着的这一批，返回翻译好的 `<touch …>` 段，排在正文前面一起发；没有触摸时返回 nil。
    public func takeForSending() -> String? { store.takePacket()?.text }

    /// 出错时报给宿主；没接宿主就写进系统日志。
    func report(_ source: String, _ text: String) { Self.reportVia(host, source, text) }

    private nonisolated static let errorLog = Logger(subsystem: "touch-space", category: "error")
    nonisolated static func reportVia(_ host: (any TouchChatHost)?, _ source: String, _ text: String) {
        if let host {
            Task { @MainActor in host.touchSpaceReport(source, text) }
        } else {
            errorLog.error("\(source, privacy: .public)：\(text, privacy: .public)")
        }
    }

    // MARK: 进出

    public func open() {
        #if os(iOS)
        // 输入框正打着字的话，先把键盘收走（键盘在自己的窗口里，会盖在空间上面）。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        // Mac：输入框还握着键盘焦点的话，打的字会进被盖住的输入框，Esc 也被它吃掉（关不了空间）。
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
        // 空间还没出现：此刻窗口里就是她看到的聊天页。
        do {
            snapshot = try TouchSnapshot.capture(in: hostObject)
        } catch {
            snapshot = nil
            report("touch", "进触感空间时没截到聊天页，这次不变形（照样能摸、能发）：\(error)")
        }
        haptics.prepare()
        isOpen = true
        // 进空间后宿主可能还在动版面：稍后再拍一次，空间里就是滑好的样子。
        refreshSnapshotSoon(after: 0.5)
    }

    #if os(iOS)
    private var hostObject: AnyObject? { hostWindow }
    #else
    private var hostObject: AnyObject? { nil }
    #endif

    /// 聊天页变了（模型回话、发出去的那条落进记录）：过一会儿重拍，空间里看到的就是新的聊天页，回话也能摸。
    /// 只有 iOS 拍得到（空间在另一层窗口）；Mac 空间盖在同一个窗口里，重拍会把空间自己拍进去，所以不拍、回话照旧浮在空间里。
    /// 调参面板开着不拍（Mac 同理；iOS 面板也在空间那一层，拍不进来，但省得面板挡着时白拍）。
    func refreshSnapshotSoon(after seconds: Double) {
        #if os(iOS)
        guard isOpen, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            guard self.isOpen else { return }
            do {
                self.snapshot = try TouchSnapshot.capture(in: self.hostObject)
                self.renderer?.wake()
            } catch {
                // 这一次没拍到：留着上一张，下一次回话再拍。
            }
        }
        #endif
    }

    /// 截图上传失败（渲染器报的）：丢掉，这次不变形。
    func dropSnapshot() {
        snapshot = nil
    }

    /// 胶囊里点效果图标：换效果并记住。正在动的波纹 / 手指清掉，已经攒下的触摸不动（这一批照样会发）。
    func select(_ look: TouchLook) {
        apply(look)
        UserDefaults.standard.set(look.rawValue, forKey: TouchLook.defaultsKey)
    }

    /// 换效果，不写进 UserDefaults。
    func apply(_ look: TouchLook) {
        self.look = look
        filter.reset(look)
        renderer?.wake()
    }

    /// 画布尺寸变了（渲染器报的）。
    func canvasResized(_ size: CGSize) {
        canvasSize = size
        store.form = CGRect(origin: .zero, size: size)
    }

    /// ✓ / ✕：回到聊天。摸过的这一批留在输入框里，等她按发送（可以先打几个字）。
    /// 开着实时时没有「放进输入框」：没发的立刻发出去。
    public func close() {
        stopLive()
        if store.hasPending {
            if live {
                sendLive(force: true)
            } else {
                haptics.placed()
                if dryRun { store.discard() }
            }
        }
        filter.reset(look)
        haptics.strokeEnded()
        isOpen = false
        refreshTask?.cancel()
        refreshTask = nil
        snapshot = nil
        panelOpen = false
        replyFade?.cancel()
        replyVisible = false
    }

    /// 长按胶囊 / 输入框里小标签的 ×：清掉这一批。
    public func discard() {
        store.discard()
        stopLive()
    }

    /// 胶囊里的「实时」：开 / 关并记住。关掉时攒着的那一批留着（照普通用法放进输入框）。
    func toggleLive() {
        live.toggle()
        UserDefaults.standard.set(live, forKey: Self.liveKey)
        stopLive()
        if live { liveAfterChange() }
    }

    /// 三指长按 / Mac 右键：打开调参面板。此刻按着的手指不算摸。
    func openPanelDroppingActive() {
        store.dropActive()
        filter.releaseAll()
        renderer?.wake()
        haptics.strokeEnded()
        panelOpen = true
    }

    // MARK: 手指（表面视图转来）

    func began(_ key: AnyHashable, _ sample: TouchSample, source: TouchPressureSource) {
        defer { liveAfterChange() }
        store.began(key, sample, source: source)
        filter.press(key, at: sample.point, time: sample.time)
        renderer?.wake()
        haptics.tap(sample.pressure)
    }

    func moved(_ key: AnyHashable, _ samples: [TouchSample]) {
        store.moved(key, samples)
        guard !samples.isEmpty else { return }
        // 每个合并采样都喂：水纹按走过的距离落滴，漏掉中间点会少落。
        var speed: Float = 0
        for sample in samples { speed = filter.drag(key, to: sample.point, time: sample.time) }
        haptics.stroke(speed: speed, pressure: samples.last!.pressure)
    }

    func ended(_ key: AnyHashable, at time: TimeInterval) {
        store.ended(key, at: time)
        haptics.release(filter.release(key))
        if !store.isTouching { haptics.strokeEnded() }
        liveAfterChange()
    }

    // MARK: 实时触摸

    private var liveWhileTouching: Bool { tuning.value.liveWhileTouching }
    private var liveSeconds: Double {
        min(max(tuning.value.liveSeconds, TouchTuning.liveSecondsRange.lowerBound), TouchTuning.liveSecondsRange.upperBound)
    }

    /// 摸了 / 抬手了：按节奏排下一次发送。
    /// - 边摸边发：已经在数就不动（每 N 秒一拍，摸着不会把它推后）；没在数、又有东西可发，就开始数。
    /// - 停手后发：一碰就停住；所有手指离开才开始数。
    private func liveAfterChange() {
        guard live, isOpen, !liveWaiting else { return }
        if liveWhileTouching {
            if liveTask == nil, store.hasPending || store.isTouching { armLive() }
        } else {
            if store.isTouching {
                cancelLiveTimer()
            } else if store.hasPending {
                armLive()
            }
        }
    }

    private func armLive() {
        cancelLiveTimer()
        let seconds = liveSeconds
        liveRing = (Date(), seconds)
        liveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return // 又摸了（停手后发）/ 关了 / 关掉实时 / 清掉了。
            }
            guard let self else { return }
            self.liveTask = nil
            self.liveRing = nil
            self.sendLive(force: false)
            self.liveAfterChange()
        }
    }

    /// 发这一批。模型还在说话：先不发，等它说完再一起发（`force` = 回聊天时，不等，进它的收件箱排队）。
    private func sendLive(force: Bool) {
        guard store.hasPending else { return }
        if dryRun {
            // 试摸：不往会话里发，把本来要发的那段写进日志（验收时看描述对不对）。
            if let packet = store.takePacket() {
                Self.liveLog.info("试摸，没发：\(packet.text, privacy: .public)")
            }
            haptics.sent()
            return
        }
        guard let host else {
            report("touch", "没有接聊天前端（TouchSpace.host），实时触摸发不出去（这一批还留着）")
            return
        }
        if host.isReplying, !force {
            // 模型还在说话：先攒着，宿主调用 `replyFinished` 时再一起发。
            liveWaiting = true
            return
        }
        liveWaiting = false
        guard let packet = store.takePacket() else { return }
        host.sendTouchNow(packet.text)
        haptics.sent()
        // 她的那条落进聊天记录：重拍一下，空间里看得到。
        refreshSnapshotSoon(after: 0.35)
    }

    private func sendIfReplyDone() {
        guard liveWaiting, let host, !host.isReplying else { return }
        liveWaiting = false
        sendLive(force: false)
        liveAfterChange()
    }

    private func cancelLiveTimer() {
        liveTask?.cancel()
        liveTask = nil
        liveRing = nil
    }

    private func stopLive() {
        cancelLiveTimer()
        liveWaiting = false
    }

    // MARK: 回复（宿主转来）

    /// 宿主在模型回复的过程中，每收到一段文字就调用一次（text 是新来的这一段）。
    public func replyDelta(_ text: String) {
        guard isOpen else { return }
        #if os(iOS)
        // iOS：回话就在聊天记录里，空间重拍聊天页就看得到。流式时最多每 0.4 秒拍一次。
        refreshSnapshotSoon(after: 0.4)
        #else
        if !replyStreaming {
            replyStreaming = true
            reply = ""
        }
        reply += text
        replyFade?.cancel()
        replyVisible = true
        #endif
    }

    /// 宿主在模型回复结束时调用（text 是完整的回复，可以传空字符串）。
    /// 实时模式下，模型说话期间攒着的触摸会在这时一起发出去。
    public func replyFinished(_ text: String = "") {
        defer { sendIfReplyDone() }
        guard isOpen else { return }
        #if os(iOS)
        // 落账后拍一次，再过一会儿补一次（Markdown 的行高可能是异步量的，第一次拍时版面可能还在动）。
        refreshTask?.cancel()
        refreshTask = nil
        refreshSnapshotSoon(after: 0.35)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.refreshSnapshotSoon(after: 0)
        }
        #else
        replyStreaming = false
        if !text.isEmpty { reply = text }
        replyVisible = !reply.isEmpty
        fadeReplyLater()
        #endif
    }

    private func fadeReplyLater() {
        replyFade?.cancel()
        replyFade = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.replyLinger)
            } catch {
                return // 新的回复又来了。
            }
            self?.replyVisible = false
        }
    }
}

// MARK: - 视图

/// 挂在根视图上（`decorateRoot`）：开着时盖住一切。画布铺的是截图，看上去和聊天页一模一样，直到手指碰上去。
struct TouchSpaceLayer: View {
    @ObservedObject var space: TouchSpace

    var body: some View {
        ZStack {
            if space.isOpen {
                TouchSpaceView(space: space)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: space.isOpen)
    }
}

struct TouchSpaceView: View {
    @ObservedObject var space: TouchSpace
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme
    #if os(iOS)
    /// iOS 的空间在自己那一层窗口里（`TouchWindow.swift`），挂在单独的 UIHostingController 上，
    /// 拿不到 App 的 `scenePhase`（一直不是 active，画布于是一帧不画、只透出底下的聊天）。
    /// 所以 iOS 直接看 App 在不在前台。
    @State private var appActive = UIApplication.shared.applicationState == .active
    private var inForeground: Bool { appActive }
    #else
    private var inForeground: Bool { phase == .active }
    #endif

    var body: some View {
        ZStack {
            // 不变暗：底下的聊天不可操作（这一层吃掉点击），画布截不到图时透出来的就是它。
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
            // 退到后台 / 不在前台就停渲染；离开空间时整个视图拆掉，自然也停。静下来时渲染器自己停帧。
            TouchCanvas(space: space, paused: !inForeground, dark: scheme == .dark)
                .ignoresSafeArea()
            #if os(macOS)
            // Mac 的空间盖在聊天同一个窗口里，重拍不了聊天页：回话照旧浮在这里（iOS 回话直接出现在聊天记录里）。
            replyText
            #endif
            VStack {
                TouchCapsule(space: space, store: space.store)
                    .padding(.top, 10)
                Spacer()
            }
            if space.panelOpen {
                VStack {
                    Spacer()
                    TouchTuningPanel(tuning: space.tuning, space: space)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: space.panelOpen)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in appActive = false }
        #endif
    }

    private var replyText: some View {
        VStack {
            Spacer()
            // 背后是浅色或深色的聊天页（没有蒙层）：垫一块薄材质，两种外观下都看得清。
            Text(space.reply.count > 240 ? "…" + space.reply.suffix(240) : space.reply)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .opacity(space.replyVisible ? 1 : 0)
        .animation(.easeOut(duration: space.replyVisible ? 0.6 : 1.8), value: space.replyVisible)
        .allowsHitTesting(false)
    }
}

/// 顶上的胶囊：一只手（有摸过的就是实心）+ 两个效果图标（当前那个高亮）+ 实时 + 手感参数 + ✓（摸过）/ ✕（没摸）。
/// 长按 →「清掉这一批」。
struct TouchCapsule: View {
    @ObservedObject var space: TouchSpace
    @ObservedObject var store: TouchStore
    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 14) {
            TouchLiveRing(space: space, store: store)
            HStack(spacing: 4) {
                ForEach(TouchLook.allCases) { look in
                    let current = space.look == look
                    Button { space.select(look) } label: {
                        Image(systemName: look.symbol)
                            .font(.system(size: 13))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white.opacity(current ? 0.22 : 0)))
                            .opacity(current ? 1 : 0.6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(look.label)
                    .accessibilityLabel(look.label)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            Button { space.toggleLive() } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(space.live ? 0.22 : 0)))
                    .opacity(space.live ? 1 : 0.6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(space.live ? "实时开着：摸着摸着就自动发（节奏在调参面板里调）" : "实时：不用点 ✓，摸着摸着就自动发")
            .accessibilityLabel("实时")
            .accessibilityAddTraits(space.live ? .isSelected : [])
            // 调参面板的按钮（三指长按不好召唤）。三指长按 / Mac 右键照旧能开。
            Button { space.panelOpen.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(space.panelOpen ? 0.22 : 0)))
                    .opacity(space.panelOpen ? 1 : 0.6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(space.panelOpen ? "收起手感参数" : "手感参数")
            .accessibilityLabel("手感参数")
            Button { space.close() } label: {
                Image(systemName: store.hasPending && !space.live ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(space.live ? (store.hasPending ? "回到聊天（没发的立刻发出去）" : "回到聊天")
                  : (store.hasPending ? "摸好了：放进输入框，回到聊天" : "回到聊天"))
            .accessibilityLabel(store.hasPending && !space.live ? "放进输入框" : "回到聊天")
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .onLongPressGesture(minimumDuration: 0.45) {
            if store.hasPending { confirmingDiscard = true }
        }
        .confirmationDialog("这一批触摸", isPresented: $confirmingDiscard, titleVisibility: .hidden) {
            Button("清掉这一批（\(store.pendingCount) 笔）", role: .destructive) { space.discard() }
            Button("留着", role: .cancel) {}
        }
    }
}

/// 胶囊左边那只手：摸过、还没发是实心。开着实时时外面绕一圈：画满 = 发出去；攒好了在等模型说完时停在满格慢慢呼吸。
struct TouchLiveRing: View {
    @ObservedObject var space: TouchSpace
    @ObservedObject var store: TouchStore

    var body: some View {
        TimelineView(.animation(paused: space.liveRing == nil && !space.liveWaiting)) { timeline in
            let now = timeline.date
            let (progress, glow): (Double, Double) = {
                if space.liveWaiting {
                    return (1, 0.55 + 0.45 * (0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 2 * .pi / 2.4)))
                }
                if let ring = space.liveRing {
                    return (min(now.timeIntervalSince(ring.since) / ring.duration, 1), 1)
                }
                return (0, 1)
            }()
            ZStack {
                if space.live {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.9 * glow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: store.hasPending ? "hand.point.up.left.fill" : "hand.point.up.left")
                    .font(.system(size: 13))
            }
            .frame(width: 30, height: 30)
        }
    }
}

/// 输入区那只手：点它进入触感空间。摸过、还没发的那一批在它旁边显示成一枚「手 + 笔数」的小标签：
/// 点标签回到空间接着摸，点 × 清掉；按发送时跟正文一起发出。
public struct TouchEntryButton: View {
    @ObservedObject var space: TouchSpace
    @ObservedObject var store: TouchStore

    public init(space: TouchSpace) {
        self.space = space
        self.store = space.store
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button { space.open() } label: {
                Image(systemName: "hand.point.up.left")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("触感空间：直接摸整块聊天页，摸好点 ✓ 放进输入框")
            if store.hasPending {
                HStack(spacing: 4) {
                    Button { space.open() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.point.up.left.fill")
                            Text("\(store.pendingCount)").monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .help("这一批触摸会跟着下一条消息发出；点这里接着摸")
                    Button { space.discard() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("清掉这一批触摸")
                    .accessibilityLabel("清掉这一批触摸")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.hasPending)
    }
}

/// 用户气泡里的触摸段：一只手 + 笔数，点开看描述全文。
public struct TouchChip: View {
    let summary: String
    let strokes: Int
    @State private var open = false

    public init(summary: String, strokes: Int) {
        self.summary = summary
        self.strokes = strokes
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.point.up.left.fill")
                    Text("\(strokes)").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(open ? "收起触摸描述" : "这条消息带着 \(strokes) 笔触摸，点开看模型读到的描述")
            if open {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
