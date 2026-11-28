import SwiftUI

/// Keel's two-sail mark. Its own file so the Home Screen widget can draw it too.
struct KeelMark: View {
    var body: some View {
        ZStack {
            Sail(rust: true).fill(LinearGradient(colors: [Color(red: 143.0 / 255.0, green: 66.0 / 255.0, blue: 36.0 / 255.0),
                                                         Color(red: 240.0 / 255.0, green: 148.0 / 255.0, blue: 103.0 / 255.0)],
                                                startPoint: .leading, endPoint: .trailing))
            Sail(rust: false).fill(LinearGradient(colors: [Color(red: 118.0 / 255.0, green: 223.0 / 255.0, blue: 194.0 / 255.0),
                                                          Color(red: 33.0 / 255.0, green: 122.0 / 255.0, blue: 101.0 / 255.0)],
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
