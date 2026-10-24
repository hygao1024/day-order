import AppKit

final class CalendarTimelineScrollView: NSScrollView {
    var onActivity: (() -> Void)?
    var onPause: (() -> Void)?
    private(set) var gestureActive = false

    override func scrollWheel(with event: NSEvent) {
        onActivity?()
        if !event.momentumPhase.isEmpty {
            gestureActive = event.momentumPhase.intersection([.ended, .cancelled]).isEmpty
        } else if !event.phase.isEmpty {
            gestureActive = event.phase.intersection([.ended, .cancelled]).isEmpty
        } else {
            gestureActive = false
        }
        super.scrollWheel(with: event)
        if !gestureActive { onPause?() }
    }
}
