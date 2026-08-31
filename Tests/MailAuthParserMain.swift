import Foundation

@main
struct MailAuthParserMain {
    static func main() throws {
        let root: URL
        if CommandLine.arguments.count > 1 {
            root = URL(fileURLWithPath: CommandLine.arguments[1])
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let dir = root.appendingPathComponent("Tests/MailAuthFixtures")
        var failed = 0
        for name in ["pass", "fail", "missing-ar"] {
            let raw = try String(contentsOf: dir.appendingPathComponent("\(name).headers"), encoding: .utf8)
            let expectedData = try Data(contentsOf: dir.appendingPathComponent("\(name).json"))
            guard let expected = try JSONSerialization.jsonObject(with: expectedData) as? [String: Any] else {
                fputs("FAIL \(name): expected JSON is not an object\n", stderr)
                failed += 1
                continue
            }
            let got = MailAuthParser.parse(raw).jsonObject()
            if !NSDictionary(dictionary: got).isEqual(to: expected) {
                fputs("FAIL \(name)\n got: \(got)\n expected: \(expected)\n", stderr)
                failed += 1
            } else {
                print("OK \(name)")
            }
        }
        if failed > 0 {
            exit(1)
        }
    }
}
