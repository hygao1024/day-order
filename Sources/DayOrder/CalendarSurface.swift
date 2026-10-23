import AppKit
import SwiftUI

enum CalendarSurface {
    static var chrome: some View {
        PopoverMaterial().allowsHitTesting(false).accessibilityHidden(true)
    }
    static let settings = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    })
    static let contentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1) : .white
    }
    static let content = Color(nsColor: contentColor)
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        // 取样窗口后方的桌面，由系统处理模糊、外观和减少透明度偏好。
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
