import AppKit
import SwiftUI

enum CalendarSurface {
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
    static let contentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1) : .white
    }
    static let content = Color(nsColor: contentColor)
}
