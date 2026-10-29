import AppKit
import Common

// Keeps the whole layout across an AeroSpace restart. Local debug-focus-jump-on-mouse-click branch only.
// On termination (menu Quit or SIGTERM) the world is written to persistedWorldUrl.
// On the next startup it is restored with the same code as the closed windows cache, plus the focus.
// The file is renamed to *.restored before it is used, so it is applied at most once.
// Files older than persistedWorldMaxAge are ignored, e.g. a world written at logout and read at the next login.

private let persistedWorldMaxAge: TimeInterval = 10 * 60

private var persistedWorldUrl: URL {
    let env = ProcessInfo.processInfo.environment
    let stateHome = env["XDG_STATE_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state")
    return stateHome.appending(path: "aerospace/focus-jump-debug/world.json")
}

@MainActor func persistWorldForRestart() {
    let world = freezeWorldForPersisting()
    do {
        let url = persistedWorldUrl
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(world).write(to: url, options: .atomic)
        focusDebugLog.notice("persistedWorld saved windows=\(world.windowIds.count, privacy: .public)")
    } catch {
        focusDebugLog.error("persistedWorld save failed: \(String(describing: error), privacy: .public)")
    }
}

/// Returns true if a persisted world was restored
@MainActor func restorePersistedWorldIfExists() async throws -> Bool {
    let url = persistedWorldUrl
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
          let data = try? Data(contentsOf: url)
    else { return false }
    let used = url.appendingPathExtension("restored")
    try? FileManager.default.removeItem(at: used)
    try? FileManager.default.moveItem(at: url, to: used)
    if let modified = attrs[.modificationDate] as? Date, modified.distance(to: .now) > persistedWorldMaxAge {
        focusDebugLog.notice("persistedWorld ignored, too old: \(modified.description, privacy: .public)")
        return false
    }
    let world: FrozenWorld
    do {
        world = try JSONDecoder().decode(FrozenWorld.self, from: data)
    } catch {
        focusDebugLog.error("persistedWorld decode failed: \(String(describing: error), privacy: .public)")
        return false
    }
    try await applyPersistedWorld(world)
    let missing = world.windowIds.filter { Window.get(byId: $0) == nil }
    focusDebugLog.notice("persistedWorld restored windows=\(world.windowIds.count, privacy: .public) missing=\(missing.count, privacy: .public)")
    for workspace in Workspace.all where !workspace.isEffectivelyEmpty {
        focusDebugLog.notice("persistedWorld restored ws=\(workspace.name, privacy: .public) \(fdMru(workspace), privacy: .public)")
    }
    return true
}

@MainActor func freezeWorldForPersisting() -> FrozenWorld {
    let allWs = Workspace.all
    var world = FrozenWorld(
        workspaces: allWs.map { FrozenWorkspace($0) },
        monitors: monitorInfos.map(FrozenMonitor.init),
        windowIds: allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet(),
    )
    world.focusedWindowId = focus.windowOrNil?.windowId
    return world
}

@MainActor func applyPersistedWorld(_ world: FrozenWorld) async throws {
    try await restoreFrozenWorld(world, skipMissingWindows: true)
    if let id = world.focusedWindowId {
        _ = Window.get(byId: id)?.focusWindow()
    }
}

@MainActor private var sigtermSource: (any DispatchSourceSignal)? = nil

/// SIGTERM goes through the same termination handler as the menu Quit, so that `kill -TERM` persists the world
@MainActor func interceptSigtermForPersistedWorld() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            terminationHandler?.beforeTermination()
            terminateApp()
        }
    }
    source.resume()
    sigtermSource = source
}
