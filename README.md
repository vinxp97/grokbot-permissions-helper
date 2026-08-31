# Grokbot Permissions Helper

**A tiny macOS app that lets a desktop agent use Calendar, Contacts, Reminders, and (optionally) an IMAP inbox without storing secrets in git.**

macOS will not raise a TCC permission dialog for a raw `swift` script. It will for a real `.app` bundle. This helper is that bundle: it asks once, dumps a text snapshot, and quits. IMAP credentials live in the macOS Keychain only.

```
┌─────────────┐     open .app      ┌──────────────────────────┐
│  Your agent │ ─────────────────► │ Grokbot Permissions      │
│  (on Mac)   │                    │ Helper.app               │
└──────┬──────┘                    │  EventKit · Contacts     │
       │                           │  Shortcuts list          │
       │  read dump                │  optional IMAP TLS       │
       ▼                           └────────────┬─────────────┘
 /tmp/grokbot-permissions-helper-out.txt  ◄─────┘
       mail queue (Application Support)   ◄─────┘
```

| Calendar | Contacts | Reminders | Home | Mail |
| --- | --- | --- | --- | --- |
| Read events (today + next days) | Count + a few samples | Incomplete items in a window | Lists matching Shortcuts (no HomeKit) | IMAP UNSEEN/new UIDs → local queue + optional webhook |

---

## Why this exists

Desktop agents running on a Mac can launch processes, but **Calendar / Contacts / Reminders prompts only appear for apps** with the right `Info.plist` usage strings. A command-line binary is invisible to those prompts, so access comes back denied forever.

This helper:

1. Ships as `Grokbot_Permissions_Helper.app`
2. Requests **full** Calendar, Reminders, and Contacts access **only when status is still `notDetermined`**
3. Writes a parseable dump to `/tmp/grokbot-permissions-helper-out.txt`
4. Exits
5. Optionally fetches IMAP over TLS and queues new message headers locally

Rebuilds keep the same bundle identifier (`com.grokbot.permissionshelper`) and ad-hoc signature so macOS does not treat every build as a new app (which would re-prompt).

HomeKit is intentionally **out**. Regular Mac apps cannot use it without Apple entitlements. Lights and scenes go through existing **Shortcuts**.

---

## Quick start

Requires macOS 14+, Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone git@github.com:vinxp97/grokbot-permissions-helper.git
cd grokbot-permissions-helper
./scripts/build.sh
cp -R dist/Grokbot_Permissions_Helper.app ~/Applications/
open ~/Applications/Grokbot_Permissions_Helper.app
```

Click **Allow** for Calendar, Contacts, and Reminders the first time. Later launches skip the dialogs and just refresh the dump.

```bash
cat /tmp/grokbot-permissions-helper-out.txt
```

Build and install notes for agents: [AGENTS.md](AGENTS.md).

---

## CLI modes

Launch the Mach-O inside the bundle (not `open`, unless you pass `--args`).

| Flag | What it does |
| --- | --- |
| *(none)* | Calendar / Contacts / Reminders / Shortcuts dump to `/tmp/grokbot-permissions-helper-out.txt`. |
| `--mail-setup` | AppKit form: IMAP host, port (default 993), username, password (secure field). Optional webhook URL and bearer. Saves to Keychain service `com.grokbot.permissionshelper.mail`. Never prints secrets. Blank password/bearer on a later run keeps the previous Keychain value. |
| `--mail-fetch` | IMAP TLS: `LOGIN`, `SELECT INBOX`, `UID SEARCH` UNSEEN plus UIDs newer than last, `UID FETCH RFC822.HEADER`. Parses SPF/DKIM/DMARC from that header block (no body, no second IMAP). Appends new items to `~/Library/Application Support/GrokbotPermissionsHelper/queue.json`. If there are new items **and** the last auto webhook is older than 3 hours, POST JSON (see below) with `Authorization: Bearer` from Keychain, then record `lastWebhookAt`. During cooldown, only queue. |
| `--mail-check` | Same fetch, then POST the webhook even during the 3-hour cooldown (manual / agent). |
| `--help` | Short usage. |

```bash
BIN="$HOME/Applications/Grokbot_Permissions_Helper.app/Contents/MacOS/GrokbotPermissionsHelper"
"$BIN" --mail-setup
"$BIN" --mail-fetch
"$BIN" --mail-check
```

IMAP is implicit TLS (Network.framework). Default port 993. LOGIN must be allowed on the server (app password, not account password, on providers that require it). No POP3, no SMTP.

Stdout from mail modes is counts only (`MAIL: queued 2 new`). Hosts, usernames, passwords, webhook URLs, and tokens are never printed.

---

## Mail queue and webhook

Local state (never commit):

- `~/Library/Application Support/GrokbotPermissionsHelper/queue.json`
- `~/Library/Application Support/GrokbotPermissionsHelper/last-webhook`

Webhook body (new messages from that run, not the whole history):

```json
{
  "new_count": 2,
  "queued_count": 10,
  "messages": [
    {
      "uid": 12,
      "from": "Ada <ada@example.com>",
      "subject": "Hello",
      "date": "Fri, 28 Aug 2026 09:00:00 -0400",
      "spf": "pass",
      "dkim": "pass",
      "dmarc": "pass",
      "dkim_d": "example.com",
      "dmarc_policy": "reject",
      "header_from_domain": "example.com",
      "envelope_from": "bounce@example.com",
      "return_path": "<bounce@example.com>",
      "reply_to": "",
      "message_id_domain": "mail.example.com",
      "authentication_results": "inbound.example.net; spf=pass smtp.mailfrom=ada@example.com; dkim=pass header.d=example.com; dmarc=pass (p=reject) header.from=example.com",
      "header_url_hosts": ["www.example.com"]
    }
  ]
}
```

Auth fields are parsed from the RFC822 header already fetched (`MailAuthParser`). `spf` / `dkim` / `dmarc` are `pass`, `fail`, or `none`. Missing `Authentication-Results` is `none`, never invented `pass`. Multiple AR headers: the first in the block is inbound MX (servers prepend); later AR lines only fill methods the first one did not mention. `header_url_hosts` is hostnames from `http(s)` URLs in the HEADER only, not the body. Routing (all-pass vs fail/missing) is the consumer's job; this helper only emits JSON.

If no webhook URL was saved in Keychain, fetch still queues. HTTPS is preferred; local HTTP is allowed via `NSAllowsLocalNetworking`.

---

## launchd (poll every 15 minutes)

Template only: [launchd/com.grokbot.permissionshelper.mail.plist.example](launchd/com.grokbot.permissionshelper.mail.plist.example). Placeholders — no hosts, accounts, or URLs.

```bash
mkdir -p ~/Library/LaunchAgents
cp launchd/com.grokbot.permissionshelper.mail.plist.example \
  ~/Library/LaunchAgents/com.grokbot.permissionshelper.mail.plist
# Edit YOUR_USERNAME (and the .app path if you installed elsewhere).
launchctl bootstrap gui/"$(id -u)" ~/Library/LaunchAgents/com.grokbot.permissionshelper.mail.plist
```

Unload:

```bash
launchctl bootout gui/"$(id -u)" ~/Library/LaunchAgents/com.grokbot.permissionshelper.mail.plist
```

Do not copy the loaded plist back into this repo. `.gitignore` drops `*.plist` except `Resources/Info.plist` and `launchd/*.plist.example`.

---

## Output format

Line-oriented, tab-separated payloads. Status keys first, then dumps. Example shape (fake data):

```
NOW: 2026-08-26T12:00:00Z
CAL_STATUS: fullAccess
REM_STATUS: fullAccess
CON_STATUS: authorized
CALENDAR: granted
CALENDARS: 2
CAL	Work	iCloud
EVT	timed	2026-08-26T13:00:00-04:00	2026-08-26T14:00:00-04:00	Work	iCloud	Standup	
REMINDERS: granted
REMINDER_LISTS: 1
REMINDER_LIST	To Do	iCloud
REMINDERS_INCOMPLETE: 1
REM	To Do	Buy oat milk	2026-08-27T16:00:00Z
CONTACTS: granted
CONTACTS_COUNT: 42
CONTACT	Ada Lovelace	ada@example.com	+1-555-0100
HOME_VIA: Shortcuts (2 home-related of 10 total)
HOME_SHORTCUT	Turn Lights On
```

| Prefix | Meaning |
| --- | --- |
| `CAL_STATUS` / `REM_STATUS` / `CON_STATUS` | TCC state before this run |
| `CAL` | Calendar name + source |
| `EVT` | `allday or timed`, start, end, calendar, source, title, location |
| `REM` | List, title, due ISO-8601 or `none` |
| `CONTACT` | Display name, email, phone (samples only) |
| `HOME_SHORTCUT` | Shortcut name that looks home-related |

Times use the **Mac's current timezone**, not a hardcoded zone.

---

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `GROKBOT_HELPER_OUT` | `/tmp/grokbot-permissions-helper-out.txt` | Dump path |
| `GROKBOT_HELPER_CAL_DAYS` | `3` | Inclusive horizon from start of today |
| `GROKBOT_HELPER_REM_LOOKBACK_DAYS` | `7` | Incomplete reminders window behind |
| `GROKBOT_HELPER_REM_FORWARD_DAYS` | `14` | Incomplete reminders window ahead |
| `GROKBOT_HELPER_CONTACT_SAMPLES` | `8` | How many contact rows to include |

`open` does not pass env into GUI apps. To set dump knobs, launch the binary inside the bundle:

```bash
GROKBOT_HELPER_CAL_DAYS=7 \
  "$HOME/Applications/Grokbot_Permissions_Helper.app/Contents/MacOS/GrokbotPermissionsHelper"
```

---

## Security

- **No secrets in git.** This repo is public. Do not commit dump files, `queue.json`, `last-webhook`, loaded launchd plists, Keychain exports, passwords, webhook URLs, bearer tokens, personal emails, or IMAP hosts.
- **Keychain only for mail.** Service `com.grokbot.permissionshelper.mail`. The helper never prints those values.
- **IMAP + optional webhook.** Calendar dump still does not upload. Mail modes speak IMAP TLS to the host you entered and may POST header summaries to the webhook you entered.
- **Ad-hoc signed.** Fine for a personal Mac. Not notarized; Gatekeeper may ask you to open it once via System Settings → Privacy & Security.
- **Stable identity.** `codesign --identifier` matches the bundle id so grants survive rebuilds.
- **Least surprise.** Calendar/Contacts/Reminders are requested only when still `notDetermined`. Denied/restricted stays denied; the dump reports it.

---

## Project layout

```
Sources/GrokbotPermissionsHelper/main.swift        # dump app + CLI dispatch
Sources/GrokbotPermissionsHelper/IMAPClient.swift  # IMAP TLS (Network.framework)
Sources/GrokbotPermissionsHelper/MailKeychain.swift
Sources/GrokbotPermissionsHelper/MailSetup.swift
Sources/GrokbotPermissionsHelper/MailFetch.swift
Sources/GrokbotPermissionsHelper/MailAuthParser.swift  # SPF/DKIM/DMARC from RFC822.HEADER
Tests/MailAuthFixtures                             # pass / fail / missing-AR parser fixtures
Resources/Info.plist                               # TCC usage strings + CFBundleIconFile=AppIcon
scripts/build.sh                                   # compile, bundle, ad-hoc sign
launchd/com.grokbot.permissionshelper.mail.plist.example
AGENTS.md                                          # build / install / utilize notes for agents
```

## License

[MIT](LICENSE)
