import SwiftUI
import Testing
import UIKit

@testable import SrokaDesign

struct DesignTests {
    @Test func `Every named colour resolves from the bundle`() {
        for name in SrokaColor.assetNames {
            #expect(UIColor(named: name, in: .module, compatibleWith: nil) != nil, "missing \(name)")
        }
    }

    @Test func `Outfit registers and is available by family name`() {
        #expect(SrokaFont.registerFonts())
        #expect(UIFont.fontNames(forFamilyName: SrokaFont.brandFamily).isEmpty == false)
    }

    @Test func `Reader palettes match Android`() {
        #expect(ReaderPalette.sepia.backgroundHex == "#F3EAD8")
        #expect(ReaderPalette.dark.textHex == "#D9D7D1")
    }
}
