import SwiftUI

public struct AIGlowRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    fileprivate func normalized() -> AIGlowRGBA {
        AIGlowRGBA(
            red: Self.clampUnit(red),
            green: Self.clampUnit(green),
            blue: Self.clampUnit(blue),
            alpha: Self.clampUnit(alpha)
        )
    }

    fileprivate var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }
}

public struct AIGlowGradientStop: Equatable, Sendable {
    public let location: Double
    public let color: AIGlowRGBA

    public init(location: Double, color: AIGlowRGBA) {
        self.location = location
        self.color = color
    }

    public init(location: Double, hex: UInt32, alpha: Double = 1) {
        self.init(location: location, color: AIGlowRGBA(hex: hex, alpha: alpha))
    }
}

public struct AIGlowPalette: Equatable, Sendable {
    public struct Variant: Equatable, Sendable {
        public let ringStops: [AIGlowGradientStop]
        public let auraStops: [AIGlowGradientStop]

        public init(ringStops: [AIGlowGradientStop], auraStops: [AIGlowGradientStop]) {
            self.ringStops = ringStops
            self.auraStops = auraStops
        }
    }

    public let name: String
    public let light: Variant
    public let dark: Variant?

    public init(name: String, light: Variant, dark: Variant? = nil) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    public func resolved(for colorScheme: ColorScheme) -> Variant {
        if colorScheme == .dark, let dark {
            return dark
        }
        return light
    }

    public func normalized() -> AIGlowPalette {
        let baseline = AIGlowPalette.default
        let normalizedLight = Variant(
            ringStops: Self.normalizeStops(light.ringStops, fallback: baseline.light.ringStops),
            auraStops: Self.normalizeStops(light.auraStops, fallback: baseline.light.auraStops)
        )
        let normalizedDark: Variant?
        if let dark {
            normalizedDark = Variant(
                ringStops: Self.normalizeStops(dark.ringStops, fallback: normalizedLight.ringStops),
                auraStops: Self.normalizeStops(dark.auraStops, fallback: normalizedLight.auraStops)
            )
        } else {
            normalizedDark = nil
        }
        return AIGlowPalette(name: name, light: normalizedLight, dark: normalizedDark)
    }

    public static let appleDefault: AIGlowPalette = {
        let ringHex: [UInt32] = [
            0xFF6778, 0xFFBA71, 0x8D99FF, 0xF5B9EA, 0xFF6778
        ]
        let auraHex: [UInt32] = [
            0xA0414B, 0xA07749, 0x5A6299, 0x9E7296, 0xA0414B
        ]
        let variant = Variant(
            ringStops: Self.evenStops(hexes: ringHex),
            auraStops: Self.evenStops(hexes: auraHex)
        )
        return AIGlowPalette(name: "Apple Default", light: variant)
    }()

    public static let whatsAppGreen: AIGlowPalette = {
        let ringHexLight: [UInt32] = [
            0x25D366, 0x6EE6B0, 0x34B7F1, 0x00B4D8, 0x2ECC71, 0x25D366
        ]
        let auraHexLight: [UInt32] = [
            0x1D8A55, 0x46B98A, 0x2A7FA1, 0x1B7396, 0x249E67, 0x1D8A55
        ]
        let ringHexDark: [UInt32] = [
            0x1FB85B, 0x35D58B, 0x2CA0D1, 0x0C87B8, 0x23B96B, 0x1FB85B
        ]
        let auraHexDark: [UInt32] = [
            0x0F5A37, 0x1F7A59, 0x17607D, 0x13526F, 0x1A6A4A, 0x0F5A37
        ]
        let light = Variant(
            ringStops: Self.evenStops(hexes: ringHexLight),
            auraStops: Self.evenStops(hexes: auraHexLight)
        )
        let dark = Variant(
            ringStops: Self.evenStops(hexes: ringHexDark),
            auraStops: Self.evenStops(hexes: auraHexDark)
        )
        return AIGlowPalette(name: "WhatsApp Green", light: light, dark: dark)
    }()

    public static let `default` = appleDefault

    public static var ringColors: [Color] {
        Self.default.light.ringStops.map { $0.color.swiftUIColor }
    }

    public static var auraColors: [Color] {
        Self.default.light.auraStops.map { $0.color.swiftUIColor }
    }

    public func ringColors(for colorScheme: ColorScheme) -> [Color] {
        resolved(for: colorScheme).ringStops.map { $0.color.swiftUIColor }
    }

    public func auraColors(for colorScheme: ColorScheme) -> [Color] {
        resolved(for: colorScheme).auraStops.map { $0.color.swiftUIColor }
    }

    public func ringGradientStops(for colorScheme: ColorScheme) -> [Gradient.Stop] {
        resolved(for: colorScheme).ringStops.map {
            Gradient.Stop(color: $0.color.swiftUIColor, location: $0.location)
        }
    }

    public func auraGradientStops(for colorScheme: ColorScheme) -> [Gradient.Stop] {
        resolved(for: colorScheme).auraStops.map {
            Gradient.Stop(color: $0.color.swiftUIColor, location: $0.location)
        }
    }
}

private extension AIGlowPalette {
    static func evenStops(hexes: [UInt32]) -> [AIGlowGradientStop] {
        guard !hexes.isEmpty else { return [] }
        let count = max(hexes.count - 1, 1)
        return hexes.enumerated().map { index, hex in
            let location = Double(index) / Double(count)
            return AIGlowGradientStop(location: location, hex: hex)
        }
    }

    static func normalizeStops(_ stops: [AIGlowGradientStop], fallback: [AIGlowGradientStop]) -> [AIGlowGradientStop] {
        // TODO(§11.1): Decide min/max supported stop count (closure via harness).
        // TODO(§11.1): Decide deterministic tie-break for duplicate locations (closure via harness).
        // TODO(§11.1): Decide strategy for synthesizing missing boundary stops (closure via harness).
        // TODO(§11.1): Decide strategy for reducing oversized stop sets (closure via harness).

        let normalized: [(index: Int, stop: AIGlowGradientStop)] = stops.enumerated().compactMap { index, stop in
            guard stop.location.isFinite else { return nil }
            let clampedLocation = max(0, min(stop.location, 1))
            let clampedColor = stop.color.normalized()
            return (index, AIGlowGradientStop(location: clampedLocation, color: clampedColor))
        }

        guard !normalized.isEmpty else { return fallback }

        let sorted = normalized.sorted { lhs, rhs in
            if lhs.stop.location == rhs.stop.location {
                return lhs.index < rhs.index
            }
            return lhs.stop.location < rhs.stop.location
        }

        return sorted.map { $0.stop }
    }
}

#if canImport(AppKit)
import AppKit

public extension AIGlowPalette {
    static var menuBadgeImage: NSImage {
        let colors = Self.default.light.ringStops.map { $0.color.nsColor }
        return NSImage.aiGlowBadge(colors: colors)
    }
}

private extension AIGlowRGBA {
    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
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
#endif
