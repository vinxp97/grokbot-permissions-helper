import Foundation

/// Structured auth parsed from an RFC822 header block (the same RFC822.HEADER
/// IMAP already FETCHes). No body. Missing Authentication-Results never becomes pass.
struct MailAuth {
    var spf: String = "none"
    var dkim: String = "none"
    var dmarc: String = "none"
    var dkimD: String = ""
    var dmarcPolicy: String = ""
    var headerFromDomain: String = ""
    var envelopeFrom: String = ""
    var returnPath: String = ""
    var replyTo: String = ""
    var messageIdDomain: String = ""
    var authenticationResults: String = ""
    var headerUrlHosts: [String] = []

    func jsonObject() -> [String: Any] {
        [
            "spf": spf,
            "dkim": dkim,
            "dmarc": dmarc,
            "dkim_d": dkimD,
            "dmarc_policy": dmarcPolicy,
            "header_from_domain": headerFromDomain,
            "envelope_from": envelopeFrom,
            "return_path": returnPath,
            "reply_to": replyTo,
            "message_id_domain": messageIdDomain,
            "authentication_results": authenticationResults,
            "header_url_hosts": headerUrlHosts,
        ]
    }
}

enum MailAuthParser {
    /// If several Authentication-Results headers exist, the first in the header
    /// block is treated as inbound MX (servers prepend). Later AR lines only
    /// fill methods the first one did not mention.
    static func parse(_ raw: String) -> MailAuth {
        var auth = MailAuth()
        let fields = headerFields(raw)
        auth.headerUrlHosts = urlHosts(raw)

        let ars = fields.compactMap { $0.name == "authentication-results" ? $0.value : nil }
        if !ars.isEmpty {
            auth.authenticationResults = ars.joined(separator: "\n")
            var seen: Set<String> = []
            for ar in ars {
                applyAR(ar, into: &auth, seen: &seen)
            }
        }

        func first(_ name: String) -> String {
            fields.first(where: { $0.name == name })?.value ?? ""
        }

        let rp = first("return-path")
        auth.returnPath = rp
        auth.envelopeFrom = angleOrBare(rp)
        auth.headerFromDomain = emailDomain(first("from"))
        auth.replyTo = first("reply-to")
        auth.messageIdDomain = emailDomain(first("message-id"))
        return auth
    }

    private struct Field {
        var name: String
        var value: String
    }

    private static func headerFields(_ raw: String) -> [Field] {
        let unfolded = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
        var out: [Field] = []
        for line in unfolded.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out.append(Field(name: name, value: String(value)))
        }
        return out
    }

    private static func applyAR(_ ar: String, into auth: inout MailAuth, seen: inout Set<String>) {
        guard let re = try? NSRegularExpression(
            pattern: #"\b(spf|dkim|dmarc)=(pass|fail|softfail|none|neutral|temperror|permerror|policy|bestguesspass)\b"#,
            options: [.caseInsensitive]
        ) else { return }
        let ns = ar as NSString
        for m in re.matches(in: ar, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges == 3,
                  let methodR = Range(m.range(at: 1), in: ar),
                  let resR = Range(m.range(at: 2), in: ar) else { continue }
            let method = String(ar[methodR]).lowercased()
            if seen.contains(method) { continue }
            seen.insert(method)
            let mapped = mapVerdict(String(ar[resR]))
            switch method {
            case "spf": auth.spf = mapped
            case "dkim":
                auth.dkim = mapped
                if auth.dkimD.isEmpty, let d = firstMatch(ar, pattern: #"header\.d=([^\s;]+)"#) {
                    auth.dkimD = d.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
            case "dmarc":
                auth.dmarc = mapped
                if auth.dmarcPolicy.isEmpty {
                    let start = m.range(at: 0).location
                    let slice = ns.substring(with: NSRange(location: start, length: min(200, ns.length - start)))
                    if let p = firstMatch(slice, pattern: #"\bp=([a-z]+)"#) {
                        auth.dmarcPolicy = p.lowercased()
                    }
                }
            default:
                break
            }
        }
    }

    private static func mapVerdict(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pass", "bestguesspass": return "pass"
        case "fail", "softfail", "permerror", "temperror", "policy": return "fail"
        default: return "none"
        }
    }

    private static func urlHosts(_ raw: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://([^/\s\"'<>]+)"#, options: [.caseInsensitive]) else {
            return []
        }
        let ns = raw as NSString
        var hosts: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: raw) else { continue }
            var host = String(raw[r]).lowercased()
            if let colon = host.firstIndex(of: ":"), !host.contains("]") {
                host = String(host[..<colon])
            }
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty, !seen.contains(host) else { continue }
            seen.insert(host)
            hosts.append(host)
        }
        return hosts
    }

    private static func emailDomain(_ s: String) -> String {
        let inner = angleOrBare(s)
        guard let at = inner.lastIndex(of: "@") else { return "" }
        return String(inner[inner.index(after: at)...])
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ">."))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func angleOrBare(_ s: String) -> String {
        if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">"), gt > lt {
            return String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }
}
