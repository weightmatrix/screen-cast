import Foundation

@main enum CodeSuggestionCheck {
    @MainActor static func main() async throws {
        let suggestion = MatchingCodeSuggestion()
        let current = MatchingCode.generate()
        suggestion.request(for: current, excluding: [current])
        for _ in 0..<100 {
            if !suggestion.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let code = suggestion.code else { fatalError(suggestion.errorText ?? "Suggestion timed out") }
        precondition(MatchingCode.isValid(code) && code != current)
        suggestion.request(for: current, excluding: [current])
        precondition(suggestion.code == code, "Same conflict must not start repeated lookups")
        suggestion.request(for: current, excluding: [current], force: true)
        suggestion.reset()
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(suggestion.code == nil && !suggestion.isLoading && suggestion.errorText == nil,
                     "Cancelled lookup must not publish a stale recommendation")
        print("PASS live suggestion lookup, format/exclusion, conflict deduplication and cancellation")
    }
}
