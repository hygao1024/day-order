import AppKit

final class CalendarTimelineScrollView: NSScrollView {
    #if DEBUG
    var wheelEvents = 0
    #endif
    var onActivity: (() -> Void)?
    var onPause: (() -> Void)?
    private(set) var gestureActive = false

    override func scrollWheel(with event: NSEvent) {
        #if DEBUG
        wheelEvents += 1
        #endif
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
