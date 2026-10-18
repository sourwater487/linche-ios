import UIKit
import WebKit

final class LinCheWebView: WKWebView {
    var nativeHitTest: ((CGPoint) -> Bool)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if nativeHitTest?(point) == true { return nil }
        return super.hitTest(point, with: event)
    }
    // WKWebView forwards its input accessory to the focused web form control.
    // Removing it does not remove the keyboard's predictive text / IME row.
    override var inputAccessoryView: UIView? { nil }
}
