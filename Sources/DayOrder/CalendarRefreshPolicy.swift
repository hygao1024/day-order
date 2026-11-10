import AppKit
import QuartzCore

@MainActor enum CalendarRefreshPolicy {
    static let preferenceKey = "preferHighRefreshRate"

    static func apply(to link: CADisplayLink, in view: NSView, enabled: Bool) {
        let maximum = Float(max(1, view.window?.screen?.maximumFramesPerSecond ?? 60))
        let range = enabled
            ? CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            : CAFrameRateRange.default
        let current = link.preferredFrameRateRange
        if current.minimum != range.minimum || current.maximum != range.maximum || current.preferred != range.preferred {
            link.preferredFrameRateRange = range
        }
    }
}

@MainActor final class CalendarDisplayLinkTarget: NSObject {
    let frame: (CADisplayLink) -> Void
    init(frame: @escaping (CADisplayLink) -> Void) { self.frame = frame }
    @objc func tick(_ link: CADisplayLink) { frame(link) }
}
