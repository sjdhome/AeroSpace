@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        focusDebugLog.info("updateFocusCache skipPopup nativeFocused=\(fdWin(nativeFocused), privacy: .public)")
        return
    }
    focusDebugLog.info(
        "updateFocusCache event=\(fdEvent, privacy: .public) nativeFocused=\(fdWin(nativeFocused), privacy: .public) lastKnownNative=\(lastKnownNativeFocusedWindowId?.description ?? "nil", privacy: .public) willTakeFocus=\(nativeFocused?.windowId != lastKnownNativeFocusedWindowId, privacy: .public)",
    )
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
