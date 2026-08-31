import Foundation
import Network

enum IMAPError: LocalizedError {
    case connectFailed
    case greeting
    case loginFailed
    case selectFailed
    case commandFailed
    case timeout
    case cancelled
    case invalidPassword

    var errorDescription: String? {
        switch self {
        case .connectFailed: return "IMAP TLS connection failed"
        case .greeting: return "IMAP server greeting was not OK"
        case .loginFailed: return "IMAP login failed"
        case .selectFailed: return "IMAP SELECT INBOX failed"
        case .commandFailed: return "IMAP command failed"
        case .timeout: return "IMAP timed out"
        case .cancelled: return "IMAP connection cancelled"
        case .invalidPassword: return "IMAP password contains unsupported control characters"
        }
    }
}

struct IMAPEnvelope {
    var uid: UInt32
    var from: String
    var subject: String
    var date: String
    var auth: MailAuth
}

/// Minimal IMAP4rev1 client over Network.framework implicit TLS (port 993).
/// Commands used: CAPABILITY, LOGIN, SELECT INBOX, UID SEARCH, UID FETCH, LOGOUT.
final class IMAPClient {
    private let connection: NWConnection
    private let nwQueue = DispatchQueue(label: "com.grokbot.permissionshelper.imap")
    private let bufLock = NSLock()
    private var buffer = Data()
    private var tagSeq = 0
    private let ioTimeout: TimeInterval = 30

    init(host: String, port: Int) {
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        let raw = UInt16(clamping: port <= 0 ? 993 : port)
        guard let nwPort = NWEndpoint.Port(rawValue: raw) else {
            fatalError("invalid IMAP port")
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
    }

    deinit {
        connection.cancel()
    }

    /// Connect, LOGIN, SELECT INBOX. Returns UIDVALIDITY (0 if the server omitted it).
    func connectAndLogin(username: String, password: String) throws -> UInt32 {
        if password.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }) {
            throw IMAPError.invalidPassword
        }
        try waitReady()
        let greet = try readLine()
        guard greet.uppercased().hasPrefix("* OK") else { throw IMAPError.greeting }
        _ = try? runCommand("CAPABILITY")
        let login = try runCommand("LOGIN \(Self.quote(username)) \(Self.quote(password))")
        guard login.ok else { throw IMAPError.loginFailed }
        let sel = try runCommand("SELECT INBOX")
        guard sel.ok else { throw IMAPError.selectFailed }
        return Self.parseUIDValidity(sel.untagged) ?? 0
    }

    func searchUnseenAndNew(afterUID: UInt32) throws -> [UInt32] {
        var ids = Set<UInt32>()
        let unseen = try runCommand("UID SEARCH UNSEEN")
        guard unseen.ok else { throw IMAPError.commandFailed }
        Self.parseSearch(unseen.untagged).forEach { ids.insert($0) }
        if afterUID > 0 {
            let newer = try runCommand("UID SEARCH UID \(afterUID + 1):*")
            if newer.ok {
                Self.parseSearch(newer.untagged).forEach { ids.insert($0) }
            }
        }
        return ids.filter { $0 > 0 }.sorted()
    }

    func fetchHeaders(uids: [UInt32]) throws -> [IMAPEnvelope] {
        guard !uids.isEmpty else { return [] }
        var out: [IMAPEnvelope] = []
        var i = 0
        while i < uids.count {
            let end = min(i + 20, uids.count)
            let slice = uids[i..<end]
            let set = slice.map(String.init).joined(separator: ",")
            let resp = try runCommand("UID FETCH \(set) (UID RFC822.HEADER)")
            guard resp.ok else { throw IMAPError.commandFailed }
            out.append(contentsOf: Self.parseFetch(resp.blob))
            i = end
        }
        return out
    }

    func logout() {
        _ = try? runCommand("LOGOUT")
        connection.cancel()
    }

    // MARK: - Wire

    private struct IMAPReply {
        var ok: Bool
        var untagged: [String]
        var blob: String
    }

    private func waitReady() throws {
        let sem = DispatchSemaphore(value: 0)
        let once = NSLock()
        var done = false
        var readyError: IMAPError?
        func finish(_ err: IMAPError?) {
            once.lock()
            defer { once.unlock() }
            if done { return }
            done = true
            readyError = err
            sem.signal()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(nil)
            case .failed:
                finish(.connectFailed)
            case .cancelled:
                finish(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: nwQueue)
        if sem.wait(timeout: .now() + ioTimeout) == .timedOut {
            connection.cancel()
            throw IMAPError.timeout
        }
        if let readyError { throw readyError }
    }

    private func nextTag() -> String {
        tagSeq += 1
        return "A\(tagSeq)"
    }

    private func sendLine(_ s: String) throws {
        let data = Data((s + "\r\n").utf8)
        let sem = DispatchSemaphore(value: 0)
        var failed = false
        connection.send(content: data, completion: .contentProcessed { err in
            if err != nil { failed = true }
            sem.signal()
        })
        if sem.wait(timeout: .now() + ioTimeout) == .timedOut {
            throw IMAPError.timeout
        }
        if failed { throw IMAPError.commandFailed }
    }

    private func runCommand(_ command: String) throws -> IMAPReply {
        let tag = nextTag()
        try sendLine("\(tag) \(command)")
        var untagged: [String] = []
        var blob = ""
        while true {
            let pair = try readLineOrLiteral()
            blob += pair.line + "\n"
            if let lit = pair.literal {
                blob += (String(data: lit, encoding: .utf8) ?? String(decoding: lit, as: UTF8.self))
                blob += "\n"
            }
            if pair.line.hasPrefix("* ") || pair.line.hasPrefix("+ ") {
                untagged.append(pair.line)
                continue
            }
            if pair.line.hasPrefix(tag + " ") {
                let rest = pair.line.dropFirst(tag.count + 1)
                let ok = rest.uppercased().hasPrefix("OK")
                return IMAPReply(ok: ok, untagged: untagged, blob: blob)
            }
            untagged.append(pair.line)
        }
    }

    private func readLineOrLiteral() throws -> (line: String, literal: Data?) {
        let line = try readLine()
        if let n = Self.literalSize(line) {
            let data = try readBytes(n)
            return (line, data)
        }
        return (line, nil)
    }

    private func readLine() throws -> String {
        while true {
            bufLock.lock()
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                bufLock.unlock()
                return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
            }
            bufLock.unlock()
            try receiveMore()
        }
    }

    private func readBytes(_ n: Int) throws -> Data {
        while true {
            bufLock.lock()
            if buffer.count >= n {
                let data = Data(buffer.prefix(n))
                buffer.removeSubrange(0..<n)
                bufLock.unlock()
                return data
            }
            bufLock.unlock()
            try receiveMore()
        }
    }

    private func receiveMore() throws {
        let sem = DispatchSemaphore(value: 0)
        var failed = false
        var complete = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if error != nil {
                failed = true
            } else if let data, !data.isEmpty {
                self.bufLock.lock()
                self.buffer.append(data)
                self.bufLock.unlock()
            } else if isComplete {
                complete = true
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + ioTimeout) == .timedOut {
            throw IMAPError.timeout
        }
        if failed { throw IMAPError.connectFailed }
        if complete {
            bufLock.lock()
            let empty = buffer.isEmpty
            bufLock.unlock()
            if empty { throw IMAPError.cancelled }
        }
    }

    // MARK: - Parse

    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func literalSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        var inner = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if inner.hasSuffix("+") {
            inner = inner.dropLast()
        }
        guard !inner.isEmpty, inner.allSatisfy({ $0.isNumber }), let n = Int(inner) else { return nil }
        return n
    }

    static func parseUIDValidity(_ lines: [String]) -> UInt32? {
        for line in lines {
            let u = line.uppercased()
            guard let r = u.range(of: "[UIDVALIDITY ") else { continue }
            let idx = line.index(line.startIndex, offsetBy: u.distance(from: u.startIndex, to: r.upperBound))
            let num = line[idx...].prefix(while: { $0.isNumber })
            if let v = UInt32(num) { return v }
        }
        return nil
    }

    static func parseSearch(_ lines: [String]) -> [UInt32] {
        var ids: [UInt32] = []
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2, parts[0] == "*", parts[1].uppercased() == "SEARCH" else { continue }
            for p in parts.dropFirst(2) {
                if let v = UInt32(p) { ids.append(v) }
            }
        }
        return ids
    }

    static func parseFetch(_ blob: String) -> [IMAPEnvelope] {
        var results: [IMAPEnvelope] = []
        var current = ""
        func flush() {
            let t = current
            current = ""
            guard !t.isEmpty, let env = envelope(fromFetch: t) else { return }
            results.append(env)
        }
        for line in blob.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("* ") && s.uppercased().contains("FETCH") {
                flush()
                current = s + "\n"
            } else {
                current += s + "\n"
            }
        }
        flush()
        return results
    }

    static func envelope(fromFetch text: String) -> IMAPEnvelope? {
        var uid: UInt32 = 0
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
        for i in 0..<parts.count {
            if parts[i].uppercased() == "UID", i + 1 < parts.count, let v = UInt32(parts[i + 1]) {
                uid = v
                break
            }
        }
        guard uid > 0 else { return nil }
        let headers = parseRFC822Headers(text)
        return IMAPEnvelope(
            uid: uid,
            from: headers["from"] ?? "",
            subject: decodeRFC2047(headers["subject"] ?? ""),
            date: headers["date"] ?? "",
            auth: MailAuthParser.parse(text)
        )
    }

    static func parseRFC822Headers(_ raw: String) -> [String: String] {
        let unfolded = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
        var dict: [String: String] = [:]
        for line in unfolded.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "from" || name == "subject" || name == "date" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            dict[name] = value
        }
        return dict
    }

    static func decodeRFC2047(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else {
            return s
        }
        let ns = s as NSString
        var result = s
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            guard m.numberOfRanges == 4,
                  let charsetR = Range(m.range(at: 1), in: s),
                  let encR = Range(m.range(at: 2), in: s),
                  let textR = Range(m.range(at: 3), in: s),
                  let fullR = Range(m.range(at: 0), in: result) else { continue }
            let charset = String(s[charsetR])
            let enc = String(s[encR]).uppercased()
            let text = String(s[textR])
            let decoded: String
            if enc == "B" {
                guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { continue }
                decoded = decodeData(data, charset: charset)
            } else {
                decoded = decodeQuotedPrintableWord(text, charset: charset)
            }
            result.replaceSubrange(fullR, with: decoded)
        }
        return result
    }

    static func decodeQuotedPrintableWord(_ text: String, charset: String) -> String {
        var bytes = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "_" {
                bytes.append(0x20)
                i = text.index(after: i)
            } else if c == "=", let hexEnd = text.index(i, offsetBy: 3, limitedBy: text.endIndex) {
                let hex = text[text.index(after: i)..<hexEnd]
                if let b = UInt8(hex, radix: 16) {
                    bytes.append(b)
                    i = hexEnd
                } else {
                    bytes.append(contentsOf: String(c).utf8)
                    i = text.index(after: i)
                }
            } else {
                bytes.append(contentsOf: String(c).utf8)
                i = text.index(after: i)
            }
        }
        return decodeData(bytes, charset: charset)
    }

    static func decodeData(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "us-ascii", "ascii": encoding = .ascii
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }
}
