import Testing

@testable import SrokaContent

struct SrokaContentTests {
    @Test func `Module is linked`() {
        #expect(SrokaContentModule.name == "SrokaContent")
    }
}
