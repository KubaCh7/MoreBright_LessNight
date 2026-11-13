import AppKit
import Metal
import QuartzCore

/// A window that can never take focus, clicks, or a place in Cmd+Tab / Mission Control.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Full-screen, click-through EDR window whose only content is a uniform value `m` (> 1.0)
/// in extended linear sRGB. With a multiply compositing filter the WindowServer computes
/// `destination * m`, i.e. a pure linear gain on every channel: hue and white point stay put.
///
/// Rendering: no display link, no continuous loop. A frame is drawn only while a ramp
/// (200 ms, ease-out) is running; afterwards the layer stays static. When the gain returns
/// to 1.0 the window is ordered out entirely, so EDR disengages and costs nothing.
final class EDROverlay {
    static let rampDuration: CFTimeInterval = 0.2

    private let window: OverlayWindow
    private let metalLayer = CAMetalLayer()
    private let commandQueue: MTLCommandQueue
    private let renderQueue = DispatchQueue(label: "MoreBrightLessNight.overlay.render", qos: .userInteractive)

    // renderQueue-confined
    private var displayedGain: Double = 1
    private var rampFrom: Double = 1
    private var rampTo: Double = 1
    private var rampStart: CFTimeInterval = 0
    private var rampTimer: DispatchSourceTimer?

    // main-confined
    private var isOrderedIn = false
    private var generation = 0

    init?(screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue

        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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

        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        // Content is uniform, so a tiny drawable stretched over the screen is enough.
        metalLayer.drawableSize = CGSize(width: 16, height: 16)
        metalLayer.contentsGravity = .resize
        // "multiply" is the CA filter name BrightIntosh ships with; it blends with the
        // windows underneath during WindowServer compositing.
        metalLayer.compositingFilter = "multiply"

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = metalLayer
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        renderQueue.sync { self.render(gain: 1) }
    }

    deinit {
        rampTimer?.cancel()
        window.orderOut(nil)
        window.close()
    }

    func updateFrame(for screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
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
        renderQueue.async { [weak self] in
            self?.startRamp(to: target, animated: animated, token: token)
        }
    }

    func tearDown() {
        generation += 1
        renderQueue.sync {
            rampTimer?.cancel()
            rampTimer = nil
        }
        window.orderOut(nil)
        isOrderedIn = false
    }

    // MARK: renderQueue

    private func startRamp(to target: Double, animated: Bool, token: Int) {
        rampTimer?.cancel()
        rampTimer = nil

        if !animated || abs(target - displayedGain) < 0.001 {
            render(gain: target)
            settle(at: target, token: token)
            return
        }

        rampFrom = displayedGain
        rampTo = target
        rampStart = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick(token: token) }
        rampTimer = timer
        timer.resume()
    }

    private func tick(token: Int) {
        let progress = min(1, (CACurrentMediaTime() - rampStart) / Self.rampDuration)
        let remaining = 1 - progress
        let eased = 1 - remaining * remaining * remaining // ease-out cubic
        render(gain: rampFrom + (rampTo - rampFrom) * eased)
        if progress >= 1 {
            rampTimer?.cancel()
            rampTimer = nil
            settle(at: rampTo, token: token)
        }
    }

    private func settle(at gain: Double, token: Int) {
        guard gain <= 1.0001 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.window.orderOut(nil)
            self.isOrderedIn = false
        }
    }

    private func render(gain: Double) {
        displayedGain = gain
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: gain, green: gain, blue: gain, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
