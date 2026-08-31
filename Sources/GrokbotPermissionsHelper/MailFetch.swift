import AppKit
import Foundation

enum MailFetchError: LocalizedError {
    case noWebhook
    case badWebhook
    case webhookTimeout
    case webhookFailed
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noWebhook: return "No webhook URL in Keychain"
        case .badWebhook: return "Webhook URL is not valid"
        case .webhookTimeout: return "Webhook timed out"
        case .webhookFailed: return "Webhook request failed"
        case .httpStatus(let c): return "Webhook HTTP \(c)"
        }
    }
}

enum MailFetch {
    static let cooldown: TimeInterval = 3 * 60 * 60
    static let maxQueue = 200
    static var delegate: MailFetchDelegate?

    static func run(forceWebhook: Bool) {
        let app = NSApplication.shared
        let d = MailFetchDelegate(forceWebhook: forceWebhook)
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("GrokbotPermissionsHelper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var queueURL: URL {
        supportDir.appendingPathComponent("queue.json")
    }

    static var lastWebhookURL: URL {
        supportDir.appendingPathComponent("last-webhook")
    }

    static func perform(forceWebhook: Bool) throws {
        let config = try MailKeychain.load()
        log("MAIL: connecting")
        let client = IMAPClient(host: config.host, port: config.port)
        let uidValidity = try client.connectAndLogin(username: config.username, password: config.password)
        log("MAIL: connected")

        var queue = loadQueue()
        if uidValidity != 0 && queue.uidValidity != 0 && queue.uidValidity != uidValidity {
            queue.lastUID = 0
        }
        if uidValidity != 0 {
            queue.uidValidity = uidValidity
        }

        let known: Set<UInt32>
        if queue.uidValidity == uidValidity || uidValidity == 0 {
            known = Set(queue.messages.map(\.uid))
        } else {
            known = []
        }

        let candidates = try client.searchUnseenAndNew(afterUID: queue.lastUID)
        let newUIDs = candidates.filter { !known.contains($0) }
        log("MAIL: unseen/new \(candidates.count) (new to queue \(newUIDs.count))")

        let cap = Array(newUIDs.prefix(50))
        let envelopes = try client.fetchHeaders(uids: cap)
        client.logout()

        let now = ISO8601DateFormatter().string(from: Date())
        var added: [QueuedMail] = []
        var seen = known
        for env in envelopes {
            if seen.contains(env.uid) { continue }
            seen.insert(env.uid)
            let item = QueuedMail(from: env, queuedAt: now)
            queue.messages.append(item)
            added.append(item)
            if env.uid > queue.lastUID {
                queue.lastUID = env.uid
            }
        }
        for uid in cap where uid > queue.lastUID {
            queue.lastUID = uid
        }
        if queue.messages.count > maxQueue {
            queue.messages = Array(queue.messages.suffix(maxQueue))
        }
        try saveQueue(queue)
        log("MAIL: queued \(added.count) new (total \(queue.messages.count))")

        let shouldPost: Bool
        if added.isEmpty {
            shouldPost = false
            log("MAIL: no new messages")
        } else if forceWebhook {
            shouldPost = true
        } else if webhookCooldownActive() {
            shouldPost = false
            log("MAIL: webhook skipped (cooldown)")
        } else {
            shouldPost = true
        }

        guard shouldPost else { return }
        guard let hook = config.webhookURL, !hook.isEmpty else {
            log("MAIL: webhook skipped (not configured)")
            return
        }
        try postWebhook(config: config, urlString: hook, newItems: added, queuedCount: queue.messages.count)
        recordWebhook()
        log("MAIL: webhook posted (\(added.count) new)")
    }

    static func webhookCooldownActive() -> Bool {
        guard let raw = try? String(contentsOf: lastWebhookURL, encoding: .utf8) else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601DateFormatter().date(from: trimmed) else { return false }
        return Date().timeIntervalSince(date) < cooldown
    }

    static func recordWebhook() {
        let s = ISO8601DateFormatter().string(from: Date())
        try? s.write(to: lastWebhookURL, atomically: true, encoding: .utf8)
    }

    static func loadQueue() -> MailQueue {
        guard let data = try? Data(contentsOf: queueURL) else {
            return MailQueue(uidValidity: 0, lastUID: 0, messages: [])
        }
        return (try? JSONDecoder().decode(MailQueue.self, from: data))
            ?? MailQueue(uidValidity: 0, lastUID: 0, messages: [])
    }

    static func saveQueue(_ queue: MailQueue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(queue)
        try data.write(to: queueURL, options: .atomic)
    }

    static func postWebhook(config: MailKeychain.Config, urlString: String, newItems: [QueuedMail], queuedCount: Int) throws {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw MailFetchError.badWebhook
        }
        let bodyObj = WebhookBody(
            new_count: newItems.count,
            queued_count: queuedCount,
            messages: newItems.map { WebhookMsg(from: $0) }
        )
        let body = try JSONEncoder().encode(bodyObj)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("GrokbotPermissionsHelper/1.1", forHTTPHeaderField: "User-Agent")
        if let token = config.bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        req.timeoutInterval = 30

        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var failed = false
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if err != nil { failed = true }
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 35) == .timedOut {
            throw MailFetchError.webhookTimeout
        }
        if failed { throw MailFetchError.webhookFailed }
        if status < 200 || status >= 300 {
            throw MailFetchError.httpStatus(status)
        }
    }

    static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

struct MailQueue: Codable {
    var uidValidity: UInt32
    var lastUID: UInt32
    var messages: [QueuedMail]
}

struct QueuedMail: Codable {
    var uid: UInt32
    var from: String
    var subject: String
    var date: String
    var queuedAt: String
    var spf: String
    var dkim: String
    var dmarc: String
    var dkim_d: String
    var dmarc_policy: String
    var header_from_domain: String
    var envelope_from: String
    var return_path: String
    var reply_to: String
    var message_id_domain: String
    var authentication_results: String
    var header_url_hosts: [String]

    init(from env: IMAPEnvelope, queuedAt: String) {
        uid = env.uid
        from = env.from
        subject = env.subject
        date = env.date
        self.queuedAt = queuedAt
        spf = env.auth.spf
        dkim = env.auth.dkim
        dmarc = env.auth.dmarc
        dkim_d = env.auth.dkimD
        dmarc_policy = env.auth.dmarcPolicy
        header_from_domain = env.auth.headerFromDomain
        envelope_from = env.auth.envelopeFrom
        return_path = env.auth.returnPath
        reply_to = env.auth.replyTo
        message_id_domain = env.auth.messageIdDomain
        authentication_results = env.auth.authenticationResults
        header_url_hosts = env.auth.headerUrlHosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(UInt32.self, forKey: .uid)
        from = try c.decode(String.self, forKey: .from)
        subject = try c.decode(String.self, forKey: .subject)
        date = try c.decode(String.self, forKey: .date)
        queuedAt = try c.decode(String.self, forKey: .queuedAt)
        spf = try c.decodeIfPresent(String.self, forKey: .spf) ?? "none"
        dkim = try c.decodeIfPresent(String.self, forKey: .dkim) ?? "none"
        dmarc = try c.decodeIfPresent(String.self, forKey: .dmarc) ?? "none"
        dkim_d = try c.decodeIfPresent(String.self, forKey: .dkim_d) ?? ""
        dmarc_policy = try c.decodeIfPresent(String.self, forKey: .dmarc_policy) ?? ""
        header_from_domain = try c.decodeIfPresent(String.self, forKey: .header_from_domain) ?? ""
        envelope_from = try c.decodeIfPresent(String.self, forKey: .envelope_from) ?? ""
        return_path = try c.decodeIfPresent(String.self, forKey: .return_path) ?? ""
        reply_to = try c.decodeIfPresent(String.self, forKey: .reply_to) ?? ""
        message_id_domain = try c.decodeIfPresent(String.self, forKey: .message_id_domain) ?? ""
        authentication_results = try c.decodeIfPresent(String.self, forKey: .authentication_results) ?? ""
        header_url_hosts = try c.decodeIfPresent([String].self, forKey: .header_url_hosts) ?? []
    }
}

struct WebhookBody: Codable {
    var new_count: Int
    var queued_count: Int
    var messages: [WebhookMsg]
}

struct WebhookMsg: Codable {
    var uid: UInt32
    var from: String
    var subject: String
    var date: String
    var spf: String
    var dkim: String
    var dmarc: String
    var dkim_d: String
    var dmarc_policy: String
    var header_from_domain: String
    var envelope_from: String
    var return_path: String
    var reply_to: String
    var message_id_domain: String
    var authentication_results: String
    var header_url_hosts: [String]

    init(from item: QueuedMail) {
        uid = item.uid
        from = item.from
        subject = item.subject
        date = item.date
        spf = item.spf
        dkim = item.dkim
        dmarc = item.dmarc
        dkim_d = item.dkim_d
        dmarc_policy = item.dmarc_policy
        header_from_domain = item.header_from_domain
        envelope_from = item.envelope_from
        return_path = item.return_path
        reply_to = item.reply_to
        message_id_domain = item.message_id_domain
        authentication_results = item.authentication_results
        header_url_hosts = item.header_url_hosts
    }
}

final class MailFetchDelegate: NSObject, NSApplicationDelegate {
    let forceWebhook: Bool

    init(forceWebhook: Bool) {
        self.forceWebhook = forceWebhook
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try MailFetch.perform(forceWebhook: self.forceWebhook)
            } catch {
                let msg = "MAIL_ERROR: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
