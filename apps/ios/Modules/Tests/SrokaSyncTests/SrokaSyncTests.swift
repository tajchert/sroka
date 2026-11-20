import Testing

@testable import SrokaSync

struct SrokaSyncTests {
    @Test func `Module is linked`() {
        #expect(SrokaSyncModule.name == "SrokaSync")
    }
}
