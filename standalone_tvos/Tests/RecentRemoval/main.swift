import Foundation

func check(_ actual: String?, _ expected: String?, line: Int = #line) {
    precondition(actual == expected, "Recent focus mismatch on line \(line): \(String(describing: actual))")
}

check(NuvioRecentFocus.nextID(in: ["A", "B", "C"], removing: "B"), "C")
check(NuvioRecentFocus.nextID(in: ["A", "B", "C"], removing: "C"), "B")
check(NuvioRecentFocus.nextID(in: ["A", "B", "C"], removing: "A"), "B")
check(NuvioRecentFocus.nextID(in: ["A"], removing: "A"), nil)
check(NuvioRecentFocus.nextID(in: [], removing: "A"), nil)
check(NuvioRecentFocus.nextID(in: ["A", "B"], removing: "missing"), nil)
print("Recent removal focus tests passed")
