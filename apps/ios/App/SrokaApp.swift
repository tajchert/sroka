import SwiftUI

@main
struct SrokaApp: App {
    init() {
        AppComposition.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
