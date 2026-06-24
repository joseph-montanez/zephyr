import Foundation

/// Ranks command descriptors for command-line autocomplete.
///
/// Matching is isolated from command execution so scoring rules can evolve
/// without adding another reason for `CADCommandProcessor` to change.
final class CADCommandMatcher {
    typealias Match = (descriptor: CommandDescriptor, matchingAlias: String)

    var lastInput = ""
    var cachedMatches: [Match] = []

    func reset() {
        lastInput = ""
        cachedMatches = []
    }

    func matches(input rawInput: String) -> [Match] {
        let input = rawInput.uppercased().trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else {
            lastInput = ""
            cachedMatches = allCommandsByCategory()
            return cachedMatches
        }
        guard input != lastInput else { return cachedMatches }
        lastInput = input

        let inputCharacters = Array(input)
        var ranked: [(descriptor: CommandDescriptor, alias: String, score: Double)] = []

        for descriptor in CommandDescriptor.allCommands {
            let candidates = descriptor.allMatches.compactMap { candidate -> (String, Double)? in
                guard containsInSequence(candidate, inputCharacters) else { return nil }
                return (candidate, score(candidate: candidate, input: input, characters: inputCharacters))
            }
            if let best = candidates.min(by: { $0.1 < $1.1 }) {
                ranked.append((descriptor, best.0, best.1))
            }
        }

        ranked.sort {
            $0.score == $1.score ? $0.alias < $1.alias : $0.score < $1.score
        }
        cachedMatches = ranked.map { ($0.descriptor, $0.alias) }
        return cachedMatches
    }

    private func allCommandsByCategory() -> [Match] {
        let order: [CommandCategory] = [.draw, .modify, .view, .layer, .block, .settings]
        return CommandDescriptor.allCommands.sorted {
            let lhsCategory = order.firstIndex(of: $0.category) ?? 99
            let rhsCategory = order.firstIndex(of: $1.category) ?? 99
            return lhsCategory == rhsCategory
                ? $0.canonicalName < $1.canonicalName
                : lhsCategory < rhsCategory
        }.map { ($0, $0.canonicalName) }
    }

    private func containsInSequence(
        _ candidate: String,
        _ needle: [Character]
    ) -> Bool {
        var index = candidate.startIndex
        for character in needle {
            guard let found = candidate[index...].firstIndex(of: character) else { return false }
            index = candidate.index(after: found)
        }
        return true
    }

    private func score(
        candidate: String,
        input: String,
        characters: [Character]
    ) -> Double {
        let candidate = candidate.uppercased()
        let candidateCharacters = Array(candidate)
        var score = candidate == input ? -1_000.0 : 0
        if candidate.hasPrefix(input) { score -= 100 }

        var longestRun = 0
        var run = 0
        var candidateIndex = 0
        for character in characters {
            while candidateIndex < candidateCharacters.count,
                  candidateCharacters[candidateIndex] != character {
                run = 0
                candidateIndex += 1
            }
            if candidateIndex < candidateCharacters.count {
                run += 1
                candidateIndex += 1
                longestRun = max(longestRun, run)
            }
        }

        score -= Double(longestRun) * 10
        score -= Double(characters.count) * 2
        if let first = candidate.firstIndex(of: characters[0]),
           let last = candidate.lastIndex(of: characters[characters.count - 1]) {
            score += Double(candidate.distance(from: first, to: last)) * 0.5
        }
        score += Double(candidate.count) * 0.1
        return score
    }
}
