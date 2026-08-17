import FluentKit
import PostgresNIO

/// Which database constraint a failed write violated.
///
/// This type exists because of #21. Fluent's `DatabaseError.isConstraintFailure` is a single
/// boolean covering `uniqueViolation`, `foreignKeyViolation`, `notNullViolation`,
/// `checkViolation` and more. That was exact while uniqueness was the only constraint in the
/// schema — every constraint failure really was a duplicate name. The foreign key added in
/// `Migrations.AddEmployeeDepartment` ends that: a save naming a department that no longer
/// exists is now also a constraint failure, and reporting it as *"An employee named X already
/// exists"* would be a plain lie.
///
/// **This is where PostgreSQL-specific knowledge is allowed to live, and the only place.**
/// Distinguishing the constraints means reading SQLSTATE, which Fluent deliberately does not
/// expose — its job is to be portable, and the price of portability is that it cannot tell you
/// this. Rather than scatter `import PostgresNIO` across four handlers, the coupling is confined
/// to this file: switching databases means rewriting one initialiser, not auditing the handlers.
/// `Docs/FLUENT.md` → *What the abstraction costs* is the longer argument.
enum ConstraintViolation {
    /// A `UNIQUE` index rejected the row — SQLSTATE `23505`.
    case unique
    /// A foreign key rejected the row, either because the referenced row is absent or because
    /// deleting it would orphan this one — SQLSTATE `23503` and `23001`.
    case foreignKey
    /// A constraint failed that this application does not distinguish, such as `NOT NULL` or a
    /// `CHECK`. Callers should treat it as an unexpected failure rather than guessing.
    case other

    /// Classifies a thrown error, or returns `nil` if it is not a constraint failure at all.
    ///
    /// Returning `nil` for unrelated errors is what lets a handler write
    /// `catch let error where ConstraintViolation(error) == .unique` and leave everything else to
    /// propagate as a `500`, which is the correct answer for a failure nobody anticipated.
    init?(_ error: any Error) {
        guard let code = Self.sqlState(of: error) else { return nil }

        switch code {
        case .uniqueViolation:
            self = .unique
        case .foreignKeyViolation, .restrictViolation:
            self = .foreignKey
        case .integrityConstraintViolation, .notNullViolation, .checkViolation, .exclusionViolation:
            self = .other
        default:
            return nil
        }
    }

    /// Both error types reach here in practice: `PSQLError` from the current connection path, and
    /// `PostgresError` from the older one. FluentPostgresDriver conforms both to `DatabaseError`
    /// and reads SQLSTATE the same way, so this mirrors what the driver already does rather than
    /// inventing a second interpretation of the same field.
    private static func sqlState(of error: any Error) -> PostgresError.Code? {
        if let psqlError = error as? PSQLError {
            return psqlError.serverInfo?[.sqlState].map(PostgresError.Code.init(raw:))
        }

        if let postgresError = error as? PostgresError {
            return postgresError.code
        }

        return nil
    }
}
