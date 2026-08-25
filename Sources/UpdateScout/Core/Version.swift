import Foundation

/// Loose, forgiving version comparison.
///
/// Handles the real-world mess: `1.2.3`, `2024.06.1`, `1.2.3_1`, `v4.0`,
/// `3.1.0-beta.2`, `14.3 (23E214)`, `1.2.3+build`.
enum Version {

    /// Split into comparable components. Numeric runs compare numerically,
    /// alphabetic runs lexically.
    private static func components(_ raw: String) -> [Either] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("v"), cleaned.dropFirst().first?.isNumber == true {
            cleaned = String(cleaned.dropFirst())
        }
        // Drop build metadata and parenthesised build numbers.
        if let plus = cleaned.firstIndex(of: "+") { cleaned = String(cleaned[..<plus]) }
        if let paren = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<paren]) }

        var parts: [Either] = []
        var buffer = ""
        var bufferIsDigits = false

        func flush() {
            guard !buffer.isEmpty else { return }
            parts.append(bufferIsDigits ? .number(Int(buffer) ?? 0) : .text(buffer.lowercased()))
            buffer = ""
        }

        for ch in cleaned {
            if ch.isNumber {
                if !bufferIsDigits { flush(); bufferIsDigits = true }
                buffer.append(ch)
            } else if ch.isLetter {
                if bufferIsDigits { flush(); bufferIsDigits = false }
                buffer.append(ch)
            } else {
                flush()
                bufferIsDigits = false
            }
        }
        flush()
        return parts
    }

    private enum Either {
        case number(Int)
        case text(String)

        /// Pre-release identifiers sort below a bare release.
        var isPrerelease: Bool {
            if case .text(let s) = self {
                return ["alpha", "beta", "rc", "pre", "dev", "snapshot", "nightly"].contains(s)
            }
            return false
        }
    }

    /// `.orderedAscending` means `lhs` is older than `rhs`.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        let count = max(a.count, b.count)

        for index in 0..<count {
            let left = index < a.count ? a[index] : nil
            let right = index < b.count ? b[index] : nil

            switch (left, right) {
            case (nil, .some(let r)):
                // "1.2" vs "1.2.0" are the same release — a missing component is zero.
                if case .number(0) = r { continue }
                // "1.2" vs "1.2.1": shorter is older, unless the extra part is a prerelease tag.
                return r.isPrerelease ? .orderedDescending : .orderedAscending
            case (.some(let l), nil):
                if case .number(0) = l { continue }
                return l.isPrerelease ? .orderedAscending : .orderedDescending
            case (.some(.number(let l)), .some(.number(let r))):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            case (.some(.text(let l)), .some(.text(let r))):
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            case (.some(.number), .some(.text)):
                return .orderedDescending   // 1.2.0 > 1.2.rc
            case (.some(.text), .some(.number)):
                return .orderedAscending
            case (nil, nil):
                break
            }
        }
        return .orderedSame
    }

    /// True when `candidate` is strictly newer than `installed`.
    ///
    /// Refuses to answer when either side isn't a version at all — placeholders
    /// like "—", "latest" or "" would otherwise compare as infinitely old and
    /// report a phantom update.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard isUsable(candidate), isUsable(installed) else { return false }
        return compare(installed, candidate) == .orderedAscending
    }

    static func isUsable(_ raw: String) -> Bool {
        raw.contains(where: \.isNumber)
    }

    /// Highest version in a list.
    static func highest(_ versions: [String]) -> String? {
        versions.max { compare($0, $1) == .orderedAscending }
    }

    /// Classify the size of the jump, for the UI dot colour.
    static func bump(from installed: String, to latest: String) -> Bump {
        let a = components(installed)
        let b = components(latest)
        func number(_ list: [Either], _ index: Int) -> Int? {
            guard index < list.count, case .number(let n) = list[index] else { return nil }
            return n
        }
        if let a0 = number(a, 0), let b0 = number(b, 0), a0 != b0 { return .major }
        if let a1 = number(a, 1), let b1 = number(b, 1), a1 != b1 { return .minor }
        return .patch
    }

    enum Bump {
        case major, minor, patch
    }
}
