import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let notifApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        focusDebugLog.notice("globalNotif name=\(notifName, privacy: .public) app=\(notifApp?.bundleIdentifier ?? "nil", privacy: .public)/\(notifApp?.processIdentifier ?? 0, privacy: .public)")
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { @MainActor event in
            onLeftMouseDown(event.locationInWindow.withYAxisFlipped)
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                let inVisibleRect = clickedMonitor.visibleRect.contains(mouseLocation)
                let frontmost = NSWorkspace.shared.frontmostApplication
                focusDebugLog.notice(
                    "mouseUp loc=\(mouseLocation.debugDescription, privacy: .public) clickedMon=\(clickedMonitor.monitorId_oneBased ?? 0, privacy: .public) clickedMonActiveWs=\(clickedMonitor.activeWorkspace.name, privacy: .public) inVisibleRect=\(inVisibleRect, privacy: .public) focus=\(fdFocus(focus), privacy: .public) frontmost=\(frontmost?.bundleIdentifier ?? "nil", privacy: .public)/\(frontmost?.processIdentifier ?? 0, privacy: .public)",
                )
                let isOtherMonitorClick = inVisibleRect && clickedMonitor.activeWorkspace != focus.workspace
                // A click on a window is left to macOS: the default branch picks the clicked window up from the native focus.
                //  Focusing the workspace instead would focus its MRU window, not the clicked one. The native focus can't be
                //  used to tell the desktop from a window here, because the clicked app is often not frontmost yet at mouse up.
                //  nil (the hit test failed) keeps the workspace switch.
                let isWindowClick = isOtherMonitorClick ? await isAxWindowUnderMouse(mouseLocation) : nil
                focusDebugLog.notice("mouseUp isOtherMonitorClick=\(isOtherMonitorClick, privacy: .public) isWindowClick=\(isWindowClick.map(String.init) ?? "nil", privacy: .public)")
                switch true {
                    // Detect clicks on desktop of different monitors
                    case isOtherMonitorClick && isWindowClick != true:
                        focusDebugLog.notice("mouseUp branch=focusWorkspace ws=\(clickedMonitor.activeWorkspace.name, privacy: .public)")
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            let ws = clickedMonitor.activeWorkspace
                            focusDebugLog.notice(
                                "mouseUp body focusBeforeBody=\(fdFocus(focus), privacy: .public) clickedMonActiveWs=\(ws.name, privacy: .public) \(fdMru(ws), privacy: .public)",
                            )
                            return ws.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        focusDebugLog.notice("mouseUp branch=scheduleRefresh")
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
