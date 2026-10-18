import UIKit

/// Text editing belongs to UIKit; business state remains in the existing Chat.
@available(iOS 26.0, *)
final class NativeComposerView: UIView, UITextViewDelegate {
    let editor = UITextView()
    private let placeholder = UILabel()
    private let actions = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    private var placeholderTop: NSLayoutConstraint!
    private var applying = false
    private var revision = 0
    private var conversationID = ""
    private var streaming = false
    private(set) var generation = ""
    var measuredHeight: CGFloat { heightConstraint.constant }
    var onEvent: (([String: Any]) -> Void)?
    var onHeightChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "native-chat-composer"
        let material = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        material.cornerConfiguration = .corners(radius: .fixed(22))
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        editor.backgroundColor = .clear
        editor.textColor = .label
        editor.font = NativeTypography.font(size: 14)
        editor.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        editor.textContainer.lineFragmentPadding = 0
        editor.delegate = self
        editor.accessibilityIdentifier = "native-chat-input"
        editor.accessibilityLabel = "message..."
        editor.isScrollEnabled = false
        placeholder.text = "message..."
        placeholder.font = editor.font
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        actions.tintColor = .label
        send.tintColor = .label
        actions.accessibilityLabel = "Open input actions"
        actions.accessibilityIdentifier = "native-actions"
        actions.addTarget(self, action: #selector(openActions), for: .touchUpInside)
        send.accessibilityIdentifier = "native-send"
        send.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        for child in [actions, editor, send] {
            child.translatesAutoresizingMaskIntoConstraints = false
            material.contentView.addSubview(child)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(placeholder)
        heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        placeholderTop = placeholder.topAnchor.constraint(equalTo: editor.topAnchor, constant: 10)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor), material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor), material.bottomAnchor.constraint(equalTo: bottomAnchor),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            actions.widthAnchor.constraint(equalToConstant: 44), actions.heightAnchor.constraint(equalToConstant: 44),
            send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), send.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            send.widthAnchor.constraint(equalToConstant: 44), send.heightAnchor.constraint(equalToConstant: 44),
            editor.leadingAnchor.constraint(equalTo: actions.trailingAnchor, constant: 2), editor.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -2),
            editor.topAnchor.constraint(equalTo: topAnchor), editor.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor), placeholderTop,
            heightConstraint
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        applying = true
        editor.resignFirstResponder()
        editor.text = ""
        conversationID = ""
        revision = 0
        generation = ""
        applying = false
    }

    func apply(_ state: [String: Any]) {
        applying = true
        defer { applying = false }
        let nextID = state["conversationId"] as? String ?? ""
        let nextGeneration = state["generation"] as? String ?? ""
        let switched = nextID != conversationID || generation != nextGeneration
        if switched {
            editor.resignFirstResponder()
            conversationID = nextID; generation = nextGeneration; revision = 0
            editor.text = state["draft"] as? String ?? ""
        }
        overrideUserInterfaceStyle = state["appearance"] as? String == "dark" ? .dark : .light
        let size = max(10, min(32, (state["fontSize"] as? CGFloat) ?? 14))
        if editor.font?.pointSize != size { editor.font = NativeTypography.font(size: size) }
        placeholder.font = editor.font
        editor.keyboardAppearance = overrideUserInterfaceStyle == .dark ? .dark : .light
        tintColor = .label
        streaming = state["streaming"] as? Bool ?? false
        if let icons = state["icons"] as? [String: String] {
            if let image = NativeArtwork.image(icons["send"]) { send.setImage(image, for: .normal) }
            if let image = NativeArtwork.image(icons["attach"]) { actions.setImage(image, for: .normal) }
        }
        send.accessibilityLabel = streaming ? "Stop response" : "Send message"
        send.isEnabled = streaming || state["ready"] as? Bool == true
        actions.accessibilityValue = state["menuOpen"] as? Bool == true ? "expanded" : "collapsed"
        let ack = state["ack"] as? Int ?? -1
        if ack >= revision, editor.markedTextRange == nil, let text = state["draft"] as? String, text != editor.text {
            do {
                editor.text = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        updateHeight()
    }

    func focus(_ state: [String: Any]) {
        guard state["generation"] as? String == generation, editor.markedTextRange == nil,
              state["conversationId"] as? String == conversationID,
              (state["ack"] as? Int ?? -1) >= revision, let text = state["text"] as? String else { return }
        applying = true
        editor.text = text
        editor.selectedRange = NSRange(location: min((text as NSString).length, max(0, state["cursor"] as? Int ?? 0)), length: 0)
        applying = false
        editor.becomeFirstResponder()
        emit("change")
        updateHeight()
    }

    override func layoutSubviews() { super.layoutSubviews(); updateHeight() }

    private func updateHeight() {
        placeholder.isHidden = !editor.text.isEmpty
        guard editor.bounds.width > 0 else { return }
        let measured = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
        let textHeight = max(editor.font?.lineHeight ?? 18, measured - editor.textContainerInset.top - editor.textContainerInset.bottom)
        let needed = textHeight + 20
        let height = min(160, max(44, ceil(needed)))
        let inset = max(10, (height - textHeight) / 2)
        if abs(editor.textContainerInset.top - inset) > 0.1 {
            editor.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        }
        placeholderTop.constant = inset
        editor.isScrollEnabled = needed > 160
        if abs(heightConstraint.constant - height) > 0.5 {
            heightConstraint.constant = height
            onHeightChange?()
        }
    }

    private func emit(_ kind: String) {
        guard !applying else { return }
        revision += 1
        let selection = editor.selectedRange
        onEvent?(["generation": generation, "kind": kind, "conversationId": conversationID, "revision": revision,
                  "text": editor.text ?? "", "start": selection.location, "end": NSMaxRange(selection)])
    }
    func textViewDidChange(_ textView: UITextView) { emit("change"); updateHeight() }
    func textViewDidChangeSelection(_ textView: UITextView) {
        // Selection can precede didChange. Include the current text in the same
        // event so acknowledgements can never replay an older React draft.
        emit("change")
    }
    func textViewDidEndEditing(_ textView: UITextView) { emit("change") }
    @objc private func openActions() { emit("actions") }
    @objc private func sendMessage() {
        editor.unmarkText()
        emit(streaming ? "stop" : "send")
    }
}
