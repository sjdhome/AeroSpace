import AppKit
import Common
import os

// Temporary diagnostics for the "mouse click on another monitor jumps to the workspace's MRU window" bug.
// Lives only on the local debug-focus-jump-on-mouse-click branch. Remove the branch once the cause is found.
// Read with: /usr/bin/log stream --level info --predicate 'subsystem == "bobko.aerospace.debug" AND category == "focus-debug"'
// Window titles are deliberately not logged.
let focusDebugLog = Logger(subsystem: aeroSpaceAppId, category: "focus-debug")

@MainActor
func fdWin(_ window: Window?) -> String {
    guard let window else { return "nil" }
    let parentKind = window.parent.map { String(describing: type(of: $0)) } ?? "unbound"
    return "\(window.windowId)[\(window.app.rawAppBundleId ?? "?") ws=\(window.nodeWorkspace?.name ?? "-") \(parentKind)]"
}

@MainActor
func fdFocus(_ focus: LiveFocus) -> String {
    "win=\(fdWin(focus.windowOrNil)) ws=\(focus.workspace.name) mon=\(focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0)"
}

var fdEvent: String { refreshSessionEvent.map { "\($0)" } ?? "none" }

@MainActor
func fdMru(_ workspace: Workspace) -> String {
    let chain = workspace.mruChildren.map { child in
        "\(String(describing: type(of: child)))->\(child.mostRecentNonEmptyWindowRecursive?.windowId.description ?? "empty")"
    }
    return "mruChildren=[\(chain.joined(separator: ", "))]" +
        " mostRecent=\(workspace.mostRecentWindowRecursive?.windowId.description ?? "nil")" +
        " mostRecentNonEmpty=\(workspace.mostRecentNonEmptyWindowRecursive?.windowId.description ?? "nil")" +
        " anyLeaf=\(workspace.anyLeafWindowRecursive?.windowId.description ?? "nil")"
}
