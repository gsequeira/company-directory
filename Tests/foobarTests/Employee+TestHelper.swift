@testable import foobar

extension Components.Schemas.Employee {
    var fullName: String { "\(firstName) \(lastName)" }
}
