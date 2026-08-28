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
            let item = QueuedMail(
                uid: env.uid,
                from: env.from,
                subject: env.subject,
                date: env.date,
                queuedAt: now
            )
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
            messages: newItems.map { WebhookMsg(from: $0.from, subject: $0.subject, date: $0.date) }
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
}

struct WebhookBody: Codable {
    var new_count: Int
    var queued_count: Int
    var messages: [WebhookMsg]
}

struct WebhookMsg: Codable {
    var from: String
    var subject: String
    var date: String
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
