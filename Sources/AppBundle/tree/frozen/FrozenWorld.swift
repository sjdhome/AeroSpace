struct FrozenWorld: Codable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>
    /// Only used by the persisted world, see persistedWorld.swift. The closed windows cache doesn't restore the focus
    var focusedWindowId: UInt32? = nil
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    var result = [UInt32]()
    for child in node.children {
        result += collectAllWindowIdsRecursive(child)
    }
    return result
}

/// Replaying markAsMostRecentChild over the returned windows in order rebuilds the MRU order of every node in the subtree
@MainActor func mruReplayOrder(_ node: TreeNode) -> [UInt32] {
    if let window = node as? Window { return [window.windowId] }
    let mru = Array(node.mruChildren) // Most recent first
    let neverMarked = node.children.filter { child in !mru.contains { $0 === child } }
    return (neverMarked + mru.reversed()).flatMap { mruReplayOrder($0) }
}
