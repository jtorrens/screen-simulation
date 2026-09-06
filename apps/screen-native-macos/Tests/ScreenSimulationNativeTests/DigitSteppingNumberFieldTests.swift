import Foundation
import ScreenSimulationMacUI
import Testing

@Test func digitSteppingUsesTheDigitImmediatelyBeforeTheCaret() throws {
    let tens = try #require(DigitSteppingText.applying(
        direction: 1,
        to: "123.45",
        selection: NSRange(location: 2, length: 0)
    ))
    #expect(tens.text == "133.45")
    #expect(tens.selection == NSRange(location: 2, length: 0))

    let tenths = try #require(DigitSteppingText.applying(
        direction: 1,
        to: "123.45",
        selection: NSRange(location: 5, length: 0)
    ))
    #expect(tenths.text == "123.55")
    #expect(tenths.selection == NSRange(location: 5, length: 0))
}

@Test func digitSteppingPreservesPrecisionCarryAndDecimalSeparator() throws {
    let carry = try #require(DigitSteppingText.applying(
        direction: 1,
        to: "99.0",
        selection: NSRange(location: 1, length: 0)
    ))
    #expect(carry.text == "109.0")
    #expect(carry.selection == NSRange(location: 2, length: 0))

    let comma = try #require(DigitSteppingText.applying(
        direction: -1,
        to: "12,30",
        selection: NSRange(location: 5, length: 0)
    ))
    #expect(comma.text == "12,29")
    #expect(comma.selection == NSRange(location: 5, length: 0))
}

@Test func wholeSelectionUsesTheLeastSignificantVisibleDigit() throws {
    let decimal = try #require(DigitSteppingText.applying(
        direction: 1,
        to: "12.300",
        selection: NSRange(location: 0, length: 6)
    ))
    #expect(decimal.text == "12.301")
    #expect(decimal.selection == NSRange(location: 0, length: 6))

    let integer = try #require(DigitSteppingText.applying(
        direction: -1,
        to: "12",
        selection: NSRange(location: 0, length: 2)
    ))
    #expect(integer.text == "11")
    #expect(integer.selection == NSRange(location: 0, length: 2))
}

@Test func ambiguousOrNonDigitSelectionsDoNotStep() {
    #expect(DigitSteppingText.applying(
        direction: 1,
        to: "123.45",
        selection: NSRange(location: 1, length: 2)
    ) == nil)
    #expect(DigitSteppingText.applying(
        direction: 1,
        to: "123.45",
        selection: NSRange(location: 4, length: 0)
    ) == nil)
}
