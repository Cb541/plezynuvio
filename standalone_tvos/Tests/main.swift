var plan = NuvioAheadPlan()
plan.update(playback: 0, duration: 120)
var first: [Int] = []
for _ in 0..<5 { first.append(plan.next()!) }
assert(first == [12, 36, 60, 84, 108])
let refinementStart = [plan.next()!, plan.next()!]
assert(refinementStart == [12, 24]) // refinement begins automatically
var all = Set(first + refinementStart)
while let next = plan.next() { all.insert(next) }
assert(all == Set(stride(from: 12, to: 119, by: 12)))
assert(!plan.hasPending)
plan.update(playback: 60, duration: 120) // committed seek reanchors
assert(plan.next() == 72)
plan.update(playback: 61, duration: 120) // clock tick preserves cursor
assert(plan.next() == 96)
plan.update(playback: 0, duration: 120) // rewind also reanchors
assert(plan.next() == 12)
var short = NuvioAheadPlan()
short.update(playback: 0, duration: 5)
assert(short.next() == nil)
print("Ahead plan: coarse-first coverage, complete refinement, clock ticks, seeking and EOF passed")
