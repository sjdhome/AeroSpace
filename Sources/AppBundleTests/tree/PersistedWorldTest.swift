@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class PersistedWorldTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRoundTripRestoresTreeFloatingFocusAndMru() async throws {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        let root = a.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                $0.layout = .accordion
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
            TestWindow.new(id: 4, parent: $0)
        }
        TestWindow.new(id: 5, parent: a.floatingWindowsContainer)
        TestWindow.new(id: 6, parent: b.rootTilingContainer)
        assertTrue(Window.get(byId: 3)!.focusWindow())
        assertTrue(Window.get(byId: 4)!.focusWindow())
        assertTrue(Window.get(byId: 1)!.focusWindow())
        assertTrue(Window.get(byId: 2)!.focusWindow()) // Root MRU: accordion, 1, 4. Accordion MRU: 2, 3
        let expectedLayout = root.layoutDescription

        let json = try JSONEncoder().encode(freezeWorldForPersisting())
        let world = try JSONDecoder().decode(FrozenWorld.self, from: json)

        // Simulate the restart: every window piles up flat on workspace b in the wrong order
        for id: UInt32 in [4, 5, 3, 1, 2] {
            Window.get(byId: id)!.bind(to: b.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        assertTrue(Window.get(byId: 6)!.focusWindow())

        try await applyPersistedWorld(world)

        assertEquals(a.rootTilingContainer.layoutDescription, expectedLayout)
        assertEquals(a.floatingWindows.map(\.windowId), [5])
        assertEquals(b.rootTilingContainer.layoutDescription, .h_tiles([.window(6)]))
        assertEquals(focus.windowOrNil?.windowId, 2)
        // MRU order survives. Without the replay the bind order wins: root MRU 4, accordion, 1
        assertEquals(a.rootTilingContainer.mostRecentWindowRecursive?.windowId, 2)
        Window.get(byId: 2)!.unbindFromParent()
        Window.get(byId: 3)!.unbindFromParent()
        assertEquals(a.rootTilingContainer.mostRecentNonEmptyWindowRecursive?.windowId, 1)
    }

    func testMissingWindowsAreSkipped() async throws {
        let a = Workspace.get(byName: "a")
        a.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        let world = try JSONDecoder().decode(FrozenWorld.self, from: JSONEncoder().encode(freezeWorldForPersisting()))
        Window.get(byId: 2)!.unbindFromParent() // The window is gone after the restart

        try await applyPersistedWorld(world)

        assertEquals(a.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
    }
}
