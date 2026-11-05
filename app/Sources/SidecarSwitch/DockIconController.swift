import AppKit
import Foundation
import SidecarIcon
import SidecarSwitchCore

@MainActor
final class DockIconController {
    struct Dependencies {
        var scheduler: DockIconScheduler
        var now: () -> Duration
        var reduceMotion: () -> Bool
        var applyImage: (NSImage) -> Void
        var render: (IconRenderRequest) -> CGImage?
    }

    private struct RestCacheKey: Equatable {
        var holder: Holder?
    }

    private struct RestCacheEntry {
        var key: RestCacheKey
        var images: [NSImage?]
    }

    private struct PulseCacheKey: Equatable {
        var from: Holder?
    }

    private struct PulseCacheEntry {
        var key: PulseCacheKey
        var pulse: [NSImage?]
        var slides: [Holder: [NSImage?]]
        var slideProgress: Int
    }

    private var phase: DockIconPhase = .rest(holder: nil)
    private var phaseStart: Duration = .zero
    private var reduceMotionCaptured: Bool?
    private var generation: Int = 0
    private let scheduler: DockIconScheduler
    private let now: () -> Duration
    private let reduceMotion: () -> Bool
    private let applyImage: (NSImage) -> Void
    private let render: (IconRenderRequest) -> CGImage?
    private nonisolated(unsafe) var handle: DockIconScheduleHandle?
    private var restCache: RestCacheEntry?
    private var pulseCache: PulseCacheEntry?

    init(dependencies: Dependencies) {
        self.scheduler = dependencies.scheduler
        self.now = dependencies.now
        self.reduceMotion = dependencies.reduceMotion
        self.applyImage = dependencies.applyImage
        self.render = dependencies.render
    }

    deinit {
        handle?.invalidate()
    }

    func showRest(holder: Holder?) {
        enter(DockIconStateMachine.showRest(holder: holder))
    }

    func beginTransition(from holder: Holder?) {
        let captured: Bool
        if case .rest = phase {
            captured = reduceMotion()
            reduceMotionCaptured = captured
        } else if let value = reduceMotionCaptured {
            captured = value
        } else {
            captured = reduceMotion()
            reduceMotionCaptured = captured
        }
        enter(DockIconStateMachine.begin(phase: phase, from: holder, reduceMotion: captured))
    }

    func finishTransition(_ outcome: TransitionOutcome, current: Location, needsReconcile: Bool) {
        let step = DockIconStateMachine.onOutcome(outcome,
                                                  phase: phase,
                                                  current: current,
                                                  needsReconcile: needsReconcile,
                                                  reduceMotionCaptured: reduceMotionCaptured ?? false)
        enter(step)
    }

    func invalidate() {
        handle?.invalidate()
        handle = nil
        generation &+= 1
    }

    private func enter(_ step: DockIconStep) {
        if let settle = step.settle {
            applyPhase(settle)
        }
        phase = step.next
        phaseStart = now()
        generation &+= 1
        handle?.invalidate()
        handle = nil
        switch step.next {
        case .rest(let holder):
            reduceMotionCaptured = nil
            applyRest(holder)
        case .pulsing(let from):
            let entry = preparePulse(from: from)
            if let image = entry.pulse.first ?? nil {
                applyImage(image)
            }
            startTimer(interval: .seconds(1.0 / Double(DockIconStateMachine.pulseSampleHz)))
        case .staticSwitching(let from):
            applyStatic(from: from)
        case .sliding(let from, let to):
            let entry = prepareSlides(from: from, to: to)
            if let image = entry.slides[to]?.first ?? nil {
                applyImage(image)
            }
            startTimer(interval: .seconds(1.0 / Double(DockIconStateMachine.slideSampleHz)))
        }
    }

    private func startTimer(interval: Duration) {
        let scheduledGeneration = generation
        handle = scheduler.schedule(interval: interval) { [weak self] in
            self?.tick(scheduledGeneration: scheduledGeneration)
        }
    }

    private func tick(scheduledGeneration: Int) {
        guard scheduledGeneration == generation else { return }
        let elapsed = now() - phaseStart
        let step = DockIconStateMachine.tick(phase: phase,
                                             elapsed: elapsed,
                                             reduceMotionCaptured: reduceMotionCaptured ?? false)
        switch step.next {
        case .rest:
            enter(step)
        case .pulsing:
            applyFrame(phase: step.next, elapsed: elapsed)
            precomputeSlideFrames(generation: scheduledGeneration)
        case .sliding:
            applyFrame(phase: step.next, elapsed: elapsed)
        case .staticSwitching:
            break
        }
    }

    private func applyFrame(phase: DockIconPhase, elapsed: Duration) {
        switch phase {
        case .pulsing(let from):
            guard let entry = pulseCache, entry.key == PulseCacheKey(from: from) else { return }
            let index = DockIconStateMachine.frameIndex(phase: phase, elapsed: elapsed)
            if index < entry.pulse.count, let image = entry.pulse[index] {
                applyImage(image)
            }
        case .sliding(let from, let to):
            guard let entry = pulseCache, entry.key == PulseCacheKey(from: from),
                  let frames = entry.slides[to] else { return }
            let index = DockIconStateMachine.frameIndex(phase: phase, elapsed: elapsed)
            if index < frames.count, let image = frames[index] {
                applyImage(image)
            }
        default:
            break
        }
    }

    private func applyPhase(_ phase: DockIconPhase) {
        switch phase {
        case .rest(let holder):
            applyRest(holder)
        case .staticSwitching(let from):
            applyStatic(from: from)
        case .pulsing(let from):
            let entry = preparePulse(from: from)
            if let image = entry.pulse.first ?? nil {
                applyImage(image)
            }
        case .sliding(let from, let to):
            let entry = prepareSlides(from: from, to: to)
            if let image = entry.slides[to]?.first ?? nil {
                applyImage(image)
            }
        }
    }

    private func applyRest(_ holder: Holder?) {
        if let image = cachedRestImage(holder) {
            applyImage(image)
        }
    }

    @discardableResult
    private func cachedRestImage(_ holder: Holder?) -> NSImage? {
        let key = RestCacheKey(holder: holder)
        if let cache = restCache, cache.key == key {
            return cache.images.first ?? nil
        }
        let image = renderImage(frameRequest(.rest(holder: holder), elapsed: .zero))
        if let image {
            restCache = RestCacheEntry(key: key, images: [image])
        }
        return image
    }

    private func applyStatic(from: Holder?) {
        if let image = renderImage(frameRequest(.staticSwitching(from: from), elapsed: .zero)) {
            applyImage(image)
        }
    }

    private func preparePulse(from: Holder?) -> PulseCacheEntry {
        var entry = pulseEntry(from: from)
        guard entry.pulse.isEmpty else { return entry }
        entry.pulse.reserveCapacity(DockIconStateMachine.pulseFrameCount)
        for index in 0..<DockIconStateMachine.pulseFrameCount {
            let elapsed = Duration.seconds(Double(index) / Double(DockIconStateMachine.pulseSampleHz))
            entry.pulse.append(renderImage(frameRequest(.pulsing(from: from), elapsed: elapsed)))
        }
        pulseCache = entry
        return entry
    }

    private func pulseEntry(from: Holder?) -> PulseCacheEntry {
        let key = PulseCacheKey(from: from)
        if let cache = pulseCache, cache.key == key {
            return cache
        }
        let empty = [NSImage?](repeating: nil, count: DockIconStateMachine.slideFrameCount)
        let entry = PulseCacheEntry(key: key,
                                    pulse: [],
                                    slides: [.lavoro: empty, .personale: empty],
                                    slideProgress: 0)
        pulseCache = entry
        return entry
    }

    private func prepareSlides(from: Holder?, to: Holder) -> PulseCacheEntry {
        var entry = pulseEntry(from: from)
        var frames = entry.slides[to] ?? [NSImage?](repeating: nil,
                                                    count: DockIconStateMachine.slideFrameCount)
        guard frames.contains(where: { $0 == nil }) else { return entry }
        for index in 0..<DockIconStateMachine.slideFrameCount where frames[index] == nil {
            let elapsed = Duration.milliseconds(Int64(index) * 35)
            frames[index] = renderImage(frameRequest(.sliding(from: from, to: to), elapsed: elapsed))
        }
        entry.slides[to] = frames
        pulseCache = entry
        return entry
    }

    private func precomputeSlideFrames(generation scheduledGeneration: Int, budget: Int = 2) {
        guard scheduledGeneration == generation,
              case .pulsing(let from) = phase,
              var entry = pulseCache,
              entry.key == PulseCacheKey(from: from) else { return }
        let total = DockIconStateMachine.slideFrameCount * 2
        var rendered = 0
        while rendered < budget, entry.slideProgress < total {
            let progress = entry.slideProgress
            entry.slideProgress += 1
            let target: Holder = progress < DockIconStateMachine.slideFrameCount ? .lavoro : .personale
            let index = progress % DockIconStateMachine.slideFrameCount
            if entry.slides[target]?[index] == nil {
                let elapsed = Duration.milliseconds(Int64(index) * 35)
                entry.slides[target]?[index] = renderImage(frameRequest(.sliding(from: from, to: target),
                                                                        elapsed: elapsed))
                rendered += 1
            }
        }
        pulseCache = entry
    }

    private func frameRequest(_ phase: DockIconPhase, elapsed: Duration) -> IconRenderRequest {
        DockIconStateMachine.frame(phase: phase,
                                   elapsed: elapsed,
                                   size: IconRenderer.runtimeFrameSize).request
    }

    private func renderImage(_ request: IconRenderRequest) -> NSImage? {
        guard let image = render(request) else {
            NSLog("SidecarSwitch: dock icon render failed (size \(request.size))")
            return nil
        }
        let points = CGFloat(request.size) / 2
        return NSImage(cgImage: image, size: NSSize(width: points, height: points))
    }
}

final class TimerDockIconScheduler: DockIconScheduler {
    @MainActor
    func schedule(interval: Duration, handler: @escaping @MainActor () -> Void) -> DockIconScheduleHandle {
        let components = interval.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) * 1e-18
        let timer = Timer(timeInterval: max(seconds, 0.001), repeats: true) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerDockIconScheduleHandle(timer: timer)
    }
}

final class TimerDockIconScheduleHandle: DockIconScheduleHandle, @unchecked Sendable {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    nonisolated func invalidate() {
        timer.invalidate()
    }
}
