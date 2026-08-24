import Foundation

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(source: RecordingSource, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

    /// Instantaneous app-audio level in dBFS. -120 when no capture session is
    /// active or the tap stopped delivering buffers in the last 0.5 s.
    /// Drives the menu-bar asymmetric-silence indicator. Default: -120
    /// (mocks that don't simulate audio levels stay silent).
    var appLevelDBFS: Double { get }

    /// Instantaneous mic level in dBFS, with the same semantics as
    /// `appLevelDBFS`.
    var micLevelDBFS: Double { get }

    /// True once a channel's capture was abandoned for good (issue #588),
    /// whether a restart attempt never returned or the retry budget ran out.
    /// The level alone cannot say this: a channel that fell silent may come
    /// back, one that gave up will not.
    /// Default false so mocks that do not simulate capture failures stay quiet.
    var appCaptureGaveUp: Bool { get }
    var micCaptureGaveUp: Bool { get }

    /// True while the app-audio tap is alive but delivering buffers whose every
    /// sample is exactly zero — what a virtual output driver taking over the
    /// system default looks like from here. Deliberately not folded into
    /// `appLevelDBFS`: a live tap always carries a noise floor, so digital
    /// silence is a verdict a dBFS threshold cannot reach without also firing
    /// on a quiet meeting. Default false, like the flags above.
    var appCaptureDigitallySilent: Bool { get }
}

extension RecordingProvider {
    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        -120
    }

    var appCaptureGaveUp: Bool {
        false
    }

    var micCaptureGaveUp: Bool {
        false
    }

    var appCaptureDigitallySilent: Bool {
        false
    }
}
