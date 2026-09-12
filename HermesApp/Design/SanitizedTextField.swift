import SwiftUI
import UIKit

/// A field whose contents are rewritten as they are typed, matching the desktop's `SanitizedInput`.
///
/// A `UIViewRepresentable` because `shouldChangeCharactersIn` is the only place the rule can be enforced: writing back in `onChange` restarts the edit session and drops keystrokes, and sanitising in a `Binding` setter is ignored by the live `UITextField`'s own buffer.
public struct SanitizedTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let style: HermesTextStyle
    let textColor: Color
    let placeholderColor: Color
    let sanitize: (String) -> String
    var onSubmit: (() -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String,
        style: HermesTextStyle = HermesFont.code,
        textColor: Color,
        placeholderColor: Color,
        sanitize: @escaping (String) -> String,
        onSubmit: (() -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.style = style
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.sanitize = sanitize
        self.onSubmit = onSubmit
    }

    public func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.adjustsFontForContentSizeCategory = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return field
    }

    public func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.font = Self.uiFont(for: style)
        field.textColor = UIColor(textColor)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor(placeholderColor),
                .font: Self.uiFont(for: style),
            ]
        )
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The type rung, scaled for Dynamic Type; the builder lives on `HermesTextStyle` and is shared with the transcript's selectable text.
    private static func uiFont(for style: HermesTextStyle) -> UIFont {
        style.uiFont
    }

    public final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SanitizedTextField

        init(parent: SanitizedTextField) {
            self.parent = parent
        }

        public func textField(
            _ field: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = field.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let proposed = current.replacingCharacters(in: swiftRange, with: string)
            let clean = parent.sanitize(proposed)
            guard clean != proposed else { return true }

            // Anchor the caret to the untouched tail, not to a sanitised length of the insertion, which is wrong at a boundary where a lone space sanitises to nothing.
            field.text = clean
            let tailLength = current.utf16.count - range.location - range.length
            let caret = max(0, clean.utf16.count - max(0, tailLength))
            if let position = field.position(from: field.beginningOfDocument, offset: caret) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
            parent.text = clean
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        public func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            parent.onSubmit?()
            return false
        }
    }
}
