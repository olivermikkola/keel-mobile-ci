import SwiftUI

// Keel visual identity: jade #709C8F, rust #B66E4F, ink #101A1C, paper #F7F3E9.
enum KeelStyle {
    static let ink = Color(red: 16.0 / 255.0, green: 26.0 / 255.0, blue: 28.0 / 255.0)
    static let jade = Color(red: 112.0 / 255.0, green: 156.0 / 255.0, blue: 143.0 / 255.0)
    static let rust = Color(red: 182.0 / 255.0, green: 110.0 / 255.0, blue: 79.0 / 255.0)
    static let paper = Color(red: 247.0 / 255.0, green: 243.0 / 255.0, blue: 233.0 / 255.0)
    static let background = adaptive(dark: ink, light: paper)
    static let surface = adaptive(dark: Color(red: 0.090, green: 0.141, blue: 0.149), light: .white)
    static let accent = adaptive(dark: Color(red: 0.635, green: 0.816, blue: 0.745),
                                 light: Color(red: 0.176, green: 0.365, blue: 0.310))
    static let detail = adaptive(dark: Color(red: 0.827, green: 0.561, blue: 0.408),
                                 light: Color(red: 0.576, green: 0.282, blue: 0.176))

    private static func adaptive(dark: Color, light: Color) -> Color {
        Color(uiColor: UIColor { traits in UIColor(traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

struct KeelMark: View {
    var body: some View {
        ZStack {
            Sail(rust: true).fill(LinearGradient(colors: [Color(red: 97.0 / 255.0, green: 60.0 / 255.0, blue: 48.0 / 255.0), KeelStyle.rust],
                                                startPoint: .leading, endPoint: .trailing))
            Sail(rust: false).fill(LinearGradient(colors: [Color(red: 172.0 / 255.0, green: 208.0 / 255.0, blue: 192.0 / 255.0), KeelStyle.jade],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }

    private struct Sail: Shape {
        let rust: Bool
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 86, y: 426))
            if rust {
                path.addCurve(to: CGPoint(x: 426, y: 391), control1: CGPoint(x: 214, y: 357), control2: CGPoint(x: 316, y: 367))
                path.addLine(to: CGPoint(x: 426, y: 252))
                path.addCurve(to: CGPoint(x: 86, y: 426), control1: CGPoint(x: 418, y: 337), control2: CGPoint(x: 231, y: 336))
            } else {
                path.addLine(to: CGPoint(x: 426, y: 86))
                path.addLine(to: CGPoint(x: 426, y: 252))
                path.addCurve(to: CGPoint(x: 203, y: 367), control1: CGPoint(x: 426, y: 328), control2: CGPoint(x: 304, y: 324))
                path.addCurve(to: CGPoint(x: 86, y: 426), control1: CGPoint(x: 157, y: 386), control2: CGPoint(x: 118, y: 408))
            }
            path.closeSubpath()
            return path.applying(CGAffineTransform(scaleX: rect.width / 512, y: rect.height / 512)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        }
    }
}
