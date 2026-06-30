/// A weak box so the central can route disconnects without retaining controllers.
struct WeakController {
    weak var value: SurrealController?
    init(_ value: SurrealController) { self.value = value }
}
