@testable import AppBundle
import XCTest

@MainActor
final class WindowDestructionFocusTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNativeFocusWhenAnotherAppIsFocused() {
        let workspace = Workspace.get(byName: "a")
        assertTrue(mustNativeFocusAfterWindowDestruction(
            focusedAppPid: 2, focusedWorkspace: workspace, deadWindowAppPid: 1, deadWindowWorkspace: workspace,
        ))
    }

    func testNativeFocusWhenNoWindowIsFocused() {
        let workspace = Workspace.get(byName: "a")
        assertTrue(mustNativeFocusAfterWindowDestruction(
            focusedAppPid: nil, focusedWorkspace: workspace, deadWindowAppPid: 1, deadWindowWorkspace: workspace,
        ))
    }

    // https://github.com/nikitabobko/AeroSpace/issues/201
    func testNoNativeFocusWhenSameAppIsFocusedOnDeadWindowWorkspace() {
        let workspace = Workspace.get(byName: "a")
        assertFalse(mustNativeFocusAfterWindowDestruction(
            focusedAppPid: 1, focusedWorkspace: workspace, deadWindowAppPid: 1, deadWindowWorkspace: workspace,
        ))
    }

    // macOS hands the focus to a window of the same app on another workspace, e.g. on another monitor.
    // AeroSpace switches back to the dead window's workspace, so macOS must follow.
    func testNativeFocusWhenSameAppIsFocusedOnAnotherWorkspace() {
        assertTrue(mustNativeFocusAfterWindowDestruction(
            focusedAppPid: 1,
            focusedWorkspace: Workspace.get(byName: "b"),
            deadWindowAppPid: 1,
            deadWindowWorkspace: Workspace.get(byName: "a"),
        ))
    }
}
