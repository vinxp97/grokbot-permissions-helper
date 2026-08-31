# AGENTS.md — Grokbot Permissions Helper

Instructions for coding / desktop agents. Humans can follow them too. Point your agent at this file.

**What this is:** a macOS `.app` that can receive TCC prompts for Calendar, Contacts, and Reminders, and can fetch IMAP over TLS. A CLI `swift` file cannot raise those TCC prompts. You launch the app on the user's Mac, then read a text dump (calendar) or a local mail queue. You do not store Apple passwords, CalDAV tokens, IMAP passwords, webhook URLs, bearer tokens, or address-book exports in git.

**What this is not:** HomeKit. Use existing Shortcuts (`/usr/bin/shortcuts list` / `shortcuts run`). The helper only *lists* shortcut names that look home-related.

Do not commit `/tmp/grokbot-permissions-helper-out.txt`, contact rows, calendar events, `queue.json`, `last-webhook`, loaded launchd plists, or anything from Keychain.

This repository is **public**. Never commit secrets: no passwords, no webhook URLs, no bearer tokens, no personal emails, no IMAP hosts.

---

## 1. Download

Private-or-public clone (needs GitHub access the user already granted):

```bash
git clone git@github.com:vinxp97/grokbot-permissions-helper.git
cd grokbot-permissions-helper
```

HTTPS if SSH is not set up:

```bash
git clone https://github.com/vinxp97/grokbot-permissions-helper.git
```

You need:

- `Sources/GrokbotPermissionsHelper/*.swift`
- `Resources/Info.plist`
- `scripts/build.sh`
- `launchd/com.grokbot.permissionshelper.mail.plist.example` (mail poll only)

Build **on the user's Mac** (Darwin). Linux cloud agents cannot compile this.

---

## 2. Install

Target: macOS 14+, Xcode CLT available (`xcode-select -p`).

```bash
./scripts/build.sh
mkdir -p "$HOME/Applications"
cp -R dist/Grokbot_Permissions_Helper.app "$HOME/Applications/"
```

Build to `dist/` first, then copy the `.app`. Never pass the live `~/Applications/Grokbot_Permissions_Helper.app` as `build.sh` OUT (`rm -rf` runs first; a failed compile leaves an empty bundle).

The script:

1. Compiles every `Sources/GrokbotPermissionsHelper/*.swift` against AppKit, EventKit, Contacts, Security, Network
2. Wraps it in an `.app` with `Info.plist` usage strings
3. Ad-hoc signs with identifier `com.grokbot.permissionshelper` unless `BUNDLE_ID` is set

**Live Mac TCC:** if Calendar/Contacts/Reminders were already granted under `com.vincentderiu.grokbotpermissionshelper`, rebuild with that id so macOS does not treat it as a new app:

```bash
BUNDLE_ID=com.vincentderiu.grokbotpermissionshelper ./scripts/build.sh
```

Do not change the default in `Resources/Info.plist` in git. Override at build time only.

**First run (user must click Allow):**

```bash
open "$HOME/Applications/Grokbot_Permissions_Helper.app"
```

Wait until the process exits (up to ~90s). Confirm:

```bash
test -s /tmp/grokbot-permissions-helper-out.txt
grep -E 'CAL_STATUS|REM_STATUS|CON_STATUS' /tmp/grokbot-permissions-helper-out.txt
```

Expected after Allow: `fullAccess` / `fullAccess` / `authorized`.

If Gatekeeper blocks the unsigned app, tell the user to open **System Settings → Privacy & Security** and allow it. Do not disable SIP or `spctl --master-disable`.

If Calendar/Contacts/Reminders still say `denied` or `restricted`, **do not keep launching to re-prompt**. macOS will not show the dialog again until the user flips the toggle under System Settings → Privacy & Security → Calendar / Contacts / Reminders for **Grokbot Permissions Helper**. Ask the user to enable those, then run once more.

Rebuilds must keep the same bundle id and the same `--identifier` on `codesign`, or TCC treats it as a new app and prompts again.

---

## 3. Implement / utilize

### When to launch (calendar dump)

Launch the helper **with no flags** whenever you need a fresh snapshot of calendars, incomplete reminders, a contact lookup, or the list of home-ish Shortcuts. Typical: weekday morning digest ("Tony digest"), "what's on my calendar", "add a reminder" (read first, then use EventKit via a follow-up you design — this helper's default path is read/dump only).

**Do not pass `--mail-*` flags for that digest.** Default (no flag) must stay the calendar/contacts/reminders dump.

### How to launch (dump)

Preferred (lets you pass env):

```bash
rm -f /tmp/grokbot-permissions-helper-out.txt
GROKBOT_HELPER_OUT=/tmp/grokbot-permissions-helper-out.txt \
  "$HOME/Applications/Grokbot_Permissions_Helper.app/Contents/MacOS/GrokbotPermissionsHelper"
```

Or:

```bash
open "$HOME/Applications/Grokbot_Permissions_Helper.app"
```

Wait for the dump file to appear and stabilize (process gone, file non-empty). Timeout ~90 seconds. If the file is missing, report failure; do not invent events.

Optional env (only when launching the Mach-O, not via `open`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `GROKBOT_HELPER_OUT` | `/tmp/grokbot-permissions-helper-out.txt` | Dump path |
| `GROKBOT_HELPER_CAL_DAYS` | `3` | Days from start of today (3 = today + 2) |
| `GROKBOT_HELPER_REM_LOOKBACK_DAYS` | `7` | Incomplete reminders lookback |
| `GROKBOT_HELPER_REM_FORWARD_DAYS` | `14` | Incomplete reminders forward |
| `GROKBOT_HELPER_CONTACT_SAMPLES` | `8` | Contact sample rows |

Timezone is the Mac's current timezone. Do not assume `America/New_York`.

### How to parse

Read the dump as UTF-8 lines.

- `KEY: value` for status and counts (`CAL_STATUS`, `CALENDAR`, `EVENTS`, …)
- Tab-separated records:
  - `CAL` — title, source
  - `EVT` — `allday|timed`, start ISO-8601, end ISO-8601, calendar, source, title, location
  - `REMINDER_LIST` — title, source
  - `REM` — list, title, due ISO-8601 or `none`
  - `CONTACT` — name, email, phone
  - `HOME_SHORTCUT` — shortcut name

If `CALENDAR: denied` (or Reminders/Contacts), tell the user. Do not retry in a loop.

### Home / lights

Do not import HomeKit. Run a named Shortcut the dump listed, after the user asked:

```bash
shortcuts run "Turn Lights On"
```

Never run a Shortcut that spends money, sends mail, or shares data unless the user explicitly asked for that Shortcut by name.

### Adding events or reminders

The default helper path is **read-only dump**. To write, extend the Swift (keep the same bundle id) or use another EventKit helper. Do not scrape Calendar.app UI if this dump already has the data.

---

## 4. Mail (IMAP)

Binary:

```bash
BIN="$HOME/Applications/Grokbot_Permissions_Helper.app/Contents/MacOS/GrokbotPermissionsHelper"
```

### Setup (needs the user at the Mac)

`--mail-setup` shows an AppKit form. Do not run it unattended. Do not pass host/password on the command line. Do not log field values.

```bash
"$BIN" --mail-setup
```

Stores IMAP host, port (default 993), username, password, optional webhook URL, optional bearer in Keychain service `com.grokbot.permissionshelper.mail`. Never print Keychain contents.

### Fetch (launchd / quiet poll)

```bash
"$BIN" --mail-fetch
```

TLS IMAP: LOGIN, SELECT INBOX, UID SEARCH UNSEEN (and newer UIDs), UID FETCH RFC822.HEADER. Parses SPF/DKIM/DMARC plus envelope/From/Reply-To/Message-ID domains and header `http(s)` hosts from that same header block (no body, no second IMAP). Appends new UIDs to `~/Library/Application Support/GrokbotPermissionsHelper/queue.json` (auth fields included; old queue rows without them still decode). If there are new items and the last webhook is older than 3 hours, POSTs JSON `{new_count, queued_count, messages:[{uid,from,subject,date,spf,dkim,dmarc,...}]}` with `Authorization: Bearer` from Keychain, then writes `last-webhook`. During cooldown, only queue.

Webhook `spf`/`dkim`/`dmarc` are `pass`/`fail`/`none`. Missing Authentication-Results → `none`, never invent `pass`. Multiple AR headers: first in the block is inbound MX (servers prepend); later AR only fill methods the first did not mention. Helper is a JSON emitter; Helix (or other consumer) routes on those fields. Parser-only fixtures: `Tests/MailAuthFixtures` (pass / fail / missing-AR). Do not compile the AppKit app to run those — `swiftc` `MailAuthParser.swift` + `Tests/MailAuthParserMain.swift`.

Stdout is counts (`MAIL: queued N new`). Treat `MAIL_ERROR:` on stderr as failure. Do not dump the queue into chat unless the user asked for mail.

### Manual check (agents)

When the user asks to check mail **now**, or you need to notify past the 3-hour cooldown:

```bash
"$BIN" --mail-check
```

Same fetch as `--mail-fetch`, then POST the webhook even if cooldown is active.

### launchd

Copy the **example** only, edit the placeholder binary path, load as a user agent. Interval is 900 seconds (`--mail-fetch`).

```bash
mkdir -p "$HOME/Library/LaunchAgents"
EXAMPLE="launchd/com.grokbot.permissionshelper.mail.plist.example"
DEST="$HOME/Library/LaunchAgents/com.grokbot.permissionshelper.mail.plist"
cp "$EXAMPLE" "$DEST"
# replace YOUR_USERNAME in DEST — do not put secrets in the plist
launchctl bootstrap gui/"$(id -u)" "$DEST"
```

Never commit the loaded plist, `queue.json`, or `last-webhook`.

### Hygiene (mail)

- Credentials: Keychain only. Do not write them to files in this repo or `/tmp`.
- Do not print IMAP hosts, usernames, passwords, webhook URLs, or bearer tokens.
- Queue JSON is personal mail metadata. Summarize for the user; do not forward to other agents or the network unless they asked (the webhook they configured is the exception).

---

### After a binary swap

`scripts/build.sh` `rm -rf`s its OUT path first. Never pass the live `~/Applications/Grokbot_Permissions_Helper.app` as OUT — a failed compile leaves an empty bundle.

After replacing or recodesigning the live `.app`, bootout then bootstrap the mail LaunchAgent. Leaving it loaded across a binary swap can spawn-fail with `OS_REASON_CODESIGNING` (stale LWCR).

```bash
DEST="$HOME/Library/LaunchAgents/com.grokbot.permissionshelper.mail.plist"
launchctl bootout gui/"$(id -u)" "$DEST"
launchctl bootstrap gui/"$(id -u)" "$DEST"
```

`Resources/Info.plist` must declare `CFBundleIconFile` = `AppIcon` (and `Resources/AppIcon.icns` must exist). Missing the key makes Finder/Dock show a blank icon.

IMAP TLS uses `NWEndpoint.Port(rawValue:)`. `NWEndpoint.Port(p)` does not compile.

Default dump path `/tmp/grokbot-permissions-helper-out.txt` is what weekday digest consumers read. Do not change it.

## 5. Hygiene (general)

- Do not paste dump contents into git, issues, or public chat.
- Treat dump contents as personal data. Summarize for the user; do not forward contacts or event details to other agents or the network unless the user asked.
- Subsequent runs must not re-request permission when status is already granted. The app already checks `authorizationStatus` / `notDetermined`. If you fork the Swift, keep that guard.
