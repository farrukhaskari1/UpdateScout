import Foundation
import Testing
@testable import UpdateScout

struct VersionTests {
    @Test(arguments: [
        ("1.2", "1.2.0", ComparisonResult.orderedSame),
        ("v4.0", "4.0.1", .orderedAscending),
        ("3.1.0-beta.2", "3.1.0", .orderedAscending),
        ("1.0-rc1", "1.0", .orderedAscending),
        ("3.1.0-1", "3.1.0", .orderedAscending),
        ("3.1.0-beta.2", "3.1.0-beta.10", .orderedAscending),
        ("1.2.3+build.1", "1.2.3+build.9", .orderedSame),
        ("2024.06.1", "2024.10.0", .orderedAscending),
        ("2024-06-01", "2024-07-01", .orderedAscending),
        ("1.2.3_1", "1.2.3_2", .orderedAscending),
        ("1.2.rc", "1.2.0", .orderedAscending)
    ])
    func comparison(case value: (String, String, ComparisonResult)) {
        #expect(Version.compare(value.0, value.1) == value.2)
    }

    @Test func rejectsPlaceholders() {
        #expect(!Version.isNewer("latest", than: "1.0"))
        #expect(!Version.isNewer("2.0", than: "—"))
    }

    @Test func classifiesBumps() {
        #expect(Version.bump(from: "1.2.3", to: "2.0.0") == .major)
        #expect(Version.bump(from: "1.2.3", to: "1.3.0") == .minor)
        #expect(Version.bump(from: "1.2.3", to: "1.2.4") == .patch)
    }
}
