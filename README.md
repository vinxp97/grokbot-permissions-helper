# Grokbot Permissions Helper

**A tiny macOS app that lets a desktop agent use Calendar, Contacts, and Reminders without storing secrets.**

macOS will not raise a TCC permission dialog for a raw `swift` script. It will for a real `.app` bundle. This helper is that bundle: it asks once, dumps a text snapshot, and quits.

```
┌─────────────┐     open .app      ┌──────────────────────────┐
│  Your agent │ ─────────────────▶ │ Grokbot Permissions      │
│  (on Mac)   │                    │ Helper.app               │
└──────┬──────┘                    │  EventKit · Contacts     │
       │                           │  Shortcuts list          │
       │  read dump                └────────────┬─────────────┘
       ▼                                        │
 /tmp/grokbot-permissions-helper-out.txt  ◀─────┘
```

| Calendar | Contacts | Reminders | Home |
| --- | --- | --- | --- |
| Read events (today + next days) | Count + a few samples | Incomplete items in a window | Lists matching Shortcuts (no HomeKit) |

> Agents: start at [AGENTS.md](AGENTS.md). Humans: stay here.

---

## Why this exists

Desktop agents running on a Mac can launch processes, but **Calendar / Contacts / Reminders prompts only appear for apps** with the right `Info.plist` usage strings. A command-line binary is invisible to those prompts, so access comes back denied forever.

This helper:

1. Ships as `Grokbot_Permissions_Helper.app`
2. Requests **full** Calendar, Reminders, and Contacts access **only when status is still `notDetermined`**
3. Writes a parseable dump to `/tmp/grokbot-permissions-helper-out.txt`
4. Exits

Rebuilds keep the same bundle identifier (`com.grokbot.permissionshelper`) and ad-hoc signature so macOS does not treat every build as a new app (which would re-prompt).

HomeKit is intentionally **out**. Regular Mac apps cannot use it without Apple entitlements. Lights and scenes go through existing **Shortcuts**.

---

## Quick start (human)

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

`open` does not pass env into GUI apps. To set these, launch the binary inside the bundle:

```bash
GROKBOT_HELPER_CAL_DAYS=7 \
  "$HOME/Applications/Grokbot_Permissions_Helper.app/Contents/MacOS/GrokbotPermissionsHelper"
```

---

## Security

- **No network.** The helper never uploads. An agent only sees what it reads from the dump file on this Mac.
- **No secrets in git.** Do not commit dump files, TCC databases, or personal event/contact data.
- **Ad-hoc signed.** Fine for a personal Mac. Not notarized; Gatekeeper may ask you to open it once via System Settings → Privacy & Security.
- **Stable identity.** `codesign --identifier com.grokbot.permissionshelper` so grants survive rebuilds.
- **Least surprise.** Access is requested only when still `notDetermined`. Denied/restricted stays denied; the dump reports it.

---

## Project layout

```
Sources/GrokbotPermissionsHelper/main.swift   # the app
Resources/Info.plist                          # TCC usage strings
scripts/build.sh                              # compile, bundle, ad-hoc sign
AGENTS.md                                     # download / install / utilize for agents
```

## License

[MIT](LICENSE)
