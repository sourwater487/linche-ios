import UIKit
import CoreText

/// The same unmodified KingHwaOldSong 3.0 used by the global web stylesheet.
enum NativeTypography {
    private static let registered: Void = {
        if let url = Bundle.main.url(forResource: "KingHwaOldSong", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        _ = registered
        let base = UIFont(name: "KingHwaOldSong", size: size) ?? UIFont.systemFont(ofSize: size)
        var descriptor = base.fontDescriptor
        if bold, let boldDescriptor = descriptor.withSymbolicTraits(.traitBold) { descriptor = boldDescriptor }
        // This bundled typeface has no italic face. Transform the glyph font
        // itself so UIKit does not silently substitute an upright face.
        if italic { descriptor = descriptor.withMatrix(CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)) }
        return UIFont(descriptor: descriptor, size: size)
    }
}
