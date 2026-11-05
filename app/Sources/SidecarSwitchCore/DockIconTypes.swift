import Foundation

public struct IconColor: Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func scaled(_ factor: Double) -> IconColor {
        IconColor(r: min(max(r * factor, 0), 1),
                  g: min(max(g * factor, 0), 1),
                  b: min(max(b * factor, 0), 1),
                  a: a)
    }
}

public enum IconLetter: Sendable, Equatable {
    case w
    case p
}

public enum DockIconRing: Sendable, Equatable {
    case normal
    case emphasis
}

public struct IconRenderRequest: Sendable, Equatable {
    public var knobPosition: Double
    public var exposedTop: IconColor
    public var exposedBottom: IconColor
    public var knobRing: DockIconRing
    public var letter: IconLetter?
    public var size: Int

    public init(knobPosition: Double,
                exposedTop: IconColor,
                exposedBottom: IconColor,
                knobRing: DockIconRing = .normal,
                letter: IconLetter? = nil,
                size: Int) {
        self.knobPosition = knobPosition
        self.exposedTop = exposedTop
        self.exposedBottom = exposedBottom
        self.knobRing = knobRing
        self.letter = letter
        self.size = size
    }
}

public enum DockIconPalette {
    public static let lavoroTop = IconColor(r: 0.16, g: 0.60, b: 0.32)
    public static let lavoroBottom = IconColor(r: 0.08, g: 0.45, b: 0.22)
    public static let personaleTop = IconColor(r: 0.96, g: 0.52, b: 0.10)
    public static let personaleBottom = IconColor(r: 0.86, g: 0.36, b: 0.04)
    public static let neutralTop = IconColor(r: 0.58, g: 0.60, b: 0.63)
    public static let neutralBottom = IconColor(r: 0.44, g: 0.46, b: 0.49)
    public static let busyTop = IconColor(r: 0.98, g: 0.72, b: 0.24)
    public static let busyBottom = IconColor(r: 0.98, g: 0.58, b: 0.12)
    public static let squircleTop = IconColor(r: 0.14, g: 0.16, b: 0.19)
    public static let squircleBottom = IconColor(r: 0.21, g: 0.23, b: 0.27)
    public static let knob = IconColor(r: 1, g: 1, b: 1)
    public static let knobRingNormal = IconColor(r: 0.30, g: 0.33, b: 0.36)
    public static let knobRingEmphasis = IconColor(r: 0.18, g: 0.20, b: 0.22)

    public static func exposedTop(for holder: Holder?) -> IconColor {
        switch holder {
        case .lavoro?: return lavoroTop
        case .personale?: return personaleTop
        case nil: return neutralTop
        }
    }

    public static func exposedBottom(for holder: Holder?) -> IconColor {
        switch holder {
        case .lavoro?: return lavoroBottom
        case .personale?: return personaleBottom
        case nil: return neutralBottom
        }
    }

    public static func knobPosition(for holder: Holder?) -> Double {
        switch holder {
        case .lavoro?: return 1
        case .personale?: return 0
        case nil: return 0.5
        }
    }

    public static func letter(for holder: Holder?) -> IconLetter? {
        switch holder {
        case .lavoro?: return .w
        case .personale?: return .p
        case nil: return nil
        }
    }

    public static func ring(emphasis: Bool) -> IconColor {
        emphasis ? knobRingEmphasis : knobRingNormal
    }
}

public enum DockIconPhase: Sendable, Equatable {
    case rest(holder: Holder?)
    case pulsing(from: Holder?)
    case staticSwitching(from: Holder?)
    case sliding(from: Holder?, to: Holder)
}

public struct DockIconFramePlan: Sendable, Equatable {
    public var phase: DockIconPhase
    public var elapsed: Duration
    public var request: IconRenderRequest

    public init(phase: DockIconPhase, elapsed: Duration, request: IconRenderRequest) {
        self.phase = phase
        self.elapsed = elapsed
        self.request = request
    }
}

public struct DockIconStep: Sendable, Equatable {
    public var next: DockIconPhase
    public var settle: DockIconPhase?

    public init(next: DockIconPhase, settle: DockIconPhase? = nil) {
        self.next = next
        self.settle = settle
    }
}

public enum DockIconRestResolver {
    public static func holder(outcome: TransitionOutcome, current: Location, needsReconcile: Bool) -> Holder? {
        if needsReconcile { return nil }
        return OutcomeStateReducer.actual(after: outcome, current: current).holder
    }
}

public enum DockIconStateMachine {
    public static let pulseFrameCount = 10
    public static let slideFrameCount = 11
    public static let slideDuration = Duration.milliseconds(350)
    public static let slideFrameInterval = Duration.milliseconds(35)
    public static let pulseFrequency = 1.5
    public static let pulseSampleHz = 15
    public static let slideSampleHz = 30

    public static func begin(from: Holder?, reduceMotion: Bool) -> DockIconStep {
        begin(phase: .rest(holder: from), from: from, reduceMotion: reduceMotion)
    }

    public static func begin(phase: DockIconPhase, from: Holder?, reduceMotion: Bool) -> DockIconStep {
        let next: DockIconPhase
        if case .staticSwitching = phase {
            next = .staticSwitching(from: from)
        } else {
            next = reduceMotion ? .staticSwitching(from: from) : .pulsing(from: from)
        }
        var settle: DockIconPhase?
        if case .sliding(_, let to) = phase {
            settle = .rest(holder: to)
        }
        return DockIconStep(next: next, settle: settle)
    }

    public static func showRest(holder: Holder?) -> DockIconStep {
        DockIconStep(next: .rest(holder: holder), settle: nil)
    }

    public static func onOutcome(_ outcome: TransitionOutcome,
                                 phase: DockIconPhase,
                                 current: Location,
                                 needsReconcile: Bool,
                                 reduceMotionCaptured: Bool) -> DockIconStep {
        let rest = DockIconRestResolver.holder(outcome: outcome,
                                               current: current,
                                               needsReconcile: needsReconcile)
        switch phase {
        case .rest:
            return DockIconStep(next: .rest(holder: rest), settle: nil)
        case .pulsing(let from):
            if !reduceMotionCaptured, case .done = outcome.state,
               let target = rest, target != from {
                return DockIconStep(next: .sliding(from: from, to: target), settle: nil)
            }
            return DockIconStep(next: .rest(holder: rest), settle: nil)
        case .staticSwitching:
            return DockIconStep(next: .rest(holder: rest), settle: nil)
        case .sliding:
            return DockIconStep(next: .rest(holder: rest), settle: nil)
        }
    }

    public static func tick(phase: DockIconPhase,
                            elapsed: Duration,
                            reduceMotionCaptured: Bool = false) -> DockIconStep {
        switch phase {
        case .rest(let holder):
            return DockIconStep(next: .rest(holder: holder), settle: nil)
        case .pulsing(let from):
            return DockIconStep(next: .pulsing(from: from), settle: nil)
        case .staticSwitching(let from):
            return DockIconStep(next: .staticSwitching(from: from), settle: nil)
        case .sliding(let from, let to):
            if reduceMotionCaptured || seconds(elapsed) >= 0.35 {
                return DockIconStep(next: .rest(holder: to), settle: nil)
            }
            return DockIconStep(next: .sliding(from: from, to: to), settle: nil)
        }
    }

    public static func frame(phase: DockIconPhase, elapsed: Duration, size: Int) -> DockIconFramePlan {
        let normalizedLetter: (Holder?) -> IconLetter? = { holder in
            size < 32 ? nil : DockIconPalette.letter(for: holder)
        }
        let request: IconRenderRequest
        switch phase {
        case .rest(let holder):
            request = IconRenderRequest(knobPosition: DockIconPalette.knobPosition(for: holder),
                                        exposedTop: DockIconPalette.exposedTop(for: holder),
                                        exposedBottom: DockIconPalette.exposedBottom(for: holder),
                                        knobRing: .normal,
                                        letter: normalizedLetter(holder),
                                        size: size)
        case .pulsing(let from):
            let start = from ?? .lavoro
            let other: Holder = start == .lavoro ? .personale : .lavoro
            let wave = 0.5 * (1 - cos(2 * Double.pi * pulseFrequency * seconds(elapsed)))
            request = IconRenderRequest(
                knobPosition: DockIconPalette.knobPosition(for: from),
                exposedTop: lerp(DockIconPalette.exposedTop(for: start),
                                 DockIconPalette.exposedTop(for: other), wave),
                exposedBottom: lerp(DockIconPalette.exposedBottom(for: start),
                                    DockIconPalette.exposedBottom(for: other), wave),
                knobRing: .normal,
                letter: normalizedLetter(from),
                size: size
            )
        case .staticSwitching(let from):
            request = IconRenderRequest(knobPosition: DockIconPalette.knobPosition(for: from),
                                        exposedTop: DockIconPalette.busyTop,
                                        exposedBottom: DockIconPalette.busyBottom,
                                        knobRing: .emphasis,
                                        letter: normalizedLetter(from),
                                        size: size)
        case .sliding(let from, let to):
            let progress = min(max(seconds(elapsed) / 0.35, 0), 1)
            let eased = progress * progress * (3 - 2 * progress)
            request = IconRenderRequest(
                knobPosition: lerp(DockIconPalette.knobPosition(for: from),
                                   DockIconPalette.knobPosition(for: to), eased),
                exposedTop: DockIconPalette.exposedTop(for: to),
                exposedBottom: DockIconPalette.exposedBottom(for: to),
                knobRing: .normal,
                letter: normalizedLetter(to),
                size: size
            )
        }
        return DockIconFramePlan(phase: phase, elapsed: elapsed, request: request)
    }

    public static func frameIndex(phase: DockIconPhase, elapsed: Duration) -> Int {
        let value = max(seconds(elapsed), 0)
        switch phase {
        case .pulsing:
            return boundedIndex(value * Double(pulseSampleHz)) % pulseFrameCount
        case .sliding:
            return min(boundedIndex(value / 0.035), slideFrameCount - 1)
        case .rest, .staticSwitching:
            return 0
        }
    }

    private static func boundedIndex(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        return Int(value)
    }

    private static func lerp(_ a: IconColor, _ b: IconColor, _ t: Double) -> IconColor {
        let clamped = min(max(t, 0), 1)
        return IconColor(r: a.r + (b.r - a.r) * clamped,
                         g: a.g + (b.g - a.g) * clamped,
                         b: a.b + (b.b - a.b) * clamped,
                         a: a.a + (b.a - a.a) * clamped)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return a + (b - a) * clamped
    }
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) * 1e-18
}
