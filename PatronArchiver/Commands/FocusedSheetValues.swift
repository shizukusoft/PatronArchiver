import SwiftUI

/// Focused-scene bindings that let app-scope commands drive a sheet on the key window.
///
/// A menu command lives in the App scene, above any window, so it cannot reach a window's
/// `@State` directly. Each window publishes its sheet binding with `focusedSceneValue(_:_:)`; the
/// command reads the key window's binding through `@FocusedValue` and flips it, so the sheet opens
/// on the window the user is actually looking at rather than on every window at once.
extension FocusedValues {
    var showTipJarSheet: Binding<Bool>? {
        get { self[ShowTipJarSheetKey.self] }
        set { self[ShowTipJarSheetKey.self] = newValue }
    }

    #if os(iOS)
    var showMailCompose: Binding<Bool>? {
        get { self[ShowMailComposeKey.self] }
        set { self[ShowMailComposeKey.self] = newValue }
    }
    #endif
}

private struct ShowTipJarSheetKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

#if os(iOS)
private struct ShowMailComposeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
#endif
