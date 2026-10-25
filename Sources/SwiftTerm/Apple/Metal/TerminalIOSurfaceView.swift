//
//  TerminalIOSurfaceView.swift
//  SwiftTerm
//
//  Shows Metal frames the way Ghostty does: the GPU renders into IOSurfaces
//  we own, and each finished frame becomes a plain layer's `contents` on the
//  main thread. A frame then reaches the screen in the app's own Core
//  Animation transaction, like Core Graphics output.
//
//  A `CAMetalLayer` presents through its own drawable queue instead. On iOS
//  that queue can stay two or three frames deep for seconds after the app
//  returns from the background, so scrolling trails the finger by 33–50 ms
//  until it drains. Owning the surfaces removes the queue.
//

#if !SWIFTTERM_EMBEDDED
#if os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import IOSurface
import Metal
import QuartzCore
import UIKit

/// The surfaces frames are rendered into, and which of them are free.
///
/// Frames are acquired on the main thread by the frame tick. A command
/// buffer's completion handler, on a Metal thread, hands the finished surface
/// back to main, so the slot state is guarded by a lock.
private final class TerminalIOSurfacePool: @unchecked Sendable, MetalRenderSurface {
    /// Its mutable state is only touched with the pool's lock held.
    final class Slot: @unchecked Sendable {
        let surface: IOSurface
        let texture: MTLTexture
        let size: CGSize
        /// Rendering, or rendered and waiting to be shown.
        var busy = false
        /// The layer's contents right now.
        var onScreen = false

        init(surface: IOSurface, texture: MTLTexture, size: CGSize) {
            self.surface = surface
            self.texture = texture
            self.size = size
        }
    }

    /// Enough to render one frame while another waits to be shown and the
    /// compositor still reads a third.
    private static let maximumSlots = 4

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var geometry: MetalSurfaceGeometry
    private var device: MTLDevice?
    /// Shows a finished slot. Set by the view; called on the main thread.
    var show: (@MainActor (Slot) -> Void)?
    /// Asks for another frame when no surface was free for this one.
    var retry: (@MainActor () -> Void)?

    init(geometry: MetalSurfaceGeometry) {
        self.geometry = geometry
    }

    var currentDevice: MTLDevice? {
        get { lock.withLock { device } }
        set { lock.withLock { device = newValue } }
    }

    var currentGeometry: MetalSurfaceGeometry {
        lock.withLock { geometry }
    }

    func publish(_ newGeometry: MetalSurfaceGeometry) {
        lock.withLock {
            geometry = newGeometry
            // Surfaces of another size are no use for new frames. The one on
            // screen stays alive as the layer's contents until it is replaced.
            slots.removeAll { !$0.busy && !$0.onScreen && $0.size != newGeometry.drawableSize }
        }
    }

    func acquireDrawableFrame() -> MetalDrawableFrame? {
        guard let slot = lock.withLock({ takeSlot() }) else {
            // Without a command buffer nothing would ask for this frame again.
            DispatchQueue.main.async { [retry] in
                MainActor.assumeIsolated { retry?() }
            }
            return nil
        }
        let descriptor = MTLRenderPassDescriptor()
        let color = descriptor.colorAttachments[0]
        color?.texture = slot.texture
        color?.loadAction = .clear
        color?.storeAction = .store
        let geometry = currentGeometry
        return MetalDrawableFrame(texture: slot.texture,
                                  renderPassDescriptor: descriptor,
                                  geometry: geometry) { [weak self] commandBuffer in
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let shown = buffer.status == .completed
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lock.withLock {
                            if shown {
                                self.slots.forEach { $0.onScreen = false }
                                slot.onScreen = true
                            }
                            slot.busy = false
                        }
                        if shown { self.show?(slot) }
                    }
                }
            }
        }
    }

    /// A free surface of the current size, made if there is room for one.
    /// Call with the lock held.
    private func takeSlot() -> Slot? {
        let size = geometry.drawableSize
        slots.removeAll { !$0.busy && !$0.onScreen && $0.size != size }
        // `isInUse` is true while the compositor still reads a surface that
        // was on screen a moment ago.
        if let slot = slots.first(where: { !$0.busy && !$0.onScreen && $0.size == size && !$0.surface.isInUse }) {
            slot.busy = true
            return slot
        }
        guard slots.count < Self.maximumSlots, let slot = makeSlot(size: size) else { return nil }
        slot.busy = true
        slots.append(slot)
        return slot
    }

    private func makeSlot(size: CGSize) -> Slot? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let device else { return nil }
        let bytesPerElement = 4
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: bytesPerElement,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytesPerElement),
            .pixelFormat: 0x4247_5241, // 'BGRA', matching .bgra8Unorm
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        // Tag the pixels sRGB, as the CAMetalLayer path does, so the
        // compositor color-manages them like a regular view's backing store.
        if let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            return nil
        }
        return Slot(surface: surface, texture: texture, size: size)
    }
}

/// A view that shows Metal frames as its layer's contents.
@MainActor
final class TerminalIOSurfaceView: UIView {
    /// Called when the surface wants a frame — a resize, or no free surface.
    /// The host decides how to service it.
    var onNeedsDisplay: (@MainActor () -> Void)?
    private let pool: TerminalIOSurfacePool

    override init(frame: CGRect) {
        pool = TerminalIOSurfacePool(geometry: MetalSurfaceGeometry(bounds: CGRect(origin: .zero, size: frame.size),
                                                                    drawableSize: .zero,
                                                                    contentsScale: 1))
        super.init(frame: frame)
        // Pinned to the top left, a frame drawn for the old size is not
        // stretched while a resize waits for the next one.
        layer.contentsGravity = .topLeft
        pool.show = { [weak self] slot in self?.show(slot) }
        pool.retry = { [weak self] in self?.onNeedsDisplay?() }
        updateDrawableSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderContentsScale = traitCollection.displayScale
        updateDrawableSize()
        onNeedsDisplay?()
    }

    private func show(_ slot: TerminalIOSurfacePool.Slot) {
        // A plain contents swap; the implicit fade would blur every frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = slot.surface
        CATransaction.commit()
    }

    private func updateDrawableSize() {
        let scale = layer.contentsScale
        let size = CGSize(width: (bounds.width * scale).rounded(.down),
                          height: (bounds.height * scale).rounded(.down))
        pool.publish(MetalSurfaceGeometry(bounds: bounds, drawableSize: size, contentsScale: scale))
    }
}

extension TerminalIOSurfaceView: MetalRenderTarget {
    var renderDevice: MTLDevice? {
        get { pool.currentDevice }
        set { pool.currentDevice = newValue }
    }

    var renderPixelFormat: MTLPixelFormat { .bgra8Unorm }

    var renderDrawableSize: CGSize {
        get { pool.currentGeometry.drawableSize }
        set {
            guard newValue.width > 0, newValue.height > 0 else { return }
            pool.publish(MetalSurfaceGeometry(bounds: bounds, drawableSize: newValue, contentsScale: layer.contentsScale))
        }
    }

    var renderBounds: CGRect { bounds }

    var renderContentsScale: CGFloat {
        get { layer.contentsScale }
        set {
            guard newValue > 0, layer.contentsScale != newValue else { return }
            layer.contentsScale = newValue
            updateDrawableSize()
        }
    }

    var renderGeometry: MetalSurfaceGeometry { pool.currentGeometry }

    var detachedRenderSurface: (any MetalRenderSurface)? { pool }

    func acquireDrawableFrame() -> MetalDrawableFrame? {
        pool.acquireDrawableFrame()
    }

    /// Nothing calls back into us the way UIKit calls an MTKView delegate,
    /// so the host must drive `render()` directly.
    var needsExternalDrawCall: Bool { true }

    func requestDisplay() {
        onNeedsDisplay?()
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
