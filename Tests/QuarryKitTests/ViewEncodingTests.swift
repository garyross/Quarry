import Testing
@testable import QuarryKit

struct ViewEncodingTests {
    @Test func decodesPerEncoding() {
        let cafeUTF8: [UInt8] = [0x43, 0x61, 0x66, 0xC3, 0xA9]
        #expect(ViewEncoding.utf8ViaLatin1.decode(cafeUTF8) == "Café")
        #expect(ViewEncoding.latin1.decode(cafeUTF8) == "CafÃ©")
        #expect(ViewEncoding.latin1.decode([0x43, 0x61, 0x66, 0xE9]) == "Café")
        #expect(ViewEncoding.utf8mb4.decode([0x43, 0xE9]) == nil)
        #expect(ViewEncoding.macroman.decode([0x8E]) == "é")
        #expect(ViewEncoding.cp1250.decode([0x9A]) == "š")
        #expect(ViewEncoding.greek.decode([0xE1]) == "α")
    }

    @Test func namesAndSending() {
        #expect(ViewEncoding.utf8ViaLatin1.charset == "latin1" && ViewEncoding.cp1250.charset == "cp1250")
        #expect(ViewEncoding.latin1.problem(sending: "SELECT 'é'") != nil)
        #expect(ViewEncoding.latin1.problem(sending: "SELECT 1") == nil)
        #expect(ViewEncoding.utf8ViaLatin1.problem(sending: "SELECT 'é'") == nil)
    }
}
