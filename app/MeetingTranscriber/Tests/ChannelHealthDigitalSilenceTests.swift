@testable import MeetingTranscriber
import XCTest

/// The un-debounced digital-silence path in `ChannelHealthController`.
///
/// Kept apart from `ChannelHealthIntegrationTests` because it deliberately does
/// *not* go through `ChannelHealthMonitor`: the point of these assertions is
/// that a tap reading literal zeros is reported without the debounce window and
/// without waiting for the other channel to carry speech. In the recording that
/// prompted this, the user was listening rather than talking for most of the
/// meeting, so his microphone was near-silent too and the asymmetric monitor's
/// confirmation never arrived across 45 dead minutes.
@MainActor
final class ChannelHealthDigitalSilenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeController() -> (ChannelHealthController, MockRecorder, RecordingNotifier) {
        let suite = "ChannelHealthDigitalSilenceTests-\(getpid())-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.perChannelIndicatorEnabled = true
        settings.asymmetricSilenceWarningSeconds = 30

        let notifier = RecordingNotifier()
        let controller = ChannelHealthController(
            notifier: notifier,
            debounceSeconds: { settings.asymmetricSilenceWarningSeconds },
            indicatorEnabled: { settings.perChannelIndicatorEnabled },
        )
        return (controller, recorder: MockRecorder(), notifier)
    }

    func testFlagIsInactiveByDefault() {
        let (controller, _, _) = makeController()
        XCTAssertFalse(controller.appDigitalSilenceActive)
    }

    /// The whole point: one tick, no debounce, no speech on the other channel.
    func testDigitalSilenceIsReportedOnTheFirstTick() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        // Both channels quiet — the shape that kept the asymmetric monitor from
        // ever confirming during the incident.
        recorder.micLevelDBFS = -120
        recorder.appLevelDBFS = -120
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertTrue(controller.appDigitalSilenceActive)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls[0].title, "App Audio Is Not Being Captured")
        XCTAssertEqual(
            notifier.calls[0].urgency, .timeSensitive,
            "a tap capturing literal zeros has no benign reading, so it must pierce Focus",
        )
    }

    func testDigitalSilenceTintsTheAppHalfOfTheMenuBar() {
        let (controller, recorder, _) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertTrue(controller.appSilentOverlay)
        XCTAssertFalse(controller.micSilentOverlay)
    }

    /// A microphone-only recording has no app channel, so its permanently
    /// absent tap must not paint anything.
    func testDigitalSilenceIsSuppressedOnARecordingWithNoAppChannel() {
        let (controller, recorder, _) = makeController()
        controller.simulateStartForTests(channels: .micOnly)
        recorder.appCaptureDigitallySilent = true

        controller.applyTick(recorder: recorder, now: t0)

        XCTAssertFalse(controller.appSilentOverlay)
    }

    func testDigitalSilenceIsReportedOncePerEpisode() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true

        for offset in stride(from: 0.0, through: 300.0, by: 0.1) {
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        // Counted by title: the mock's levels stay at -120, so the sibling
        // symmetric-silence monitor legitimately fires its own alert once.
        let ours = notifier.calls.filter { $0.title == "App Audio Is Not Being Captured" }
        XCTAssertEqual(ours.count, 1, "the 10 Hz poll must not re-notify every tick")
    }

    func testRecoveryClearsTheFlagWithoutANotification() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)
        XCTAssertTrue(controller.appDigitalSilenceActive)

        recorder.appCaptureDigitallySilent = false
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertFalse(controller.appSilentOverlay)
        XCTAssertEqual(notifier.calls.count, 1, "recovery is not worth a second alert")
    }

    /// A second episode in the same recording is a second failure and is worth
    /// telling the user about again.
    func testASecondEpisodeNotifiesAgain() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()

        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)
        recorder.appCaptureDigitallySilent = false
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(1))
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(2))

        XCTAssertEqual(notifier.calls.count, 2)
    }

    func testStopClearsTheFlag() {
        let (controller, recorder, _) = makeController()
        controller.simulateStartForTests()
        recorder.appCaptureDigitallySilent = true
        controller.applyTick(recorder: recorder, now: t0)

        controller.stop()

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertFalse(controller.appSilentOverlay)
    }

    /// The message has to name what the user can act on — the device mismatch,
    /// and the tools that produce it — and say that the app is already trying
    /// the next device, since that is what the same verdict triggers.
    func testMessagePointsAtTheInterposingDevice() {
        let message = ChannelHealthController.digitalSilenceMessage
        XCTAssertTrue(message.lowercased().contains("virtual device"))
        XCTAssertTrue(message.lowercased().contains("loopback driver"))
        XCTAssertTrue(message.lowercased().contains("trying the next audio device"))
        XCTAssertTrue(message.contains("System Settings › Sound"))
    }

    /// A healthy but quiet tap must reach none of this. The verdict comes from
    /// the capture layer, not from a level, precisely so a quiet meeting cannot
    /// trigger it.
    func testQuietChannelsAloneDoNotTriggerDigitalSilence() {
        let (controller, recorder, notifier) = makeController()
        controller.simulateStartForTests()
        recorder.micLevelDBFS = -120
        recorder.appLevelDBFS = -61.3

        for offset in stride(from: 0.0, through: 300.0, by: 1.0) {
            controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(offset))
        }

        XCTAssertFalse(controller.appDigitalSilenceActive)
        XCTAssertTrue(
            notifier.calls.allSatisfy { $0.title != "App Audio Is Not Being Captured" },
        )
    }
}
