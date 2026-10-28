import AppKit
import Common

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])

struct FrozenMonitor: Sendable, Codable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: MonitorInfo) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
    }
}

struct FrozenWorkspace: Sendable, Codable {
    let name: String
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        monitor = FrozenMonitor(workspace.workspaceMonitor)
        rootTilingNode = FrozenContainer(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            workspace.macOsNativeHiddenAppsWindowsContainer.children.map { FrozenWindow($0 as! Window) } +
            workspace.macOsNativeFullscreenWindowsContainer.children.map { FrozenWindow($0 as! Window) }
    }
}

@MainActor func cacheClosedWindowIfNeeded() {
    let allWs = Workspace.all
    let allWindowIds = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
    if allWindowIds.isSubset(of: closedWindowsCache.windowIds) {
        focusDebugLog.notice("closedWindowsCache alreadyCached event=\(fdEvent, privacy: .public) windows=\(allWindowIds.count, privacy: .public)")
        return // already cached
    }
    closedWindowsCache = FrozenWorld(
        workspaces: allWs.map { FrozenWorkspace($0) },
        monitors: monitorInfos.map(FrozenMonitor.init),
        windowIds: allWindowIds,
    )
    focusDebugLog.notice("closedWindowsCache stored event=\(fdEvent, privacy: .public) windows=\(allWindowIds.count, privacy: .public)")
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    if !closedWindowsCache.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    focusDebugLog.notice("closedWindowsCache restore begin event=\(fdEvent, privacy: .public) trigger=\(fdWin(newlyDetectedWindow), privacy: .public) cachedWindows=\(closedWindowsCache.windowIds.count, privacy: .public)")
    try await restoreFrozenWorld(closedWindowsCache, skipMissingWindows: false)
    for workspace in Workspace.all where !workspace.isEffectivelyEmpty {
        focusDebugLog.notice("closedWindowsCache restore end ws=\(workspace.name, privacy: .public) \(fdMru(workspace), privacy: .public)")
    }
    return true
}

/// skipMissingWindows: false stops restoring a container at the first window that isn't registered yet,
///                     to keep the indices of the subsequent windows right (closed windows cache).
///                     true skips missing windows (persisted world, where windows can be gone for good)
@MainActor func restoreFrozenWorld(_ world: FrozenWorld, skipMissingWindows: Bool) async throws {
    let monitors = monitorInfos
    let topLeftCornerToMonitor = monitors.grouped { $0.rect.topLeftCorner }

    for frozenWorkspace in world.workspaces {
        let workspace = Workspace.get(byName: frozenWorkspace.name)
        _ = topLeftCornerToMonitor[frozenWorkspace.monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(workspace)
        for frozenWindow in frozenWorkspace.floatingWindows {
            Window.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        for frozenWindow in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
            Window.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        let prevRoot = workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        restoreTreeRecursive(
            frozenContainer: frozenWorkspace.rootTilingNode,
            parent: workspace,
            index: INDEX_BIND_LAST,
            skipMissingWindows: skipMissingWindows,
        )
        for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
        }
    }

    for monitor in world.monitors {
        _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
}

@discardableResult
@MainActor
private func restoreTreeRecursive(
    frozenContainer: FrozenContainer,
    parent: NonLeafTreeNodeObject,
    index: Int,
    skipMissingWindows: Bool,
) -> Bool {
    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    for (index, child) in frozenContainer.children.enumerated() {
        // With skipMissingWindows, bind at the end so that skipped windows don't leave holes in the indices
        let bindIndex = skipMissingWindows ? INDEX_BIND_LAST : index
        switch child {
            case .window(let w):
                guard let window = Window.get(byId: w.id) else {
                    if skipMissingWindows { continue }
                    // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                    return false
                }
                window.bind(to: container, adaptiveWeight: w.weight, index: bindIndex)
            case .container(let c):
                // There is no reason to continue
                if !restoreTreeRecursive(frozenContainer: c, parent: container, index: bindIndex, skipMissingWindows: skipMissingWindows) {
                    return false
                }
        }
    }
    return true
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to reset the cache every time layout changes. The layout can only be changed by running commands
// and with mouse manipulations
@MainActor func resetClosedWindowsCache() {
    if !closedWindowsCache.windowIds.isEmpty {
        focusDebugLog.notice("closedWindowsCache reset event=\(fdEvent, privacy: .public)")
    }
    closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
}
