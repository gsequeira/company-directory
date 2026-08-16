@testable import CompanyDirectory

extension Components.Schemas.Employee {
    var fullName: String { "\(firstName) \(lastName)" }
}
