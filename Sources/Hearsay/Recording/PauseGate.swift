import os

/// Recording pause, read on the audio threads: while paused, captures drop every buffer before the
/// writer, the level box and the live feed see it. On resume the writers' timeline pads the gap with
/// silence (as for any gap), so the files stay on meeting time.
final class PauseGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isPaused: Bool { state.withLock { $0 } }
    func set(_ paused: Bool) { state.withLock { $0 = paused } }
}
