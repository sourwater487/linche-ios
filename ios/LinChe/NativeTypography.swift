import UIKit
import CoreText

/// The same unmodified KingHwaOldSong 3.0 used by the global web stylesheet.
enum NativeTypography {
    private static let registered: Void = {
        if let url = Bundle.main.url(forResource: "KingHwaOldSong", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func font(size: CGFloat, bold: Bool = false) -> UIFont {
        _ = registered
        let base = UIFont(name: "KingHwaOldSong", size: size) ?? UIFont.systemFont(ofSize: size)
        if bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
