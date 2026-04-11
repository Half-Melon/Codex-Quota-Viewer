import Foundation

func profileLastUsedComparator(
    lhsLastUsedAt: Date?,
    lhsDisplayName: String,
    rhsLastUsedAt: Date?,
    rhsDisplayName: String
) -> Bool {
    let lhsLastUsed = lhsLastUsedAt ?? .distantPast
    let rhsLastUsed = rhsLastUsedAt ?? .distantPast
    if lhsLastUsed != rhsLastUsed {
        return lhsLastUsed > rhsLastUsed
    }

    return lhsDisplayName.localizedCaseInsensitiveCompare(rhsDisplayName) == .orderedAscending
}
