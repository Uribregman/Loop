# Your history file — what it is and how to read it

Loop only keeps about **7 days** of history. After that, glucose readings, doses and
carb entries are deleted to keep the app fast. Pod sessions are worse: the app stores
the current pod and exactly **one** previous pod, so every pod change erases the one
before it.

The history log exists to keep a permanent copy. It is **opt-in**, it only ever
**writes** — nothing in it is read back by Loop, and it cannot affect your insulin in
any way.

Because there is no way to recover data older than about a week, the log can only
record from the day you switch it on. Nothing before that can be recovered.

## Where the file lives

The log is written to **iCloud Drive** when that's available, and to the app's own
storage on your phone when it isn't. Either way you can find it in the **Files** app.

Files are split up **by month**, so they stay small and sync quickly:

```
loop-history-2026-08.jsonl
loop-history-2026-09.jsonl
```

## What's inside

Each file is plain text. **One line = one event.** Nothing is ever rewritten — new
events are added to the end. That's deliberate: if the app is killed mid-write, at
worst the last line is incomplete, and everything before it is still perfectly good.

You can open a file in any text editor. Each line is a JSON object, and every line
starts with the same three fields:

| Field | Meaning |
|---|---|
| `v` | Format version (currently `1`). Fields are never repurposed, so old lines stay readable forever. |
| `t` | What kind of event this is: `glucose`, `meal`, `dose` or `pod`. |
| `at` | When it happened, e.g. `2026-08-11T20:14:00+03:00`. The `+03:00` is your time zone. |

Fields that don't apply are simply left out. Keys are in alphabetical order.

---

## `glucose` — one CGM reading

```json
{"at":"2026-08-11T20:14:00+03:00","mgdl":142,"source":"Dexcom G7","syncIdentifier":"a1b2c3","t":"glucose","trend":"flat","trendRate":0.3,"v":1}
```

| Field | Meaning |
|---|---|
| `mgdl` | The reading, **always in mg/dL** — even if you read mmol/L in the app. One unit in the file means no ambiguity later. To get mmol/L, divide by 18. |
| `trend` | The arrow the CGM reported: `flat`, `up`, `upUp`, `down`, and so on. |
| `trendRate` | How fast it's moving, in mg/dL per minute. Negative means falling. |
| `source` | Which device it came from. |
| `syncIdentifier` | The CGM's own ID for the reading, so a re-import can skip duplicates. |

Manually entered and display-only readings are kept too — what you actually *saw*
matters when you look back at an excursion.

---

## `meal` — one carb entry

A meal made of several parts is saved as several carb entries, so you'll see one line
per part, all sharing the same `mealName`.

```json
{"absorption":10800,"at":"2026-08-11T13:02:00+03:00","eatenAt":"2026-08-11T12:45:00+03:00","enteredAt":"2026-08-11T13:10:00+03:00","foodType":"🍕","grams":65,"mealEmoji":"🍕","mealName":"Pizza night","syncIdentifier":"d4e5f6","t":"meal","v":1}
```

A meal carries **three different times**, and they are genuinely different — the
example above is a pizza eaten at 12:45, whose carbs were set to start counting at
13:02, logged into the app at 13:10, over 3 hours.

| Field | Meaning |
|---|---|
| `eatenAt` | **Eating time** — when you actually ate. Missing for carbs entered outside the meal screen, which have no meal time. |
| `at` | **Absorption start** — when these carbs begin counting. You can offset a meal part, so this is often *not* the eating time. |
| `absorption` | **Absorption time** — how long the carbs were expected to take, **in seconds** (`10800` = 3 hours). |
| `enteredAt` | **Entry time** — when you saved it into the app. Differs from `eatenAt` whenever you log a meal late, which is exactly when it matters for making sense of a spike afterwards. |
| `updatedAt` | Only present if you edited the entry after saving it. |
| `grams` | Carbs in grams. |
| `foodType` | The emoji or text on that individual entry. |
| `mealName` | The name you gave the whole meal, if any. |
| `mealEmoji` | The emoji you picked for the whole meal, if any. |

`mealName` and `mealEmoji` come from Loop's own meal notes, which only keep the last
300 meals — so those names were quietly being lost over time. Copying them here is
what stops that happening.

---

## `dose` — one delivery of insulin

```json
{"at":"2026-08-11T13:05:00+03:00","automatic":false,"kind":"bolus","syncIdentifier":"7g8h9i","t":"dose","units":4.25,"v":1}
```

| Field | Meaning |
|---|---|
| `kind` | `bolus`, `basal`, `tempBasal`, `suspend` or `resume`. |
| `units` | Units of insulin actually delivered. |
| `unitsPerHour` | The *rate*, for basal doses. A basal has a rate; a bolus has an amount. |
| `endedAt` | When delivery finished. Left out for instant doses like a bolus. |
| `automatic` | `true` when Loop decided this itself, `false` when you asked for it. |

---

## `pod` — one finished pod session

Written when a pod **stops**. This is the one record that genuinely cannot be
recreated later.

```json
{"activatedAt":"2026-08-08T09:30:00+03:00","at":"2026-08-11T11:47:00+03:00","faultCode":"0x1C","firmwareVersion":"2.7.0","hoursRun":74.3,"lotNo":"41234","lotSeq":"887766","podType":"1","remainingAtStop":12.4,"stopReason":"expired","t":"pod","totalDelivered":138.6,"v":1}
```

| Field | Meaning |
|---|---|
| `activatedAt` | When you started the pod. |
| `hoursRun` | How long it lasted, in hours. |
| `totalDelivered` | Total units it delivered over its life. |
| `remainingAtStop` | Units still inside when it stopped — i.e. insulin thrown away. |
| `stopReason` | Why it ended. See below. |
| `faultCode` | The pod's own error code in hex, if it reported one. |
| `lotNo`, `lotSeq`, `podType`, `firmwareVersion` | Identifying details, useful if a whole batch misbehaves. |

`stopReason` is one of:

- **`expired`** — it reached the end of its life (about 80 hours).
- **`reservoirEmpty`** — it ran out of insulin.
- **`fault`** — it failed. Check `faultCode`.
- **`deactivated`** — you took it off before any of the above.

Only Omnipod pumps produce these records.

---

## Using the file

Any text editor will open it. If you have the `jq` tool, this checks a file is valid
and prints it readably:

```bash
jq -c . < loop-history-2026-08.jsonl
```

Pull out just your glucose readings:

```bash
jq -c 'select(.t == "glucose")' < loop-history-2026-08.jsonl
```

See how long each pod lasted and why it ended:

```bash
jq -r 'select(.t == "pod") | "\(.at) \(.hoursRun)h \(.stopReason)"' < loop-history-2026-08.jsonl
```

## A caution

This file is a record, not medical advice. It shows what happened; it does not tell
you what to change. Any decision about insulin settings belongs with your care team.
