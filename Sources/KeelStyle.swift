import SwiftUI
import UIKit

/// Current Apple device wording so universal iPhone/iPad builds never call an iPad an iPhone.
@MainActor
enum KeelDevice {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var name: String { isPad ? "iPad" : "iPhone" }
    static var uppercaseName: String { name.uppercased() }
    static var symbol: String { isPad ? "ipad" : "iphone" }
}

// Keel visual identity: ink #0A1112, jade #36B394, rust #DC7648, paper #F7F3E9.
enum KeelStyle {
    static let ink = Color(red: 10.0 / 255.0, green: 17.0 / 255.0, blue: 18.0 / 255.0)
    static let jade = Color(red: 54.0 / 255.0, green: 179.0 / 255.0, blue: 148.0 / 255.0)
    static let rust = Color(red: 220.0 / 255.0, green: 118.0 / 255.0, blue: 72.0 / 255.0)
    static let paper = Color(red: 247.0 / 255.0, green: 243.0 / 255.0, blue: 233.0 / 255.0)
    static let background = adaptive(dark: ink, light: paper)
    static let surface = adaptive(dark: Color(red: 16.0 / 255.0, green: 26.0 / 255.0, blue: 28.0 / 255.0), light: .white)
    static let accent = adaptive(dark: Color(red: 118.0 / 255.0, green: 223.0 / 255.0, blue: 194.0 / 255.0),
                                 light: Color(red: 30.0 / 255.0, green: 112.0 / 255.0, blue: 92.0 / 255.0))
    static let detail = adaptive(dark: rust,
                                 light: Color(red: 158.0 / 255.0, green: 71.0 / 255.0, blue: 34.0 / 255.0))
    /// The fill behind what the user wrote.
    static let bubble = adaptive(dark: Color(red: 22.0 / 255.0, green: 36.0 / 255.0, blue: 38.0 / 255.0),
                                 light: Color(red: 0.898, green: 0.918, blue: 0.878))
    /// Thin outlines around cards and the composer.
    static let hairline = accent.opacity(0.18)
    static let cardRadius: CGFloat = 16
    static let bubbleRadius: CGFloat = 20

    /// Navigation and toolbars in Keel's own colours rather than the system's
    /// grey, so every sheet matches the menu: ink behind, no hairline.
    static func applyBarAppearance() {
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(background)
        bar.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        let tools = UIToolbarAppearance()
        tools.configureWithOpaqueBackground()
        tools.backgroundColor = UIColor(background)
        tools.shadowColor = .clear
        UIToolbar.appearance().standardAppearance = tools
        UIToolbar.appearance().scrollEdgeAppearance = tools
    }

    private static func adaptive(dark: Color, light: Color) -> Color {
        Color(uiColor: UIColor { traits in UIColor(traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

