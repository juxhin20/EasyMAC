import Foundation

/// A window that could satisfy a workspace item.
struct MatchCandidate: Equatable, Sendable {
    let windowID: UInt32
    let bundleID: String
    let title: String
}

/// What a workspace item asks for.
struct MatchRequest: Equatable, Sendable {
    let bundleID: String
    let titleContains: String?
}

/// Pure window ↔ workspace-item matching, kept free of AppKit so it can be unit tested.
enum WindowMatcher {

    /// Assigns each request (by index) at most one distinct window.
    /// Pass 1 honours title hints; pass 2 gives remaining requests the first free window of their app.
    static func assign(_ requests: [MatchRequest], candidates: [MatchCandidate]) -> [Int: UInt32] {
        var used = Set<UInt32>()
        var result: [Int: UInt32] = [:]

        for (index, request) in requests.enumerated() {
            guard let hint = normalized(request.titleContains) else { continue }
            if let match = candidates.first(where: {
                $0.bundleID == request.bundleID && !used.contains($0.windowID)
                    && $0.title.localizedCaseInsensitiveContains(hint)
            }) {
                result[index] = match.windowID
                used.insert(match.windowID)
            }
        }

        for (index, request) in requests.enumerated() where result[index] == nil {
            if let match = candidates.first(where: { $0.bundleID == request.bundleID && !used.contains($0.windowID) }) {
                result[index] = match.windowID
                used.insert(match.windowID)
            }
        }
        return result
    }

    /// Suggests a stable title hint, e.g. "RentalX" from "index.php — RentalX — Visual Studio Code".
    static func suggestHint(title: String, appName: String) -> String? {
        let separators = [" — ", " – ", " - ", " | "]
        var parts = [title]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let app = appName.lowercased()
        let meaningful = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { part in
                let lower = part.lowercased()
                return !(lower == app || lower.contains(app) || app.contains(lower))
            }
        guard let last = meaningful.last else { return nil }
        return String(last.prefix(60))
    }

    private static func normalized(_ hint: String?) -> String? {
        guard let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
