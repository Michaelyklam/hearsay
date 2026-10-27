import os

/// Recording pause, read on the audio threads. While paused, captures drop every buffer. The pause is
/// cut out of the recording rather than padded: `shift` moves every later buffer's host time back by
/// the total time paused, so the files and the live feed continue where they stopped (no seconds of
/// zeros written on the audio thread at resume) and mic and call stay aligned, being shifted alike.
/// Meeting time is therefore recorded time; levels and end detection keep the real host time.
final class PauseGate: Sendable {
    private struct State { var paused = false; var pausedAt: UInt64 = 0; var offset: UInt64 = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPaused: Bool { state.withLock { $0.paused } }

    func set(_ paused: Bool, at host: UInt64) {
        state.withLock { s in
            guard s.paused != paused else { return }
            if paused { s.pausedAt = host } else if host > s.pausedAt { s.offset += host - s.pausedAt }
            s.paused = paused
        }
    }

    /// A buffer's host time on the recording's clock (pauses removed).
    func shift(_ host: UInt64) -> UInt64 {
        let offset = state.withLock { $0.offset }
        return host > offset ? host - offset : host
    }
}
