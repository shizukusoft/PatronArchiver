#if os(macOS)
import SwiftUI

extension View {
    /// Draws text fields with the system border in a rounded rectangle shape.
    @ViewBuilder
    func roundedTextFieldBorder() -> some View {
        if #available(macOS 27, *) {
            textFieldStyle(.bordered)
                .textInputBorderShape(.roundedRectangle)
        } else {
            textFieldStyle(.roundedBorder)
        }
    }
}
#endif
