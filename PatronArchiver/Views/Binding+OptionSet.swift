import SwiftUI

extension Binding where Value: OptionSet, Value == Value.Element {
    /// A Boolean binding to one flag of an option set, for driving a `Toggle`.
    ///
    /// SwiftUI has nothing that binds an `OptionSet` directly — every `Toggle` initializer takes a
    /// `Binding<Bool>` — so each flag gets its own view of the whole value: reading tests
    /// membership, and writing inserts or removes that one flag while leaving the rest alone.
    func contains(_ member: Value) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(member) },
            set: { isOn in
                if isOn {
                    wrappedValue.insert(member)
                } else {
                    wrappedValue.remove(member)
                }
            }
        )
    }
}
