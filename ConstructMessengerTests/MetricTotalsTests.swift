import XCTest
@testable import Construct_Messenger

/// The divergence-signal counters of `decisions/ios-semantic-divergence-signals.md` are only worth
/// the epic that added them if a run can be read off them afterwards. Until 2026-08-24 it could
/// not: `count(event:)` scanned a 200-record ring buffer shared by every event, so a busy receive
/// path evicted the rare loud signals before anyone looked, and no count reached the exported log
/// at all.
///
/// **Touches the `PerformanceMetrics.shared` singleton** — run this suite alone as well as in the
/// full set (decisions/one-ack-cache-one-durable-store.md: a green full run can be an artefact of
/// an alphabetically earlier suite).
final class MetricTotalsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PerformanceMetrics.shared.clearAll()
    }

    override func tearDown() {
        PerformanceMetrics.shared.clearAll()
        super.tearDown()
    }

    /// The defect this replaced, in the shape it had on device: one rare failure surrounded by a
    /// redelivery storm. The 2026-08-04 run recorded 6296 `duplicate_after_ack_check`, which turns
    /// a 200-slot buffer over thirty times — a single `confirm_hold_overflow` in the middle of it
    /// was unreadable by the time the run ended.
    func testRareSignalSurvivesAHighVolumeNeighbour() {
        for _ in 0..<250 { PerformanceMetrics.shared.record(.duplicateAfterAckCheck) }
        PerformanceMetrics.shared.record(.confirmHoldOverflow)
        for _ in 0..<250 { PerformanceMetrics.shared.record(.duplicateAfterAckCheck) }

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .confirmHoldOverflow), 1,
                       "the rare signal was evicted by its noisy neighbour")
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .duplicateAfterAckCheck), 500,
                       "counts must not saturate at the ring buffer's capacity")
    }

    /// `clearAll()` is what the other suites use to isolate a count, so the totals have to reset
    /// with it — otherwise every existing before/after assertion drifts.
    func testClearAllResetsTheTotals() {
        PerformanceMetrics.shared.record(.confirmHold)
        XCTAssertEqual(PerformanceMetrics.shared.count(event: .confirmHold), 1)

        PerformanceMetrics.shared.clearAll()

        XCTAssertEqual(PerformanceMetrics.shared.count(event: .confirmHold), 0)
    }

    /// A line per 30-second sample on an idle device would be noise in the file the signals are
    /// meant to make readable.
    func testSummaryIsSilentUntilSomethingIsRecorded() {
        XCTAssertNil(PerformanceMetrics.shared.changedSignalsSummary(),
                     "nothing recorded — nothing to say")

        PerformanceMetrics.shared.record(.senderSyncUnroutable)
        XCTAssertNotNil(PerformanceMetrics.shared.changedSignalsSummary())

        XCTAssertNil(PerformanceMetrics.shared.changedSignalsSummary(),
                     "unchanged totals must not repeat the previous line")

        PerformanceMetrics.shared.record(.senderSyncUnroutable)
        XCTAssertNotNil(PerformanceMetrics.shared.changedSignalsSummary(),
                        "the counter moved and the line must say so")
    }

    /// Cumulative, not per-interval: the value of the line is that the last one in a log is the
    /// whole run.
    func testSummaryCarriesRunningTotalsNotDeltas() {
        PerformanceMetrics.shared.record(.confirmHold)
        _ = PerformanceMetrics.shared.changedSignalsSummary()

        PerformanceMetrics.shared.record(.confirmHold)
        let second = PerformanceMetrics.shared.changedSignalsSummary()

        XCTAssertEqual(second, "confirm_hold=2")
    }

    /// `token_wallet_wait` is the shape that made the breakdown necessary: it is the Privacy Pass
    /// enforce-readiness gauge (TODO 47), it logs nothing of its own, and its bare total says
    /// nothing the decision asks — `served` against `timeout` is the whole measurement.
    func testClosedSetLabelsAreBrokenOutOfTheTotal() {
        for _ in 0..<3 { PerformanceMetrics.shared.record(.tokenWalletWait, label: "served") }
        PerformanceMetrics.shared.record(.tokenWalletWait, label: "timeout")

        XCTAssertEqual(PerformanceMetrics.shared.changedSignalsSummary(),
                       "token_wallet_wait=4(served=3,timeout=1)")
    }

    /// The other half of the same rule. `duplicate_after_ack_check` labels with `msgNum=`, so a
    /// per-label map would grow for as long as the run does and read as noise at the end of it —
    /// the 2026-08-04 figure was 6296 records. The cardinality decides, not a list kept by hand.
    func testIdentifierLabelsCollapseToThePlainTotal() {
        for msgNum in 0..<40 {
            PerformanceMetrics.shared.record(.duplicateAfterAckCheck, label: "msgNum=\(msgNum)")
        }

        XCTAssertEqual(PerformanceMetrics.shared.changedSignalsSummary(),
                       "duplicate_after_ack_check=40")
    }

    /// Volume first, so the denominators lead: a failure count with no traffic count beside it is
    /// how `chunk_reassembly_incomplete` read as eleven losses for a photo that arrived intact.
    func testSummaryLeadsWithTheBusiestEvent() {
        PerformanceMetrics.shared.record(.confirmHoldOverflow)
        for _ in 0..<3 { PerformanceMetrics.shared.record(.duplicateAfterAckCheck) }

        let summary = PerformanceMetrics.shared.changedSignalsSummary()

        XCTAssertEqual(summary, "duplicate_after_ack_check=3 confirm_hold_overflow=1")
    }
}
