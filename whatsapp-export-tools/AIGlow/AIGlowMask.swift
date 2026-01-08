import SwiftUI

/// Shape helpers for matching glow geometry to control bounds.
struct AIGlowMask {
    static func roundedRect(cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}
