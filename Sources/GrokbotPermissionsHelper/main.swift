import AppKit
import Contacts
import EventKit
import Foundation

/// Grokbot Permissions Helper
/// Accessory macOS app that requests TCC access (once), dumps a text snapshot, then quits.
/// Command-line Swift cannot raise Calendar/Contacts/Reminders prompts; this .app can.

final class AppDelegate: NSObject, NSApplicationDelegate {
    let eventStore = EKEventStore()
    let contactStore = CNContactStore()
    let group = DispatchGroup()
    var lines: [String] = []
    let lineLock = NSLock()

    var outURL: URL {
        let path = ProcessInfo.processInfo.environment["GROKBOT_HELPER_OUT"]
            ?? "/tmp/grokbot-permissions-helper-out.txt"
        return URL(fileURLWithPath: path)
    }

    var calendarHorizonDays: Int {
        intEnv("GROKBOT_HELPER_CAL_DAYS", default: 3)
    }

    var reminderLookbackDays: Int {
        intEnv("GROKBOT_HELPER_REM_LOOKBACK_DAYS", default: 7)
    }

    var reminderForwardDays: Int {
        intEnv("GROKBOT_HELPER_REM_FORWARD_DAYS", default: 14)
    }

    var contactSampleLimit: Int {
        intEnv("GROKBOT_HELPER_CONTACT_SAMPLES", default: 8)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        let conStatus = CNContactStore.authorizationStatus(for: .contacts)
        let needsPrompt =
            calStatus == .notDetermined ||
            remStatus == .notDetermined ||
            conStatus == .notDetermined

        // Only come to the front when macOS still needs an Allow dialog.
        if needsPrompt {
            NSApp.activate(ignoringOtherApps: true)
        }

        append("NOW: \(ISO8601DateFormatter().string(from: Date()))")
        append("CAL_STATUS: \(Self.label(calStatus))")
        append("REM_STATUS: \(Self.label(remStatus))")
        append("CON_STATUS: \(Self.contactLabel(conStatus))")

        group.enter()
        if calStatus == .fullAccess {
            append("CALENDAR: granted")
            dumpCalendars()
            group.leave()
        } else if calStatus == .notDetermined {
            eventStore.requestFullAccessToEvents { granted, error in
                self.append("CALENDAR: \(granted ? "granted" : "denied") \(error?.localizedDescription ?? "")")
                if granted { self.dumpCalendars() }
                self.group.leave()
            }
        } else {
            append("CALENDAR: denied")
            group.leave()
        }

        group.enter()
        if remStatus == .fullAccess {
            append("REMINDERS: granted")
            DispatchQueue.global().async {
                self.dumpReminders()
                self.group.leave()
            }
        } else if remStatus == .notDetermined {
            eventStore.requestFullAccessToReminders { granted, error in
                self.append("REMINDERS: \(granted ? "granted" : "denied") \(error?.localizedDescription ?? "")")
                if granted {
                    DispatchQueue.global().async {
                        self.dumpReminders()
                        self.group.leave()
                    }
                } else {
                    self.group.leave()
                }
            }
        } else {
            append("REMINDERS: denied")
            group.leave()
        }

        group.enter()
        if conStatus == .authorized {
            append("CONTACTS: granted")
            dumpContacts()
            group.leave()
        } else if conStatus == .notDetermined {
            contactStore.requestAccess(for: .contacts) { granted, error in
                self.append("CONTACTS: \(granted ? "granted" : "denied") \(error?.localizedDescription ?? "")")
                if granted { self.dumpContacts() }
                self.group.leave()
            }
        } else {
            append("CONTACTS: denied")
            group.leave()
        }

        dumpHomeShortcuts()

        DispatchQueue.global().async {
            _ = self.group.wait(timeout: .now() + 90)
            self.finish()
        }
    }

    static func label(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown"
        }
    }

    static func contactLabel(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    func dumpCalendars() {
        let cals = eventStore.calendars(for: .event).sorted { $0.title < $1.title }
        append("CALENDARS: \(cals.count)")
        for c in cals {
            append("CAL\t\(c.title)\t\(c.source?.title ?? "?")")
        }

        var cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: calendarHorizonDays, to: start) else { return }
        let pred = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: pred).sorted { $0.startDate < $1.startDate }
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = cal.timeZone
        append("RANGE_START: \(fmt.string(from: start))")
        append("RANGE_END: \(fmt.string(from: end))")
        append("EVENTS: \(events.count)")
        for e in events {
            let title = e.title ?? "(no title)"
            let loc = e.location ?? ""
            let cname = e.calendar?.title ?? "?"
            let src = e.calendar?.source?.title ?? "?"
            let allDay = e.isAllDay ? "allday" : "timed"
            append("EVT\t\(allDay)\t\(fmt.string(from: e.startDate))\t\(fmt.string(from: e.endDate))\t\(cname)\t\(src)\t\(title)\t\(loc)")
        }
    }

    func dumpReminders() {
        let lists = eventStore.calendars(for: .reminder).sorted { $0.title < $1.title }
        append("REMINDER_LISTS: \(lists.count)")
        for list in lists {
            append("REMINDER_LIST\t\(list.title)\t\(list.source?.title ?? "?")")
        }
        let start = Date().addingTimeInterval(-60 * 60 * 24 * Double(reminderLookbackDays))
        let end = Date().addingTimeInterval(60 * 60 * 24 * Double(reminderForwardDays))
        let pred = eventStore.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        let sem = DispatchSemaphore(value: 0)
        eventStore.fetchReminders(matching: pred) { reminders in
            let items = reminders ?? []
            self.append("REMINDERS_INCOMPLETE: \(items.count)")
            for r in items.prefix(25) {
                let due: String
                if let d = r.dueDateComponents, let date = Calendar.current.date(from: d) {
                    due = ISO8601DateFormatter().string(from: date)
                } else {
                    due = "none"
                }
                self.append("REM\t\(r.calendar?.title ?? "?")\t\(r.title ?? "(no title)")\t\(due)")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
    }

    func dumpContacts() {
        let keys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var count = 0
        var samples: [String] = []
        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                count += 1
                if samples.count < self.contactSampleLimit {
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    let org = contact.organizationName
                    let email = (contact.emailAddresses.first?.value as String?) ?? ""
                    let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
                    let label = name.isEmpty ? org : name
                    samples.append("CONTACT\t\(label)\t\(email)\t\(phone)")
                }
            }
            append("CONTACTS_COUNT: \(count)")
            for s in samples { append(s) }
        } catch {
            append("CONTACTS_ERROR: \(error.localizedDescription)")
        }
    }

    func dumpHomeShortcuts() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        proc.arguments = ["list"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let names = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let homeish = names.filter { n in
                let l = n.lowercased()
                return l.contains("light") || l.contains("led") || l.contains("home") || l.contains("night")
            }
            append("HOME_VIA: Shortcuts (\(homeish.count) home-related of \(names.count) total)")
            for n in homeish { append("HOME_SHORTCUT\t\(n)") }
        } catch {
            append("HOME_SHORTCUTS_ERROR: \(error.localizedDescription)")
        }
    }

    func append(_ line: String) {
        lineLock.lock()
        lines.append(line)
        lineLock.unlock()
    }

    func finish() {
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func intEnv(_ key: String, default fallback: Int) -> Int {
        if let raw = ProcessInfo.processInfo.environment[key], let value = Int(raw), value > 0 {
            return value
        }
        return fallback
    }
}

let flags = Set(CommandLine.arguments.dropFirst())
if flags.contains("--help") || flags.contains("-h") {
    let help = """
    Grokbot Permissions Helper
      (no flags)     Calendar / Contacts / Reminders dump (Tony digest)
      --mail-setup   Prompt for IMAP + optional webhook; store in Keychain
      --mail-fetch   Fetch UNSEEN/new UIDs, queue, webhook if cooldown elapsed
      --mail-check   Same fetch, POST webhook even during the 3-hour cooldown
    Credentials stay in Keychain service com.grokbot.permissionshelper.mail.
    Never prints passwords, tokens, webhook URLs, or IMAP hosts.
    """
    FileHandle.standardOutput.write(Data(help.utf8))
    exit(0)
} else if flags.contains("--mail-setup") {
    MailSetup.run()
} else if flags.contains("--mail-fetch") {
    MailFetch.run(forceWebhook: false)
} else if flags.contains("--mail-check") {
    MailFetch.run(forceWebhook: true)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
