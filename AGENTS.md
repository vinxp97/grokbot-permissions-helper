# AGENTS.md — Grokbot Permissions Helper

Instructions for coding / desktop agents. Humans can follow them too. Point your agent at this file.

**What this is:** a macOS `.app` that can receive TCC prompts for Calendar, Contacts, and Reminders. A CLI `swift` file cannot. You launch the app on the user's Mac, then read a text dump. You do not store Apple passwords, CalDAV tokens, or address-book exports in git.

**What this is not:** HomeKit. Use existing Shortcuts (`/usr/bin/shortcuts list` / `shortcuts run`). The helper only *lists* shortcut names that look home-related.

Do not commit `/tmp/grokbot-permissions-helper-out.txt`, contact rows, or calendar events.

---

## 1. Download

Private repo (needs GitHub access the user already granted):

```bash
git clone git@github.com:vinxp97/grokbot-permissions-helper.git
cd grokbot-permissions-helper
```

HTTPS if SSH is not set up:

```bash
git clone https://github.com/vinxp97/grokbot-permissions-helper.git
```

You only need:

- `Sources/GrokbotPermissionsHelper/main.swift`
- `Resources/Info.plist`
- `scripts/build.sh`

Build **on the user's Mac** (Darwin). Linux cloud agents cannot compile this.

---

## 2. Install

Target: macOS 14+, Xcode CLT available (`xcode-select -p`).

```bash
./scripts/build.sh
mkdir -p "$HOME/Applications"
cp -R dist/Grokbot_Permissions_Helper.app "$HOME/Applications/"
```

Optional custom output path:

```bash
./scripts/build.sh "$HOME/Applications/Grokbot_Permissions_Helper.app"
```

The script:

1. Compiles `main.swift` against AppKit, EventKit, Contacts
2. Wraps it in an `.app` with `Info.plist` usage strings
3. Ad-hoc signs with identifier `com.grokbot.permissionshelper`

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

Rebuilds must keep bundle id `com.grokbot.permissionshelper` and the same `--identifier` on `codesign`, or TCC treats it as a new app and prompts again.

---

## 3. Implement / utilize

### When to launch

Launch the helper whenever you need a fresh snapshot of calendars, incomplete reminders, a contact lookup, or the list of home-ish Shortcuts. Typical: weekday morning digest, "what's on my calendar", "add a reminder" (read first, then use EventKit via a follow-up you design — this helper is read/dump only).

### How to launch

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
  - `EVT` — `allday` or `timed`, start ISO-8601, end ISO-8601, calendar, source, title, location
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

This helper is **read-only dump**. To write, extend the Swift (keep the same bundle id) or use another EventKit helper. Do not scrape Calendar.app UI if this dump already has the data.

### Hygiene

- Do not paste dump contents into git, issues, or public chat.
- Treat dump contents as personal data. Summarize for the user; do not forward contacts or event details to other agents or the network unless the user asked.
- Subsequent runs must not re-request permission when status is already granted. The app already checks `authorizationStatus` / `notDetermined`. If you fork the Swift, keep that guard.
