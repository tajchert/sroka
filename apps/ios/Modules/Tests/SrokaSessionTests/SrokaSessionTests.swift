import Testing

@testable import SrokaSession

struct SrokaSessionTests {
    @Test func `Module is linked`() {
        #expect(SrokaSessionModule.name == "SrokaSession")
    }
}
