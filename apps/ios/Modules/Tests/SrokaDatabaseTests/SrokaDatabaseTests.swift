import Testing

@testable import SrokaDatabase

struct SrokaDatabaseTests {
    @Test func `Module is linked`() {
        #expect(SrokaDatabaseModule.name == "SrokaDatabase")
    }
}
