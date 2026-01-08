import SwiftUI
import AppKit

/// Palette definitions and helpers for the Apple-Intelligence-style AI glow.
struct AIGlowPaletteDefinition {
    let name: String
    let ringHex: [UInt32]
    let auraHex: [UInt32]
}

enum AIGlowPaletteOption: String, CaseIterable {
    case appleBaseline = "apple-baseline"
    case intelligenceGlow = "intelligence-glow"
    case siriPill = "siri-pill"

    var definition: AIGlowPaletteDefinition {
        switch self {
        case .appleBaseline:
            return AIGlowPaletteDefinition(
                name: "Apple Baseline",
                ringHex: [
                    0x457DE3, 0x646DD2, 0xB46AE9, 0xD672AE, 0xEF869D, 0x457DE3
                ],
                auraHex: [
                    0x24457B, 0x31366C, 0x6E418B, 0x87426F, 0x703448, 0x24457B
                ]
            )
        case .intelligenceGlow:
            return AIGlowPaletteDefinition(
                name: "Intelligence Glow",
                ringHex: [
                    0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xFF6778, 0xFFBA71, 0xC686FF
                ],
                auraHex: [
                    0x5A6299, 0x9E7296, 0xA0414B, 0xA07749, 0x5A6299, 0x9E7296
                ]
            )
        case .siriPill:
            return AIGlowPaletteDefinition(
                name: "Siri Pill",
                ringHex: [
                    0xFF6778, 0xFFBA71, 0x8D99FF, 0xF5B9EA, 0xFF6778
                ],
                auraHex: [
                    0xA0414B, 0xA07749, 0x5A6299, 0x9E7296, 0xA0414B
                ]
            )
        }
    }
}

enum AIGlowPalette {
    static let activeOption: AIGlowPaletteOption = {
        if let raw = ProcessInfo.processInfo.environment["AI_GLOW_PALETTE"],
           let option = AIGlowPaletteOption(rawValue: raw) {
            return option
        }
        return .siriPill
    }()

    static let ringHex: [UInt32] = activeOption.definition.ringHex
    static let auraHex: [UInt32] = activeOption.definition.auraHex
    static let ringColors: [Color] = ringHex.map { Color(hex: $0) }
    static let auraColors: [Color] = auraHex.map { Color(hex: $0) }
    static let ringNSColors: [NSColor] = ringHex.map { NSColor(hex: $0) }
    static let menuBadgeImage: NSImage = .aiGlowBadge(colors: ringNSColors)
    static let paletteName: String = activeOption.definition.name
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}

private extension NSImage {
    static func aiGlowBadge(colors: [NSColor]) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: path, angle: 0)
        } else {
            colors.first?.setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
