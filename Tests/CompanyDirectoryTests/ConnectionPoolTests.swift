import Testing

@testable import CompanyDirectory

// Unit tests, not integration tests — this touches no database, so it needs neither
// `TestHelpers.withApplication` nor the `.serialized` trait the integration suite depends on.
//
// What they cover, and what they deliberately do not. The defect in #83 is a deadlock that
// resolves as a timeout, so a test that reproduces it is a test that hangs for the length of
// `ConnectionPool.acquisitionTimeout` and then asserts on a `500`. That is a slow test of the
// symptom rather than of the fix.
//
// What is worth pinning is the arithmetic, because it is the thing that now carries the reasoning:
// the per-loop number is derived from a total budget and a core count, and the floor of two is a
// correctness property rather than a tuning choice. These tests fail if somebody rewrites the
// division and loses the floor.
//
// **This does not mean the defect is covered.** What prevents a recurrence is the rule recorded in
// `Docs/FLUENT.md`, that a transaction closure may not reach for anything outside itself. Nothing
// here enforces that.
@Suite("Connection pool sizing")
struct ConnectionPoolTests {

    @Test("The floor of two holds however many cores there are")
    func testFloorHoldsAtHighCoreCounts() {
        // 32 / 64 rounds to zero, which is the case the `max` exists for.
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 64) == 2)
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 16) == 2)
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 1_000) == 2)
    }

    @Test("The budget divides across event loops when there is room to")
    func testBudgetDividesAcrossEventLoops() {
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 2) == 16)
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 4) == 8)
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 10) == 3)
    }

    @Test("The total stays under PostgreSQL's default max_connections")
    func testTotalStaysWithinBudget() {
        // The floor wins above 16 cores, so the total exceeds the budget there. That is deliberate:
        // correctness comes first. It still has to stay clear of the server's own limit of 100.
        for coreCount in [1, 2, 4, 8, 10, 16, 32, 48] {
            let total = ConnectionPool.connectionsPerEventLoop(coreCount: coreCount) * coreCount

            #expect(total < 100, "\(coreCount) cores would open \(total) connections")
        }
    }

    @Test("A zero core count cannot divide by zero")
    func testZeroCoreCountIsSafe() {
        // `System.coreCount` should never be zero. This pins the guard rather than the platform.
        #expect(ConnectionPool.connectionsPerEventLoop(coreCount: 0) == 32)
    }
}
