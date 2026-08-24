@testable import AudioTapLib
import XCTest

/// The digital-silence verdict. The numbers in these tests are the measured
/// ones from the 2026-08-24 recording: a live-but-quiet tap carried 3,839,964
/// nonzero samples out of 3,840,000 over four minutes, and a dead one carried
/// zero out of the same 3,840,000. See `SilentTapWatchdog`.
///
/// Most tests here run the state machine on a deliberately short window so the
/// transitions are cheap to express; the ones that pin the *production*
/// threshold say so and construct the watchdog with no overrides.
final class SilentTapWatchdogTests: XCTestCase {
    /// One 48 kHz stereo IOProc buffer's worth of samples, the granularity the
    /// production path feeds in at.
    private let bufferSamples = 1024

    /// A short-window watchdog for the transition tests. 20 s is a test-speed
    /// value and deliberately NOT the production threshold — that one is 120 s
    /// and is exercised by the two `production` tests below, which would
    /// otherwise make every state-machine test six times longer to no purpose.
    private static let testWindow: TimeInterval = 20

    private func makeWatchdog(
        zeroRunSeconds: TimeInterval = SilentTapWatchdogTests.testWindow, maxTriggers: Int = 3,
    ) -> SilentTapWatchdog {
        SilentTapWatchdog(zeroRunSeconds: zeroRunSeconds, maxTriggers: maxTriggers)
    }

    /// A run comfortably past `testWindow`, and one comfortably short of it.
    /// Derived so retuning the test window cannot leave a literal behind that
    /// silently stops testing what its name says.
    private var past: TimeInterval { Self.testWindow + 5 }
    private var short: TimeInterval { Self.testWindow - 1 }

    /// Feed `seconds` worth of buffers at roughly the production cadence,
    /// returning every action the watchdog emitted.
    @discardableResult
    private func feed(
        _ watchdog: inout SilentTapWatchdog,
        sumOfSquares: Double,
        seconds: TimeInterval,
        from start: TimeInterval,
        step: TimeInterval = 0.02,
    ) -> [SilentTapWatchdog.Action] {
        var actions: [SilentTapWatchdog.Action] = []
        var now = start
        let end = start + seconds
        while now <= end {
            if let action = watchdog.observe(
                sumOfSquares: sumOfSquares, samples: bufferSamples, now: now,
            ) {
                actions.append(action)
            }
            now += step
        }
        return actions
    }

    // MARK: - The discriminator

    func testQuietButLiveTapNeverTrips() {
        var watchdog = makeWatchdog()
        // -61.3 dBFS over 1024 samples: quiet, but not one sample is zero.
        let sumSq = pow(10, -61.3 / 10) * Double(bufferSamples)
        let actions = feed(&watchdog, sumOfSquares: sumSq, seconds: 300, from: 0)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(watchdog.isSilent)
    }

    func testDigitallySilentTapTrips() {
        var watchdog = makeWatchdog()
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: past, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
        XCTAssertTrue(watchdog.isSilent)
        XCTAssertEqual(watchdog.restartsRequested, 1)
    }

    func testTripDoesNotFireBeforeTheWindowElapses() {
        var watchdog = makeWatchdog()
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: short, from: 0)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(watchdog.isSilent)
    }

    /// A single nonzero sample anywhere in the window restarts the clock. This
    /// is what keeps a merely quiet meeting from ever reaching a verdict.
    func testOneSignalBufferRestartsTheRun() {
        var watchdog = makeWatchdog()
        feed(&watchdog, sumOfSquares: 0, seconds: short, from: 0)
        XCTAssertNil(watchdog.observe(sumOfSquares: 1e-12, samples: bufferSamples, now: short + 0.5))
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: short, from: short + 1)
        XCTAssertTrue(actions.isEmpty, "the run must have restarted at the signal buffer")
    }

    // MARK: - The production threshold

    /// The regression this threshold exists for. A meeting app renders exact
    /// digital zeros while idle for far longer than intuition suggests: across
    /// 22 real meetings the longest such run during healthy operation was
    /// 49.85 s, and seven runs exceeded 20 s. A watchdog that tripped on those
    /// would tear down a working tap in roughly one meeting in three, which is
    /// worse than the defect for anyone who never meets it.
    func testProductionThresholdIgnoresTheLongestObservedHealthyZeroRun() {
        var watchdog = SilentTapWatchdog()
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: 50, from: 0, step: 0.1)
        XCTAssertTrue(
            actions.isEmpty,
            "a 50 s zero run is normal idle behavior and must not trip the watchdog",
        )
        XCTAssertFalse(watchdog.isSilent)
    }

    /// Pins the margin itself, so a future revision that lowers the threshold
    /// toward the measured maximum fails here rather than in the field.
    func testProductionThresholdKeepsMarginOverTheObservedMaximum() {
        let observedMaximumSeconds = 49.85
        XCTAssertGreaterThan(
            SilentTapWatchdog.defaultZeroRunSeconds, observedMaximumSeconds * 2,
            "the threshold must stay at least 2x the longest zero run measured during healthy operation",
        )
    }

    /// The other side of the trade: the margin is bounded, and a genuinely dead
    /// tap is still caught well inside the outage.
    func testProductionThresholdStillCatchesTheIncident() {
        var watchdog = SilentTapWatchdog()
        // The incident's shorter dead stretch was 11.7 minutes.
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: 11.7 * 60, from: 0, step: 0.5)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
    }

    // MARK: - Reporting once per episode

    func testTripIsReportedOncePerEpisodeNotPerWindow() {
        var watchdog = SilentTapWatchdog()
        // The incident's longer dead stretch was 33.5 minutes — sixteen
        // production windows, which must still yield exactly one verdict.
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: 33.5 * 60, from: 0, step: 0.5)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: true)])
        XCTAssertEqual(
            watchdog.restartsRequested, 1,
            "a restart that did not help must not be repeated every window",
        )
    }

    func testSignalAfterAnEpisodeReportsRecovery() {
        var watchdog = makeWatchdog()
        feed(&watchdog, sumOfSquares: 0, seconds: past, from: 0)
        XCTAssertEqual(
            watchdog.observe(sumOfSquares: 0.5, samples: bufferSamples, now: past + 5), .recovered,
        )
        XCTAssertFalse(watchdog.isSilent)
    }

    func testRecoveryIsNotReportedWhenNoEpisodeWasOpen() {
        var watchdog = makeWatchdog()
        XCTAssertNil(watchdog.observe(sumOfSquares: 0.5, samples: bufferSamples, now: 1))
    }

    // MARK: - Trigger budget

    func testBudgetBoundsHowManyEpisodesDriveARestart() {
        var watchdog = makeWatchdog(maxTriggers: 2)
        var clock: TimeInterval = 0
        var verdicts: [SilentTapWatchdog.Action] = []
        for _ in 0 ..< 3 {
            verdicts += feed(&watchdog, sumOfSquares: 0, seconds: past, from: clock)
            clock += past + 5
            // Signal returns, closing the episode so the next one is fresh.
            _ = watchdog.observe(sumOfSquares: 0.5, samples: bufferSamples, now: clock)
            clock += 1
        }
        XCTAssertEqual(
            verdicts,
            [
                .silenceDetected(mayRestart: true),
                .silenceDetected(mayRestart: true),
                .silenceDetected(mayRestart: false),
            ],
        )
        XCTAssertEqual(watchdog.restartsRequested, 2)
    }

    /// An exhausted budget must not make the failure quieter — the user is still
    /// told, only the restart is withheld.
    func testExhaustedBudgetStillReportsSilence() {
        var watchdog = makeWatchdog(maxTriggers: 0)
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: past, from: 0)
        XCTAssertEqual(actions, [.silenceDetected(mayRestart: false)])
        XCTAssertTrue(watchdog.isSilent)
    }

    // MARK: - Restart handoff

    func testResetRunClearsTheRunButKeepsTheLatch() {
        var watchdog = makeWatchdog()
        feed(&watchdog, sumOfSquares: 0, seconds: past, from: 0)
        XCTAssertTrue(watchdog.isSilent)
        watchdog.resetRun()
        XCTAssertTrue(watchdog.isSilent, "a restart that did not help must still read as silent")
        // The new tap's zero buffers start a fresh run rather than extending the
        // dead tap's, so no verdict lands before a full window has passed.
        let actions = feed(&watchdog, sumOfSquares: 0, seconds: short, from: past + 10)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Degenerate input

    func testEmptyBuffersAreIgnored() {
        var watchdog = makeWatchdog()
        for tick in 0 ..< 100 {
            XCTAssertNil(watchdog.observe(sumOfSquares: 0, samples: 0, now: Double(tick)))
        }
        XCTAssertFalse(watchdog.isSilent)
    }

    /// A tap that has all but stopped delivering is the level-staleness path's
    /// problem, not this one's; racing it here would produce two verdicts about
    /// the same failure.
    func testTapDeliveringAlmostNothingDoesNotReachAVerdict() {
        var watchdog = makeWatchdog()
        // Two buffers spanning the whole window: far under the sample floor.
        XCTAssertNil(watchdog.observe(sumOfSquares: 0, samples: 64, now: 0))
        XCTAssertNil(watchdog.observe(sumOfSquares: 0, samples: 64, now: past))
        XCTAssertFalse(watchdog.isSilent)
    }
}
