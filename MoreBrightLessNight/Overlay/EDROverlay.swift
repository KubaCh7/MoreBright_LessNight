import AppKit
import Metal
import QuartzCore
import os

let overlayLog = Logger(subsystem: "app.morebrightlessnight", category: "overlay")

/// A window that can never take focus, clicks, or a place in Cmd+Tab / Mission Control.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Full-screen, click-through EDR window whose only content is a uniform value `m` (> 1.0)
/// in extended linear sRGB. With a multiply compositing filter the WindowServer computes
/// `destination * m`, i.e. a pure linear gain on every channel: hue and white point stay put.
///
/// macOS only grants EDR headroom while an EDR surface keeps *presenting* frames. A layer
/// that goes static loses its headroom within about a second and the boost collapses to 1×
/// (BrightIntosh renders at 5 fps for this reason; BetterDisplay calls it "continuous EDR
/// enforcement"). So while the gain is above 1.0 we present a 1×1 clear at 5 Hz on a private
/// queue. During a change we ramp at ~120 Hz for 200 ms (ease-out). At 1.0 the window is
/// ordered out and the loop stops completely.
final class EDROverlay {
    enum Mode {
        /// Full screen, multiply-composited: the overlay itself applies the gain.
        case multiply
        /// 1×1 px in the top-left corner, no compositing filter: only keeps EDR headroom
        /// engaged while the transfer table does the boost (BrightIntosh's "HDR trigger").
        case trigger
    }

    let mode: Mode
    private let window: OverlayWindow
    private let loop: RenderLoop

    // main-confined
    private var isOrderedIn = false
    private var generation = 0

    init?(screen: NSScreen, mode: Mode = .multiply) {
        guard let loop = RenderLoop(multiply: mode == .multiply) else { return nil }
        self.loop = loop
        self.mode = mode

        let frame = Self.frame(for: screen, mode: mode)
        window = OverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        // The trigger sits one level higher: fullscreen apps and games can reorder windows
        // at the shielding level, and a hidden trigger loses EDR (BrightIntosh does the same).
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + (mode == .trigger ? 1 : 0))
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary,
                                     .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.layer = loop.layer
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        window.contentView = view
    }

    deinit {
        loop.stop()
        window.orderOut(nil)
        window.close()
    }

    /// True while the window is on screen (and therefore presenting at ≥ 5 Hz).
    var isPresenting: Bool { isOrderedIn }

    /// Seconds since the last successfully presented frame, for diagnostics.
    var secondsSinceLastFrame: Double? {
        let last = loop.lastPresentTime
        guard last > 0 else { return nil }
        return CACurrentMediaTime() - last
    }

    private static func frame(for screen: NSScreen, mode: Mode) -> NSRect {
        switch mode {
        case .multiply: return screen.frame
        case .trigger: return NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
        }
    }

    func updateFrame(for screen: NSScreen) {
        window.setFrame(Self.frame(for: screen, mode: mode), display: false)
        loop.redraw()
    }

    /// Test mode only: lets ScreenCaptureKit see the boosted composite.
    func setCaptureVisible(_ visible: Bool) {
        window.sharingType = visible ? .readOnly : .none
    }

    /// Main thread. Ramps to `gain`; orders the window out once it settles at 1.0.
    func setGain(_ gain: Double, animated: Bool) {
        generation += 1
        let token = generation
        let target = max(1, gain)
        if target > 1.0001, !isOrderedIn {
            window.orderFrontRegardless()
            isOrderedIn = true
        }
        loop.setTarget(target, animated: animated) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.window.orderOut(nil)
                self.isOrderedIn = false
            }
        }
    }

    /// Re-asserts z-order after app/Space switches; fullscreen transitions can reorder
    /// windows at the shielding level.
    func orderFront() {
        guard isOrderedIn else { return }
        window.orderFrontRegardless()
        loop.redraw()
    }

    func forceRedraw() {
        loop.redraw()
    }

    func tearDown() {
        generation += 1
        loop.stop()
        window.orderOut(nil)
        isOrderedIn = false
    }
}

/// All Metal work and all mutable render state live on `queue`.
private final class RenderLoop {
    static let rampDuration: CFTimeInterval = 0.2
    static let rampIntervalMs = 8
    static let keepAliveIntervalMs = 200 // 5 Hz

    let layer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue
    private let queue = DispatchQueue(label: "MoreBrightLessNight.overlay.render", qos: .userInteractive)

    // queue-confined
    private var currentValue: Double = 1
    private var target: Double = 1
    private var rampFrom: Double = 1
    private var rampStart: CFTimeInterval = 0
    private var ramping = false
    private var timer: DispatchSourceTimer?
    private var timerIntervalMs = 0
    private var onSettledAtOne: (() -> Void)?

    private let lock = NSLock()
    private var _lastPresentTime: CFTimeInterval = 0
    var lastPresentTime: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _lastPresentTime
    }

    init?(multiply: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 3
        // Content is uniform, so a 1×1 drawable stretched over the screen is enough.
        layer.drawableSize = CGSize(width: 1, height: 1)
        layer.contentsGravity = .resize
        // "multiply" is the CA filter name BrightIntosh ships with; it blends with the
        // windows underneath during WindowServer compositing.
        if multiply { layer.compositingFilter = "multiply" }
    }

    func setTarget(_ newTarget: Double, animated: Bool, settledAtOne: @escaping () -> Void) {
        queue.async { [self] in
            target = newTarget
            onSettledAtOne = settledAtOne
            if animated, abs(newTarget - currentValue) > 0.001 {
                rampFrom = currentValue
                rampStart = CACurrentMediaTime()
                ramping = true
                schedule(intervalMs: Self.rampIntervalMs)
            } else {
                ramping = false
                draw(newTarget)
                settle()
            }
        }
    }

    func redraw() {
        queue.async { [self] in
            if target > 1.0001 || ramping { draw(currentValue) }
        }
    }

    func stop() {
        queue.async { [self] in
            stopTimer()
            ramping = false
            onSettledAtOne = nil
        }
    }

    // MARK: queue

    private func tick() {
        guard ramping else {
            draw(currentValue) // keep-alive frame: keeps macOS granting EDR headroom
            return
        }
        let progress = min(1, (CACurrentMediaTime() - rampStart) / Self.rampDuration)
        let remaining = 1 - progress
        let eased = 1 - remaining * remaining * remaining // ease-out cubic
        draw(rampFrom + (target - rampFrom) * eased)
        if progress >= 1 {
            ramping = false
            settle()
        }
    }

    private func settle() {
        if target > 1.0001 {
            schedule(intervalMs: Self.keepAliveIntervalMs)
        } else {
            stopTimer()
            onSettledAtOne?()
            onSettledAtOne = nil
        }
    }

    private func schedule(intervalMs: Int) {
        if timer != nil, timerIntervalMs == intervalMs { return }
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(max(1, intervalMs / 8)))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        timerIntervalMs = intervalMs
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerIntervalMs = 0
    }

    private func draw(_ value: Double) {
        currentValue = value
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self, buffer.status == .completed else { return }
            self.lock.lock()
            self._lastPresentTime = CACurrentMediaTime()
            self.lock.unlock()
        }
        commandBuffer.commit()
    }
}
