var plan = NuvioAheadPlan()
plan.update(playback: 0, duration: 120)
var first: [Int] = []
for _ in 0..<5 { first.append(plan.next()!) }
assert(first == [8, 32, 56, 80, 104])
assert(plan.next() == 8) // refinement begins automatically
assert(plan.next() == 16)
var all = Set(first)
while let next = plan.next() { all.insert(next) }
assert(all == Set(stride(from: 8, to: 119, by: 8)))
assert(!plan.hasPending)
plan.update(playback: 60, duration: 120) // committed seek reanchors
assert(plan.next() == 64)
plan.update(playback: 61, duration: 120) // clock tick preserves cursor
assert(plan.next() == 88)
plan.update(playback: 0, duration: 120) // rewind also reanchors
assert(plan.next() == 8)
var short = NuvioAheadPlan()
short.update(playback: 0, duration: 5)
assert(short.next() == nil)
print("Ahead plan: coarse-first coverage, complete refinement, clock ticks, seeking and EOF passed")
