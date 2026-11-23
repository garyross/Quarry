import Foundation
import Testing
@testable import QuarryKit

struct BitValueTests {
    @Test func formsOfOneValue() {
        let value = BitValue(width: 8, data: Data([0b0000_0101]))
        #expect(value.raw == 5)
        #expect(value.bits == "00000101")
        #expect(value.hex == "5")
        #expect(value.decimal == "5")
        #expect(value.octal == "5")
        #expect(value.data == Data([5]))
    }

    @Test(arguments: [1, 2, 7, 8, 9, 12, 16, 31, 32, 33, 63, 64])
    func everyWidthRoundTrips(width: Int) {
        let top = BitValue(width: width, raw: .max)
        let maximum: UInt64 = width == 64 ? .max : (UInt64(1) << UInt64(width)) - 1
        #expect(top.raw == maximum)
        #expect(top.bits == String(repeating: "1", count: width))
        #expect(top.data.count == (width + 7) / 8)
        #expect(BitValue(width: width, data: top.data) == top)
        // Each base reads back what it prints.
        #expect(top.parse(top.hex, radix: 16) == top.raw)
        #expect(top.parse(top.decimal, radix: 10) == top.raw)
        #expect(top.parse(top.octal, radix: 8) == top.raw)
        #expect(top.parse(top.bits, radix: 2) == top.raw)
        // One more than the field holds does not fit.
        if width < 64 {
            #expect(top.parse(String(top.raw + 1), radix: 10) == nil)
        }
    }

    @Test func sixtyFourBits() {
        let value = BitValue(width: 64, raw: 0x8000_0000_0000_0001)
        #expect(value.data == Data([0x80, 0, 0, 0, 0, 0, 0, 1]))
        #expect(value.hex == "8000000000000001")
        #expect(value.decimal == "9223372036854775809")
        #expect(value.octal == "1000000000000000000001")
        #expect(value.parse("18446744073709551615", radix: 10) == .max)
        #expect(value.parse("18446744073709551616", radix: 10) == nil)
    }

    @Test func parsingTypedText() {
        let value = BitValue(width: 8)
        #expect(value.parse("0xff", radix: 16) == 255)
        #expect(value.parse("FF", radix: 16) == 255)
        #expect(value.parse("1 0000", radix: 2) == 16)
        #expect(value.parse("0o17", radix: 8) == 15)
        #expect(value.parse("256", radix: 10) == nil)
        #expect(value.parse("12a", radix: 10) == nil)
        #expect(value.parse("9", radix: 8) == nil)
        #expect(value.parse("", radix: 10) == nil)
        #expect(value.parse("-1", radix: 10) == nil)
    }

    @Test func shiftsAndRotations() {
        var value = BitValue(width: 4, raw: 0b1001)
        value.shiftLeft()
        #expect(value.bits == "0010")
        value = BitValue(width: 4, raw: 0b1001)
        value.shiftRight()
        #expect(value.bits == "0100")
        value = BitValue(width: 4, raw: 0b1001)
        value.rotateLeft()
        #expect(value.bits == "0011")
        value = BitValue(width: 4, raw: 0b1001)
        value.rotateRight()
        #expect(value.bits == "1100")
        value.invert()
        #expect(value.bits == "0011")
        value.setAll()
        #expect(value.raw == 15)
        value.clearAll()
        #expect(value.raw == 0)
        value.toggle(3)
        value.toggle(9)
        #expect(value.bits == "1000")
        var wide = BitValue(width: 64, raw: 1 << 63)
        wide.rotateLeft()
        #expect(wide.raw == 1)
        wide.rotateRight()
        #expect(wide.raw == 1 << 63)
    }

    @Test func cellsAndWidths() {
        #expect(BitValue(width: 8, value: .text("b'101'")).raw == 5)
        #expect(BitValue(width: 8, value: .text("0x1F")).raw == 31)
        #expect(BitValue(width: 8, value: .text("7")).raw == 7)
        #expect(BitValue(width: 8, value: .null).raw == 0)
        #expect(BitValue(width: 4, value: .binary(Data([0xFF]))).raw == 15)
        #expect(BitValue.width(fromLength: "8") == 8)
        #expect(BitValue.width(fromLength: "") == 1)
        #expect(BitValue.width(fromLength: "99") == 64)
        #expect(BitValue(width: 12, raw: 0xABC).data == Data([0x0A, 0xBC]))
    }
}
