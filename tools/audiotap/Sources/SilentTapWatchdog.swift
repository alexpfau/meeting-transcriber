import Foundation

/// Detects a process tap that is alive but delivering *digital* silence:
/// buffers arriving on schedule whose every sample is exactly zero.
///
/// **This is the primary detector, not a backstop.** Nothing decides in advance
/// that an output device cannot carry audio — an earlier design tried that,
/// keyed on device transport, and broke working recordings, because transport
/// cannot tell a live virtual device from a dead one (see
/// `OutputDeviceAnchorPolicy`). The tap therefore always anchors to the system
/// default first and this type is the only evidence that ever moves it. A trip
/// advances `AnchorSearch` to the next candidate; without a trip, nothing moves
/// at all.
///
/// Deliberately independent of *why* the tap went dead: the observable symptom
/// is the same for every cause found so far, and a symptom-driven check keeps
/// working for causes not yet seen.
///
/// **Why exact zero and not a quiet threshold.** A tap that is genuinely
/// running always carries a noise floor *when it is rendering at all*.
/// Measured on the recording that prompted this: four minutes with nobody
/// speaking on the far side read -61.3 dBFS with 3,839,964 of 3,840,000
/// samples nonzero, while four minutes of the dead stretch read exactly -120
/// dBFS with 0 of 3,840,000 nonzero. An RMS threshold cannot separate those
/// two cases without also firing on a merely quiet meeting; "not one nonzero
/// sample in the whole window" can.
///
/// **Why the trigger budget.** The response to a trip is a tap restart, which
/// costs a fraction of a second of audio. An unbounded watchdog would chew a
/// gap into a recording every window forever. Three trips per recording bounds
/// that cost at a level the true positive is still fixed by (the first restart
/// is the one that re-anchors), and after the budget is spent the condition is
/// still *reported* — it just stops being acted on.
///
/// **One restart per episode, not one per window.** `isSilent` latches until
/// real signal returns, so a restart that did not fix the problem is not
/// followed by an identical restart a window later. Repeating a fix that just
/// failed only costs more audio, and the user has already been told. The
/// budget therefore bounds how many separate silence *episodes* are acted on,
/// not how many windows.
struct SilentTapWatchdog: Equatable {
    /// How long an unbroken run of all-zero buffers must last before the tap
    /// counts as dead.
    ///
    /// **Measured, not chosen by feel.** A meeting app really does render exact
    /// digital zeros while idle, for far longer than intuition suggests. Across
    /// the 22 recorded meetings in one user's library, excluding the two known
    /// dead windows, the app tracks contain 35 runs of exactly-zero samples
    /// between 5 s and 60 s during otherwise healthy operation: 34 over 10 s,
    /// 7 over 20 s, 3 over 30 s, median 15.1 s, p95 35.7 s, **longest 49.85 s**.
    /// Four of the seven runs past 20 s sit at the very start of a recording,
    /// before the app has begun rendering at all.
    ///
    /// So a 20-second threshold would have tripped seven times across those 22
    /// meetings — roughly one healthy meeting in three — and every trip tears
    /// the tap down and punches a real gap into a recording that was working.
    /// That is worse than the defect for anyone who never meets it. 120 s
    /// clears the observed maximum by about 2.4x and produces zero false trips
    /// against that corpus.
    ///
    /// The cost of the margin is bounded and small: on the incident recording,
    /// tripping at 120 s rather than 20 s still recovers 31.5 of the 33.5 dead
    /// minutes and 9.7 of the 11.7. Roughly 100 seconds of a rare outage buys
    /// the elimination of a false trip every third meeting.
    ///
    /// **Caveat on the measurement.** Those runs were measured on the written
    /// 16 kHz mono file, not on the raw pre-resample buffers this type actually
    /// sees. The resampler and `TimelineAnchor`'s gap-filling sit between the
    /// two, so the file approximates the raw stream rather than reproducing it.
    /// The error is believed to run toward *over*-stating zero-run length,
    /// which is the safe direction for setting a floor, but the two signals are
    /// not identical and a future revision should not treat them as such.
    ///
    /// Applied unconditionally from the start of capture, with no arming on the
    /// first nonzero sample. Arming would dispose of the four start-of-recording
    /// cases neatly, but it also disables the watchdog for a tap that is dead
    /// from its very first buffer — which is exactly the shape (issue #524)
    /// where nothing else can help. One threshold from t=0 covers both.
    static let defaultZeroRunSeconds: TimeInterval = 120

    /// How many restarts one recording may spend on this. See the type comment.
    static let defaultMaxTriggers = 3

    /// Sample floor for a verdict, per second of the run. A run that spans the
    /// full window on a handful of samples is a tap that has all but stopped
    /// delivering, which the level-staleness path already handles; declaring it
    /// digitally silent here would just race that. Set two orders of magnitude
    /// below any real capture rate, so it only excludes the degenerate case.
    static let defaultMinSamplesPerSecond: Double = 100

    /// What one buffer changed, or nil when it changed nothing. Optional
    /// rather than a `.none` case, matching `ChannelHealthMonitor`: most
    /// buffers are unremarkable, and a case named `none` reads as
    /// `Optional.none` at every call site.
    enum Action: Equatable {
        /// The run crossed the threshold. Tell the user either way — this one
        /// does not resolve itself. `mayRestart` says whether the trigger
        /// budget also allows re-anchoring the tap, which is the part that
        /// costs audio; reporting and acting are separate so an exhausted
        /// budget makes the failure no quieter.
        case silenceDetected(mayRestart: Bool)
        /// Real signal arrived after a reported episode.
        case recovered
    }

    let zeroRunSeconds: TimeInterval
    let maxTriggers: Int
    let minSamplesPerSecond: Double

    /// True from a `.reportSilence` until signal returns. Read by the app so the
    /// menu bar and the notification path can act on it without a callback.
    private(set) var isSilent = false

    private var runStart: TimeInterval?
    private var runSamples = 0
    private var triggersFired = 0

    init(
        zeroRunSeconds: TimeInterval = Self.defaultZeroRunSeconds,
        maxTriggers: Int = Self.defaultMaxTriggers,
        minSamplesPerSecond: Double = Self.defaultMinSamplesPerSecond,
    ) {
        self.zeroRunSeconds = zeroRunSeconds
        self.maxTriggers = maxTriggers
        self.minSamplesPerSecond = minSamplesPerSecond
    }

    /// Feed one captured buffer.
    ///
    /// - Parameters:
    ///   - sumOfSquares: the buffer's summed squared samples, which the capture
    ///     path already computes for its RMS reporting. Zero exactly when every
    ///     sample is exactly zero: the square of the smallest nonzero `Float`
    ///     is still comfortably representable in `Double`, so no nonzero sample
    ///     can underflow out of this sum.
    ///   - samples: how many samples that buffer held.
    ///   - now: monotonic seconds. Injected rather than read here so the whole
    ///     transition table is testable without waiting out a real window.
    mutating func observe(
        sumOfSquares: Double, samples: Int, now: TimeInterval,
    ) -> Action? {
        guard samples > 0 else { return nil }

        guard sumOfSquares == 0 else {
            runStart = nil
            runSamples = 0
            guard isSilent else { return nil }
            isSilent = false
            return .recovered
        }

        guard let started = runStart else {
            runStart = now
            runSamples = samples
            return nil
        }
        runSamples += samples

        let elapsed = now - started
        guard elapsed >= zeroRunSeconds,
              Double(runSamples) >= elapsed * minSamplesPerSecond
        else { return nil }

        // Restart the measurement either way: an episode already reported must
        // not re-report every buffer, and a budget-exhausted one must not keep
        // a run open that a later recovery would then have to unwind.
        runStart = nil
        runSamples = 0

        guard !isSilent else { return nil }
        isSilent = true
        guard triggersFired < maxTriggers else { return .silenceDetected(mayRestart: false) }
        triggersFired += 1
        return .silenceDetected(mayRestart: true)
    }

    /// How many restarts this watchdog has authorized. Surfaced for logging.
    var restartsRequested: Int {
        triggersFired
    }

    /// Clear the in-flight run without touching the trigger budget or the
    /// latched `isSilent`. Called when the tap is torn down: the buffers a new
    /// tap delivers must not be appended to the dead tap's run. The latch
    /// deliberately survives, so a restart that did not help still reads as
    /// silent until real signal proves otherwise.
    mutating func resetRun() {
        runStart = nil
        runSamples = 0
    }
}
