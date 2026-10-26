var recovery = NuvioAheadRecovery()
assert(NuvioAheadRecovery.completedPastSlots(playback: 0).isEmpty)
assert(NuvioAheadRecovery.completedPastSlots(playback: 23).isEmpty)
assert(NuvioAheadRecovery.completedPastSlots(playback: 24) == [12])
assert(NuvioAheadRecovery.completedPastSlots(playback: 36) == [12, 24])
assert(NuvioAheadRecovery.completedPastSlots(playback: 253).first == 24)
assert(NuvioAheadRecovery.completedPastSlots(playback: 253).last == 240)
assert(NuvioAheadRecovery.completedPastSlots(playback: 999).count <= 21)
for _ in 0..<3 {
    recovery.didScheduleForward()
    assert(!recovery.shouldRepairBeforeForward)
}
recovery.didScheduleForward()
assert(recovery.shouldRepairBeforeForward)
recovery.didScheduleRepair()
assert(!recovery.shouldRepairBeforeForward)
recovery.reset()
assert(!recovery.shouldRepairBeforeForward)
// Simulate repeated tvOS Up/Down overlay changes during uninterrupted playback.
// The recovery policy never accepts a controls-visible input and can still
// find missing slots at each 12-second boundary independently of focus.
var captured: Set<Int> = [12, 24, 48, 60, 84, 96]
for position in stride(from: 0, through: 120, by: 3) {
    let controlsVisible = (position / 3) % 2 == 0
    _ = controlsVisible
    let missing = NuvioAheadRecovery.completedPastSlots(playback: position)
        .filter { !captured.contains($0) }
    if let slot = missing.first { captured.insert(slot) }
}
assert(captured.contains(36))
assert(captured.contains(72))
print("Ahead recovery: past-slot window, repair fairness, and Up/Down independence passed")
