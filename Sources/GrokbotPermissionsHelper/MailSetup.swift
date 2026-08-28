import AppKit
import Foundation

/// Interactive IMAP setup. Prompts with a small AppKit form; writes Keychain only.
enum MailSetup {
    static var delegate: MailSetupDelegate?

    static func run() {
        let app = NSApplication.shared
        let d = MailSetupDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

final class MailSetupDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var hostField: NSTextField!
    var portField: NSTextField!
    var userField: NSTextField!
    var passField: NSSecureTextField!
    var webhookField: NSTextField!
    var bearerField: NSSecureTextField!
    var statusField: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = try? MailKeychain.load()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 420))

        let title = NSTextField(labelWithString: "IMAP inbox (Keychain only)")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        title.frame = NSRect(x: 20, y: 380, width: 500, height: 22)
        view.addSubview(title)

        hostField = addPlain(view: view, y: 340, value: existing?.host ?? "",
                             label: "IMAP host", placeholder: "imap.example.com")
        portField = addPlain(view: view, y: 308, value: "\(existing?.port ?? 993)",
                             label: "Port", placeholder: "993")
        userField = addPlain(view: view, y: 276, value: existing?.username ?? "",
                             label: "Username", placeholder: "")
        passField = addSecure(view: view, y: 244, label: "Password",
                              placeholder: existing == nil ? "" : "(unchanged if blank)")
        webhookField = addPlain(view: view, y: 212, value: existing?.webhookURL ?? "",
                                label: "Webhook URL", placeholder: "optional https://...")
        bearerField = addSecure(view: view, y: 180, label: "Bearer",
                                placeholder: "optional (unchanged if blank)")

        let hint = NSTextField(wrappingLabelWithString:
            "Host, username, password, and optional webhook/bearer are stored in the macOS Keychain service com.grokbot.permissionshelper.mail. Nothing is printed. The mail queue lives under Application Support and is not for git.")
        hint.frame = NSRect(x: 20, y: 90, width: 500, height: 72)
        hint.textColor = .secondaryLabelColor
        view.addSubview(hint)

        statusField = NSTextField(labelWithString: "")
        statusField.frame = NSRect(x: 20, y: 58, width: 500, height: 22)
        statusField.textColor = .systemRed
        view.addSubview(statusField)

        let save = NSButton(title: "Save to Keychain", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 330, y: 18, width: 190, height: 32)
        view.addSubview(save)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 230, y: 18, width: 90, height: 32)
        view.addSubview(cancel)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Grokbot Mail Setup"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private func addPlain(view: NSView, y: CGFloat, value: String, label: String = "IMAP host", placeholder: String = "") -> NSTextField {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.frame = NSRect(x: 16, y: y, width: 120, height: 22)
        view.addSubview(l)
        let f = NSTextField(frame: NSRect(x: 146, y: y, width: 370, height: 24))
        f.stringValue = value
        f.placeholderString = placeholder
        f.isEditable = true
        f.isBezeled = true
        view.addSubview(f)
        return f
    }

    private func addSecure(view: NSView, y: CGFloat, label: String, placeholder: String) -> NSSecureTextField {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.frame = NSRect(x: 16, y: y, width: 120, height: 22)
        view.addSubview(l)
        let f = NSSecureTextField(frame: NSRect(x: 146, y: y, width: 370, height: 24))
        f.placeholderString = placeholder
        f.isEditable = true
        f.isBezeled = true
        view.addSubview(f)
        return f
    }

    @objc func saveClicked() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 993
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        let hook = webhookField.stringValue
        let bearer = bearerField.stringValue

        if host.isEmpty || user.isEmpty {
            statusField.stringValue = "Host and username are required."
            return
        }
        let existing = try? MailKeychain.load()
        if pass.isEmpty && (existing?.password.isEmpty ?? true) {
            statusField.stringValue = "Password is required the first time."
            return
        }

        do {
            let config = try MailKeychain.mergedFromForm(
                host: host,
                port: port,
                username: user,
                password: pass,
                webhookURL: hook,
                bearerToken: bearer
            )
            try MailKeychain.save(config)
            FileHandle.standardOutput.write(Data("MAIL: saved settings to Keychain (service \(MailKeychain.service))\n".utf8))
            NSApp.terminate(nil)
        } catch {
            statusField.stringValue = error.localizedDescription
        }
    }

    @objc func cancelClicked() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
