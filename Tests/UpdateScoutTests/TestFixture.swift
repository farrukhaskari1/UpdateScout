import Foundation

enum TestFixture {
    static func data(_ name: String, extension fileExtension: String) throws -> Data {
        let url = try requireURL(name, extension: fileExtension)
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, extension fileExtension: String) throws -> String {
        String(decoding: try data(name, extension: fileExtension), as: UTF8.self)
    }

    private static func requireURL(_ name: String, extension fileExtension: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            throw FixtureError.missing("\(name).\(fileExtension)")
        }
        return url
    }

    private enum FixtureError: Error { case missing(String) }
}
