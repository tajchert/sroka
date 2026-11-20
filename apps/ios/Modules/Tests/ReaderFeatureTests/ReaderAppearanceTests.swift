import CoreGraphics
import Dependencies
import SrokaCore
import SrokaTesting
import Testing

@testable import ReaderFeature

@MainActor
struct ReaderAppearanceTests {
    private func makeModel(_ fakes: Fakes) -> ReaderAppearanceModel {
        withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ReaderAppearanceModel()
        }
    }

    private func started(_ fakes: Fakes) async -> (ReaderAppearanceModel, Task<Void, Never>) {
        let model = makeModel(fakes)
        let task = Task { await model.observe() }
        for _ in 0..<200 where !model.isLoaded { await Task.yield() }
        return (model, task)
    }

    /// Lets the preferences stream deliver the echo of the last write.
    private func settle(_ model: ReaderAppearanceModel, scale: Double) async {
        for _ in 0..<200 where model.preferences.readerTextScale != scale { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func `Preferences load before the page may be built`() async {
        let fakes = Fakes(preferences: UserPreferences(readerTheme: .dark, readerFont: .serif))
        let model = makeModel(fakes)
        #expect(!model.isLoaded)
        let task = Task { await model.observe() }
        defer { task.cancel() }
        for _ in 0..<200 where !model.isLoaded { await Task.yield() }
        #expect(model.isLoaded)
        #expect(model.preferences.readerTheme == .dark)
        #expect(model.preferences.readerFont == .serif)
    }

    @Test func `Choosing theme, font and spacing applies at once and is stored`() async {
        let fakes = Fakes()
        let (model, task) = await started(fakes)
        defer { task.cancel() }
        await model.themeSelected(.sepia)
        await model.fontSelected(.serif)
        await model.spacingSelected(.tight)
        // The store's own echo of earlier writes may still be in flight; the model converges on the last write.
        for _ in 0..<200 where model.preferences.readerLineSpacing != .tight { await Task.yield() }
        #expect(model.preferences.readerTheme == .sepia)
        #expect(model.preferences.readerFont == .serif)
        #expect(model.preferences.readerLineSpacing == .tight)
        #expect(fakes.settings.state.value.readerTheme == .sepia)
        #expect(fakes.settings.state.value.readerFont == .serif)
        #expect(fakes.settings.state.value.readerLineSpacing == .tight)
    }

    @Test func `Text size has nine steps from 0.8 to 1.6`() {
        #expect(ReaderTextScale.stepCount == 9)
        #expect(ReaderTextScale.scale(at: 0) == 0.8)
        #expect(ReaderTextScale.scale(at: 2) == 1.0)
        #expect(ReaderTextScale.scale(at: 8) == 1.6)
        #expect(ReaderTextScale.scale(at: -3) == 0.8)
        #expect(ReaderTextScale.scale(at: 99) == 1.6)
        let all = (0..<9).map { ReaderTextScale.scale(at: $0) }
        #expect(all == all.sorted())
        #expect(Set(all).count == 9)
    }

    @Test func `A stored scale maps back to its step`() {
        for index in 0..<9 {
            #expect(ReaderTextScale.index(of: ReaderTextScale.scale(at: index)) == index)
        }
        #expect(ReaderTextScale.index(of: 5) == 8)
        #expect(ReaderTextScale.index(of: 0) == 0)
    }

    @Test func `The size stepper moves one step and stops at the ends`() async {
        let fakes = Fakes()
        let (model, task) = await started(fakes)
        defer { task.cancel() }
        let start = ReaderTextScale.index(of: model.preferences.readerTextScale)
        await model.textSizeStepperTapped(direction: 1)
        #expect(ReaderTextScale.index(of: model.preferences.readerTextScale) == start + 1)
        await settle(model, scale: ReaderTextScale.scale(at: start + 1))
        await model.textSizeStepSelected(8)
        await settle(model, scale: 1.6)
        await model.textSizeStepperTapped(direction: 1)
        await settle(model, scale: 1.6)
        #expect(model.preferences.readerTextScale == 1.6)
        #expect(fakes.settings.state.value.readerTextScale == 1.6)
        await model.textSizeStepSelected(0)
        await settle(model, scale: 0.8)
        await model.textSizeStepperTapped(direction: -1)
        await settle(model, scale: 0.8)
        #expect(model.preferences.readerTextScale == 0.8)
    }

    @Test func `The slider position follows the stored scale`() async {
        let fakes = Fakes(preferences: UserPreferences(readerTextScale: 1.2))
        let (model, task) = await started(fakes)
        defer { task.cancel() }
        #expect(model.textSizeStop == 4)
    }
}

struct ScrollDirectionTrackerTests {
    @Test func `Only a clear change of direction is reported`() {
        var tracker = ScrollDirectionTracker()
        #expect(tracker.update(offset: 0, topOffset: 0) == nil)  // first sample: reference only
        #expect(tracker.update(offset: 5, topOffset: 0) == nil)  // inside the dead zone
        #expect(tracker.update(offset: 40, topOffset: 0) == .down)
        #expect(tracker.update(offset: 60, topOffset: 0) == nil)  // still down
        #expect(tracker.update(offset: 30, topOffset: 0) == .up)
        #expect(tracker.update(offset: 20, topOffset: 0) == nil)  // small wiggle
    }

    @Test func `The bars are always shown at the very top`() {
        var tracker = ScrollDirectionTracker()
        _ = tracker.update(offset: 100, topOffset: 0)
        #expect(tracker.update(offset: 160, topOffset: 0) == .down)
        #expect(tracker.update(offset: 0, topOffset: 0) == .up)
    }

    @Test func `The top offset accounts for the safe area`() {
        var tracker = ScrollDirectionTracker()
        _ = tracker.update(offset: -60, topOffset: -60)
        #expect(tracker.update(offset: 30, topOffset: -60) == .down)
        #expect(tracker.update(offset: -60, topOffset: -60) == .up)
    }
}
