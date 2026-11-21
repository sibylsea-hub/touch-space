// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import MetalKit
import SwiftUI
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 触感空间的 Metal 渲染：`MTKView` + 一个全屏片元——进空间前截的聊天页当纹理，
/// 按手指（`TouchFilter`）扭开取色。
///
/// 不用 SwiftUI 的 `layerEffect` / `distortionEffect`：它们吃不到 UIKit 撑的视图（UIScrollView、输入框，
/// WKWebView）。截图当纹理则什么都截得到（iOS；Mac 上截不到窗口服务器合成的毛玻璃）。
///
/// **帧率**（「不要让芯片发热」）：有东西在动（`filter.isBusy`）时 120Hz；一旦不忙，画完最后一帧就
/// `isPaused = true`，一帧都不再画，新的手指按下时 `wake()` 再起。离开空间（视图拆掉）、不在前台也停。
/// 着色器编进本模块的资源包（SwiftPM 处理 `.metal` → `default.metallib`），用 `makeDefaultLibrary(bundle: .module)` 取。
@MainActor
final class TouchRenderer: NSObject, MTKViewDelegate {
    private unowned let space: TouchSpace
    private weak var view: MTKView?
    private let queue: MTLCommandQueue
    private let draw: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let loader: MTKTextureLoader
    private var page: (id: UUID, texture: MTLTexture)?
    private var lastFrame: CFTimeInterval?
    /// 静下来了、已停帧（`isPaused` 由「不在前台」与它合起来决定）。
    private var idle = false

    /// 不在前台（SwiftUI 的 scenePhase）。
    var hostPaused = false {
        didSet {
            guard hostPaused != oldValue else { return }
            // 回到前台补画一帧（层里的内容可能被系统丢了），画完照常停。
            if !hostPaused { markAwake() }
            applyPause()
        }
    }

    /// 深色外观：暖色与指尖光换暗色那一对。
    var dark = false {
        didSet { if dark != oldValue { wake() } }
    }

    // 帧率统计：每秒一结；停帧时也结一次（面板角上要看得到「静下来 0 帧」）。
    private var windowStart: CFTimeInterval = 0
    private var windowFrames = 0
    private var windowSlow = 0
    private var totalFrames = 0
    private static let log = Logger(subsystem: "touch-space", category: "touch.fps")
    private static let busyFps = 120

    init(view: MTKView, space: TouchSpace) throws {
        self.space = space
        self.view = view
        let device = view.device!
        queue = device.makeCommandQueue()!
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "touch_vertex")!
        descriptor.fragmentFunction = library.makeFunction(name: "touch_filter_fragment")!
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        draw = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        loader = MTKTextureLoader(device: device)
        super.init()
        view.preferredFramesPerSecond = Self.busyFps
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            space.canvasResized(view.bounds.size)
            wake()
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { frame(view) }
    }

    /// 有新的手指 / 换了效果 / 尺寸或外观变了：从停帧里醒来。
    func wake() {
        guard idle else { return }
        markAwake()
        applyPause()
    }

    private func markAwake() {
        idle = false
        lastFrame = nil
        windowStart = 0
        windowFrames = 0
        windowSlow = 0
    }

    private func applyPause() {
        view?.isPaused = hostPaused || idle
    }

    private func frame(_ view: MTKView) {
        if space.canvasSize != view.bounds.size { space.canvasResized(view.bounds.size) }
        guard view.bounds.width > 0,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        let frameDt = min(max(now - (lastFrame ?? now - 1.0 / 60), 1.0 / 240), 0.1)
        lastFrame = now
        countFrame(now, interval: frameDt)

        let filter = space.filter
        filter.skinSize = space.tuning.value.skinSizeScale
        filter.advance(dt: frameDt)
        // 这一帧开始时已经不忙：把散完的水滴、回稳的槽拿掉，画一帧干净的截图，然后停。
        let settling = !filter.isBusy
        if settling { filter.settle() }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let commands = queue.makeCommandBuffer()!
        let render = commands.makeRenderCommandEncoder(descriptor: pass)!
        // 没有截图（截失败了，已经报告过）：什么也不画，透出底下的聊天页；照样能摸、能发。
        if let texture = pageTexture() {
            let scale = Double(view.drawableSize.width / view.bounds.width)
            let uniforms = filter.uniforms(pixels: view.drawableSize, scale: scale,
                                           uvRect: uvRect(view, snapshot: space.snapshot!),
                                           dark: dark, amp: Self.reducedMotion ? 0.5 : 1)
            render.setRenderPipelineState(draw)
            render.setFragmentTexture(texture, index: 0)
            render.setFragmentSamplerState(sampler, index: 0)
            uniforms.withUnsafeBytes { render.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        render.endEncoding()
        commands.present(drawable)
        commands.commit()

        if settling { goIdle() }
    }

    private func goIdle() {
        idle = true
        applyPause()
        let text = String(format: "静止 · 0 fps · 已停帧（累计 %d 帧）", totalFrames)
        space.frameStats = text
        Self.log.info("\(text, privacy: .public)")
    }

    /// 截图的纹理：截图换了才重新上传。非 sRGB 格式：截图里的字节原样进、原样写进 `bgra8Unorm` 画布，
    /// 颜色和截图前一样（sRGB 格式会在取样时线性化，写回非 sRGB 画布就变暗）。
    private func pageTexture() -> MTLTexture? {
        guard let snapshot = space.snapshot else {
            page = nil
            return nil
        }
        if let page, page.id == snapshot.id { return page.texture }
        do {
            let texture = try loader.newTexture(cgImage: snapshot.image, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft,
                .generateMipmaps: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
            page = (snapshot.id, texture)
            return texture
        } catch {
            space.report("touch", "截图上传成纹理失败，触感空间这次不变形（照样能摸、能发）：\(error)")
            space.dropSnapshot()
            return nil
        }
    }

    /// 画布在截图里的 UV 子矩形。iOS：截图 = key window，画布矩形用窗口坐标；
    /// Mac：截图 = contentView，画布矩形换到 contentView 坐标（不是左上原点就翻过来）。
    private func uvRect(_ view: MTKView, snapshot: TouchSnapshot) -> CGRect {
        #if os(iOS)
        // 画布在触感空间那一层窗口里，截图拍的是聊天那一层：换算到聊天那一层的坐标（两层不同窗口，经屏幕坐标换）。
        let rect = view.convert(view.bounds, to: space.hostWindow)
        #else
        let content = view.window!.contentView!
        var rect = view.convert(view.bounds, to: content)
        if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
        #endif
        return CGRect(x: rect.minX / snapshot.size.width, y: rect.minY / snapshot.size.height,
                      width: rect.width / snapshot.size.width, height: rect.height / snapshot.size.height)
    }

    private static var reducedMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// 屏幕的最高刷新率（模拟器与 MacBook Air 是 60，ProMotion 是 120）。
    private var screenMaxFps: Int {
        #if os(iOS)
        UIScreen.main.maximumFramesPerSecond
        #else
        NSScreen.main!.maximumFramesPerSecond
        #endif
    }

    /// 每秒结一次：实际帧数、慢帧（间隔超过「目标与屏幕上限取小」的 1.5 倍）、累计帧数。
    /// 写进调参面板角上，也打一行日志。停帧期间不出帧，也就不再结（读数停在「静止 · 0 fps」）。
    private func countFrame(_ now: CFTimeInterval, interval: Double) {
        if windowStart == 0 { windowStart = now }
        windowFrames += 1
        totalFrames += 1
        let effective = min(Self.busyFps, screenMaxFps)
        if interval > 1.5 / Double(effective) { windowSlow += 1 }
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        let fps = Double(windowFrames) / elapsed
        let text = String(format: "%.0f fps（目标 %d，屏幕上限 %d）· 慢帧 %d · 累计 %d 帧",
                          fps, Self.busyFps, screenMaxFps, windowSlow, totalFrames)
        space.frameStats = text
        Self.log.info("\(text, privacy: .public)")
        windowStart = now
        windowFrames = 0
        windowSlow = 0
    }
}

// MARK: - 视图（收触摸 / 鼠标）

#if os(iOS)
/// 触感空间的表面：MTKView 本身收多指触摸，转给 `TouchSpace`。
final class TouchMetalView: MTKView {
    weak var space: TouchSpace?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (sample, source) = sample(touch)
            MainActor.assumeIsolated { space?.began(ObjectIdentifier(touch), sample, source: source) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // 合并触摸：120Hz 屏上一帧里攒下的中间点，轨迹更顺。
            let all = event?.coalescedTouches(for: touch) ?? [touch]
            let samples = all.map { sample($0).0 }
            MainActor.assumeIsolated { space?.moved(ObjectIdentifier(touch), samples) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            MainActor.assumeIsolated { space?.ended(ObjectIdentifier(touch), at: touch.timestamp) }
        }
    }

    private func sample(_ touch: UITouch) -> (TouchSample, TouchPressureSource) {
        let point = touch.preciseLocation(in: self)
        let hasForce = touch.maximumPossibleForce > 0
            && (touch.type == .pencil || traitCollection.forceTouchCapability == .available)
        if hasForce {
            let p = min(1, touch.force / touch.maximumPossibleForce)
            return (TouchSample(point: point, time: touch.timestamp, pressure: p, raw: touch.force), .force)
        }
        // 指腹轻点的接触半径大约 12–20pt，压实了能到 40pt 上下。
        let r = touch.majorRadius
        let p = min(1, max(0, (r - 12) / 32))
        return (TouchSample(point: point, time: touch.timestamp, pressure: p, raw: r), .contactArea)
    }
}

struct TouchCanvas: UIViewRepresentable {
    let space: TouchSpace
    let paused: Bool
    let dark: Bool

    final class Coordinator: NSObject {
        var renderer: TouchRenderer?
        let space: TouchSpace
        init(space: TouchSpace) { self.space = space }

        /// 三指长按：打开调参面板。那三根手指不算摸。
        @objc func threeFingerHold(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            MainActor.assumeIsolated { space.openPanelDroppingActive() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(space: space) }

    func makeUIView(context: Context) -> TouchMetalView {
        let view = TouchMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice()!)
        view.space = space
        view.isMultipleTouchEnabled = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // 截图也是 2 倍：3 倍屏上省下一半多的片元。
        view.contentScaleFactor = min(UIScreen.main.scale, 2)
        install(view, context: context)
        let hold = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.threeFingerHold(_:)))
        hold.numberOfTouchesRequired = 3
        hold.minimumPressDuration = 0.8
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        view.addGestureRecognizer(hold)
        return view
    }

    private func install(_ view: TouchMetalView, context: Context) {
        do {
            let renderer = try TouchRenderer(view: view, space: space)
            renderer.dark = dark
            renderer.hostPaused = paused
            view.isPaused = paused
            context.coordinator.renderer = renderer
            view.delegate = renderer
            space.renderer = renderer
        } catch {
            fatalError("触感空间的着色器库加载失败（资源包里没有 default.metallib？）：\(error)")
        }
    }

    func updateUIView(_ view: TouchMetalView, context: Context) {
        context.coordinator.renderer!.hostPaused = paused
        context.coordinator.renderer!.dark = dark
    }
}
#else
/// Mac：鼠标按下 / 拖动 / 抬起 + 触控板压力；右键打开调参面板（Mac 上没有三指长按）。
final class TouchMetalView: MTKView {
    weak var space: TouchSpace?
    private static let key = "mouse"
    /// 最近一次压力事件的读数（鼠标事件本身不带有用的压力）。
    private var pressure: CGFloat = 0.3

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        // 上一笔还没收到抬起就又按下了（抬起丢在了别处）：先替它收尾，不然那根手指一直按着、停不了帧。
        MainActor.assumeIsolated { space?.ended(Self.key, at: event.timestamp) }
        pressure = 0.3
        let sample = TouchSample(point: point(event), time: event.timestamp, pressure: pressure, raw: 0)
        MainActor.assumeIsolated { space?.began(Self.key, sample, source: .trackpad) }
    }

    override func mouseDragged(with event: NSEvent) {
        let sample = TouchSample(point: point(event), time: event.timestamp, pressure: pressure, raw: pressure)
        MainActor.assumeIsolated { space?.moved(Self.key, [sample]) }
    }

    override func pressureChange(with event: NSEvent) {
        // 一档（轻按）0…1 映到 0…0.7，二档（深按）再往上叠到 1。
        pressure = event.stage >= 2 ? 0.7 + 0.3 * CGFloat(event.pressure) : 0.7 * CGFloat(event.pressure)
        let sample = TouchSample(point: point(event), time: event.timestamp, pressure: pressure,
                                     raw: CGFloat(event.pressure))
        MainActor.assumeIsolated { space?.moved(Self.key, [sample]) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { space?.ended(Self.key, at: event.timestamp) }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { space?.openPanelDroppingActive() }
    }
}

struct TouchCanvas: NSViewRepresentable {
    let space: TouchSpace
    let paused: Bool
    let dark: Bool

    final class Coordinator {
        var renderer: TouchRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TouchMetalView {
        let view = TouchMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice()!)
        view.space = space
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.layer!.isOpaque = false
        // 截图已转成 sRGB；不标色彩空间的话 Mac 不做色彩匹配，sRGB 字节直接按屏幕（P3）显示，颜色偏艳。
        (view.layer as! CAMetalLayer).colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        do {
            let renderer = try TouchRenderer(view: view, space: space)
            renderer.dark = dark
            renderer.hostPaused = paused
            view.isPaused = paused
            context.coordinator.renderer = renderer
            view.delegate = renderer
            space.renderer = renderer
        } catch {
            fatalError("触感空间的着色器库加载失败（资源包里没有 default.metallib？）：\(error)")
        }
        return view
    }

    func updateNSView(_ view: TouchMetalView, context: Context) {
        context.coordinator.renderer!.hostPaused = paused
        context.coordinator.renderer!.dark = dark
    }
}
#endif
