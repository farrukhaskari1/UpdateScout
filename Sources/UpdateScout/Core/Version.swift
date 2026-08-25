import Foundation

/// Loose comparison for the version formats emitted by supported ecosystems.
enum Version {
    private enum Component: Equatable {
        case number(Int)
        case text(String)
    }

    private struct Parsed {
        var core: [Component]
        var prerelease: [Component]?
    }

    private static func parse(_ raw: String) -> Parsed {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("v"), cleaned.dropFirst().first?.isNumber == true {
            cleaned.removeFirst()
        }
        if let plus = cleaned.firstIndex(of: "+") { cleaned = String(cleaned[..<plus]) }
        if let parenthesis = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<parenthesis]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Treat a dash as a SemVer prerelease separator only for a version-shaped
        // core. This avoids interpreting date versions such as 2024-06-01 as betas.
        var coreText = cleaned
        var prereleaseText: String?
        if cleaned.contains("."),
           let dash = cleaned.firstIndex(of: "-"),
           dash < cleaned.index(before: cleaned.endIndex) {
            coreText = String(cleaned[..<dash])
            prereleaseText = String(cleaned[cleaned.index(after: dash)...])
        }

        return Parsed(
            core: components(coreText),
            prerelease: prereleaseText.map(components)
        )
    }

    private static func components(_ text: String) -> [Component] {
        var parts: [Component] = []
        var buffer = ""
        var digits = false

        func flush() {
            guard !buffer.isEmpty else { return }
            parts.append(digits ? .number(Int(buffer) ?? 0) : .text(buffer.lowercased()))
            buffer = ""
        }

        for character in text {
            if character.isNumber {
                if !digits { flush(); digits = true }
                buffer.append(character)
            } else if character.isLetter {
                if digits { flush(); digits = false }
                buffer.append(character)
            } else {
                flush()
                digits = false
            }
        }
        flush()
        return parts
    }

    /// `.orderedAscending` means `lhs` is older than `rhs`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parse(lhs)
        let right = parse(rhs)
        let coreComparison = compare(left.core, right.core, missingNumbersAreZero: true)
        guard coreComparison == .orderedSame else { return coreComparison }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return .orderedSame
        case (nil, .some): return .orderedDescending
        case (.some, nil): return .orderedAscending
        case (.some(let lhsPrerelease), .some(let rhsPrerelease)):
            return compare(lhsPrerelease, rhsPrerelease, missingNumbersAreZero: false)
        }
    }

    private static func compare(
        _ lhs: [Component],
        _ rhs: [Component],
        missingNumbersAreZero: Bool
    ) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : nil
            let right = index < rhs.count ? rhs[index] : nil
            switch (left, right) {
            case (nil, nil): return .orderedSame
            case (nil, .some(.number(0))) where missingNumbersAreZero: continue
            case (.some(.number(0)), nil) where missingNumbersAreZero: continue
            case (nil, .some): return .orderedAscending
            case (.some, nil): return .orderedDescending
            case (.some(.number(let l)), .some(.number(let r))):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            case (.some(.text(let l)), .some(.text(let r))):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            case (.some(.number), .some(.text)):
                // SemVer prerelease numbers sort before text; in the loose core
                // comparator a concrete numeric component sorts after a tag.
                return missingNumbersAreZero ? .orderedDescending : .orderedAscending
            case (.some(.text), .some(.number)):
                return missingNumbersAreZero ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard isUsable(candidate), isUsable(installed) else { return false }
        return compare(installed, candidate) == .orderedAscending
    }

    static func isUsable(_ raw: String) -> Bool { raw.contains(where: \.isNumber) }

    static func highest(_ versions: [String]) -> String? {
        versions.max { compare($0, $1) == .orderedAscending }
    }

    static func bump(from installed: String, to latest: String) -> Bump {
        let lhs = parse(installed).core
        let rhs = parse(latest).core
        func number(_ list: [Component], _ index: Int) -> Int? {
            guard index < list.count, case .number(let number) = list[index] else { return nil }
            return number
        }
        if let l = number(lhs, 0), let r = number(rhs, 0), l != r { return .major }
        if let l = number(lhs, 1), let r = number(rhs, 1), l != r { return .minor }
        return .patch
    }

    enum Bump: Equatable, Sendable { case major, minor, patch }
}
