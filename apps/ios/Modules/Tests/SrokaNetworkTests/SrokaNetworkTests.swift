import Testing

@testable import SrokaNetwork

struct SrokaNetworkTests {
    @Test func `Module is linked`() {
        #expect(SrokaNetworkModule.name == "SrokaNetwork")
    }
}
