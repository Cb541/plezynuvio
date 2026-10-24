var plan = NuvioAheadPlan()
plan.update(playback: 0, duration: 120)
var forward: [Int] = []
while let slot = plan.next() { forward.append(slot) }
assert(forward == Array(stride(from: 12, to: 119, by: 12)))
assert(!plan.hasPending)

// Clock updates must preserve the forward cursor instead of resetting it.
plan.update(playback: 60, duration: 120) // committed seek
assert(plan.next() == 72)
plan.update(playback: 61, duration: 120) // normal playback tick
assert(plan.next() == 84)
plan.update(playback: 0, duration: 120) // rewind
assert(plan.next() == 12)

var gapless = NuvioAheadPlan()
gapless.update(playback: 0, duration: 180)
assert(gapless.next() == 12)
assert(gapless.next() == 24)
gapless.update(playback: 1, duration: 180) // controls appear / timeline redraw
assert(gapless.next() == 36)
gapless.update(playback: 2, duration: 180)
assert(gapless.next() == 48)

var short = NuvioAheadPlan()
short.update(playback: 0, duration: 5)
assert(short.next() == nil)
print("Ahead plan: gapless 12s forward coverage, UI clock ticks, committed seeks and EOF passed")
