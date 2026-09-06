import AppKit
import Foundation
import SwiftUI

public struct DigitSteppingEdit: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
}

public enum DigitSteppingText {
    public static func applying(
        direction: Int,
        to text: String,
        selection: NSRange
    ) -> DigitSteppingEdit? {
        guard direction == -1 || direction == 1,
              !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains("e"), !text.contains("E") else { return nil }
        let characters = Array(text)
        guard characters.count == text.utf16.count,
              selection.location >= 0,
              selection.length >= 0,
              selection.location + selection.length <= characters.count else { return nil }
        let separators = characters.indices.filter {
            characters[$0] == "." || characters[$0] == ","
        }
        guard separators.count <= 1 else { return nil }
        let decimalIndex = separators.first
        let fractionDigits = decimalIndex.map { characters.count - $0 - 1 } ?? 0
        guard characters.enumerated().allSatisfy({ index, character in
            character.isNumber
                || (index == 0 && (character == "-" || character == "+"))
                || decimalIndex == index
        }) else { return nil }

        let selectsAll = selection.location == 0 && selection.length == characters.count
        let exponent: Int
        if selectsAll {
            exponent = fractionDigits > 0 ? -fractionDigits : 0
        } else {
            guard selection.length == 0, selection.location > 0 else { return nil }
            let digitIndex = selection.location - 1
            guard characters[digitIndex].isNumber else { return nil }
            if let decimalIndex {
                exponent = digitIndex < decimalIndex
                    ? decimalIndex - digitIndex - 1
                    : decimalIndex - digitIndex
            } else {
                exponent = characters.count - digitIndex - 1
            }
        }

        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(
            string: normalized, locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        var magnitude = Decimal(1)
        if exponent >= 0 {
            for _ in 0..<exponent { magnitude *= 10 }
        } else {
            for _ in 0..<(-exponent) { magnitude /= 10 }
        }
        let result = value + Decimal(direction) * magnitude
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.maximumIntegerDigits = 100
        guard var resultText = formatter.string(from: NSDecimalNumber(decimal: result)) else {
            return nil
        }
        if decimalIndex != nil, characters[decimalIndex!] == "," {
            resultText = resultText.replacingOccurrences(of: ".", with: ",")
        }

        if selectsAll {
            return DigitSteppingEdit(
                text: resultText,
                selection: NSRange(location: 0, length: resultText.utf16.count)
            )
        }
        let resultCharacters = Array(resultText)
        let resultDecimal = resultCharacters.firstIndex { $0 == "." || $0 == "," }
        let targetIndex: Int
        if exponent >= 0 {
            targetIndex = (resultDecimal ?? resultCharacters.count) - exponent - 1
        } else {
            guard let resultDecimal else { return nil }
            targetIndex = resultDecimal - exponent
        }
        guard resultCharacters.indices.contains(targetIndex),
              resultCharacters[targetIndex].isNumber else { return nil }
        return DigitSteppingEdit(
            text: resultText,
            selection: NSRange(location: targetIndex + 1, length: 0)
        )
    }
}

public final class DigitSteppingNSTextField: NSTextField, NSTextFieldDelegate {
    public var onTextChange: ((String) -> Void)?
    public var onSubmit: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    public var acceptStep: ((String) -> String?)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        delegate = self
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        isEditable = true
        isSelectable = true
        lineBreakMode = .byClipping
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    public func controlTextDidBeginEditing(_ notification: Notification) {
        onFocusChange?(true)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        onFocusChange?(false)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onTextChange?(currentEditor()?.string ?? stringValue)
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit?()
            return true
        }
        let direction: Int
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            direction = 1
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            direction = -1
        } else {
            return false
        }
        guard let edit = DigitSteppingText.applying(
            direction: direction,
            to: textView.string,
            selection: textView.selectedRange()
        ) else {
            return true
        }
        let accepted: String
        if let acceptStep {
            guard let candidate = acceptStep(edit.text) else {
                NSSound.beep()
                return true
            }
            accepted = candidate
        } else {
            accepted = edit.text
        }
        stringValue = accepted
        textView.string = accepted
        let acceptedSelection: NSRange
        if edit.selection.length > 0 {
            acceptedSelection = NSRange(location: 0, length: accepted.utf16.count)
        } else if accepted == edit.text {
            acceptedSelection = edit.selection
        } else {
            acceptedSelection = NSRange(
                location: min(edit.selection.location, accepted.utf16.count), length: 0
            )
        }
        textView.setSelectedRange(acceptedSelection)
        onTextChange?(accepted)
        return true
    }
}

public struct DigitSteppingTextField: NSViewRepresentable {
    private let prompt: String
    @Binding private var text: String
    private let onSubmit: () -> Void
    private let onFocusChange: (Bool) -> Void
    private let acceptStep: (String) -> String?

    public init(
        _ prompt: String,
        text: Binding<String>,
        onSubmit: @escaping () -> Void = {},
        onFocusChange: @escaping (Bool) -> Void = { _ in },
        acceptStep: @escaping (String) -> String? = { $0 }
    ) {
        self.prompt = prompt
        _text = text
        self.onSubmit = onSubmit
        self.onFocusChange = onFocusChange
        self.acceptStep = acceptStep
    }

    public func makeNSView(context: Context) -> DigitSteppingNSTextField {
        let field = DigitSteppingNSTextField(string: text)
        field.placeholderString = prompt
        configure(field)
        return field
    }

    public func updateNSView(_ field: DigitSteppingNSTextField, context: Context) {
        configure(field)
        let editor = field.currentEditor()
        let displayedText = editor?.string ?? field.stringValue
        if displayedText != text {
            let selection = editor?.selectedRange
            field.stringValue = text
            editor?.string = text
            if let selection {
                editor?.selectedRange = NSRange(
                    location: min(selection.location, text.utf16.count),
                    length: 0
                )
            }
        }
    }

    private func configure(_ field: DigitSteppingNSTextField) {
        field.onTextChange = { text = $0 }
        field.onSubmit = onSubmit
        field.onFocusChange = onFocusChange
        field.acceptStep = acceptStep
    }
}

public protocol DigitSteppingNumericValue: Comparable {
    static func parseDigitStepping(_ text: String) -> Self?
    func formatDigitStepping(fractionDigits: ClosedRange<Int>?) -> String
}

extension Double: DigitSteppingNumericValue {
    public static func parseDigitStepping(_ text: String) -> Double? {
        let value = Double(text.replacingOccurrences(of: ",", with: "."))
        return value?.isFinite == true ? value : nil
    }

    public func formatDigitStepping(fractionDigits: ClosedRange<Int>?) -> String {
        guard let fractionDigits else {
            return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), self)
        }
        return formatted(
            .number.grouping(.never).precision(.fractionLength(fractionDigits))
        )
    }
}

extension Int: DigitSteppingNumericValue {
    public static func parseDigitStepping(_ text: String) -> Int? { Int(text) }
    public func formatDigitStepping(fractionDigits: ClosedRange<Int>?) -> String { String(self) }
}

extension UInt32: DigitSteppingNumericValue {
    public static func parseDigitStepping(_ text: String) -> UInt32? { UInt32(text) }
    public func formatDigitStepping(fractionDigits: ClosedRange<Int>?) -> String { String(self) }
}

public struct DigitSteppingNumberField<Value: DigitSteppingNumericValue>: View {
    private let prompt: String
    @Binding private var value: Value
    private let range: ClosedRange<Value>?
    private let fractionDigits: ClosedRange<Int>?
    @State private var draft: String
    @State private var isFocused = false

    public init(
        _ prompt: String,
        value: Binding<Value>,
        range: ClosedRange<Value>? = nil,
        fractionDigits: ClosedRange<Int>? = nil
    ) {
        self.prompt = prompt
        _value = value
        self.range = range
        self.fractionDigits = fractionDigits
        _draft = State(initialValue: value.wrappedValue.formatDigitStepping(
            fractionDigits: fractionDigits
        ))
    }

    public var body: some View {
        DigitSteppingTextField(
            prompt,
            text: $draft,
            onSubmit: commit,
            onFocusChange: { focused in
                isFocused = focused
                if focused { synchronize() }
                else { commit() }
            },
            acceptStep: acceptStep
        )
        .onChange(of: value) { _, _ in
            if !isFocused { synchronize() }
        }
    }

    private func acceptStep(_ candidate: String) -> String? {
        guard let parsed = Value.parseDigitStepping(candidate) else { return nil }
        let accepted = range.map { min($0.upperBound, max($0.lowerBound, parsed)) } ?? parsed
        let acceptedText = accepted == parsed
            ? candidate
            : accepted.formatDigitStepping(fractionDigits: fractionDigits)
        draft = acceptedText
        if accepted != value { value = accepted }
        return acceptedText
    }

    private func commit() {
        guard let parsed = Value.parseDigitStepping(
            draft.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            synchronize()
            return
        }
        let accepted = range.map { min($0.upperBound, max($0.lowerBound, parsed)) } ?? parsed
        if accepted != value { value = accepted }
        synchronize(with: accepted)
    }

    private func synchronize(with newValue: Value? = nil) {
        draft = (newValue ?? value).formatDigitStepping(fractionDigits: fractionDigits)
    }
}
