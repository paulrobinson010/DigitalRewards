# DigitalRewards — Shared Contract

This is the source of truth that the Apple apps (Swift) and the Windows app (C#)
both implement. If code and this document disagree, fix one of them; don't let them drift.
The test vectors in `shared/test-vectors/` are executable versions of sections 2–4 and
**both** implementations must pass them.

## 1. Constants

| Name | Value |
|------|-------|
| CloudKit container | `iCloud.com.digitalrewards.app` (change in one place per platform: `AppConfig.swift`, `appsettings.json`) |
| Sample interval (watch) | 5 s → 12 samples per full minute |
| Max HR estimate | `220 − age`, where `age = atYear − birthYear` |

### Default rules (new child)

| Field | Type | Default |
|-------|------|---------|
| `ratio` | int | 10 |
| `walkCadenceSpm` | int | 100 |
| `walkHrPct` | double | 0.55 |
| `otherHrPct` | double | 0.65 |
| `qualifyFraction` | double | 0.8 |
| `debitLimit` | int (≥ 0) | 60 |
| `maxBank` | int? | null |
| `dailyPlayCap` | int? | null |
| `playWindows` | PlayWindow[]? | null |

`PlayWindow = { "days": [1..7] (ISO weekday, Mon = 1), "start": "HH:mm", "end": "HH:mm" }`,
with `start < end`, and `end` may be `"24:00"`. Windows don't cross midnight in v1.
An empty or null list means "always allowed".

## 2. Activity qualification

- `activityType ∈ { "walk", "cycle", "other" }`. `walk` covers walking and running.
- `hrThresholdBpm(pct, birthYear, atYear) = roundHalfAwayFromZero(pct × (220 − (atYear − birthYear)))`.
  Note: C# must use `MidpointRounding.AwayFromZero`.
- A **sample** `{hr: int?, cadence: double?}` (cadence in steps/min) passes if:
  - `walk`: `hr != null && hr ≥ hrThreshold(walkHrPct)` **and** `cadence != null && cadence ≥ walkCadenceSpm`
  - `cycle` / `other`: `hr != null && hr ≥ hrThreshold(otherHrPct)`
- A **minute** is a block of 60 s of *active* (not paused) workout time. Only full minutes count.
  Each minute records `{p: passedSamples, t: totalSamples}`. A sample tick with no
  reading still counts in `t`.
- A minute **qualifies** if `t > 0 && p / t ≥ qualifyFraction` (compare as `p ≥ qualifyFraction × t − 1e-9`).
- `qualifyingMinutes = count(qualifying minutes)`; `earnedMinutes = qualifyingMinutes × ratio`.
- Rules are taken from the cached `Rules` at session **start** and stored in
  `Session.rulesSnapshot`.

## 3. Ledger fold (balance)

Entries: `{ id: string, kind: "earn" | "spend" | "adjust", minutes: int, at: epoch-ms }`.
- `earn.minutes ≥ 0` (added). `spend.minutes ≥ 0` (**subtracted**). `adjust.minutes` is signed.
- Sort by `at` ascending, then kind order `earn < adjust < spend`, then `id` (ordinal).
- Fold from `0`, with `delta = +minutes` for earn/adjust and `−minutes` for spend:
  - If `delta > 0` and `maxBank != null`: `balance = max(balance, min(balance + delta, maxBank))`.
    So credit above the cap is discarded. The fold always uses the *current* rules.
  - Otherwise: `balance += delta`.
- Entries with duplicate `id` are counted once (the first after sorting).

## 4. Play status

Inputs: rules, child `timeZone` (IANA), `now` (instant), `balance`, and spend entries.

- `local = now` converted to `timeZone`.
- `todayPlayed = Σ spend.minutes` where `spend.at` falls on `local`'s calendar date in `timeZone`.
- `fromBalance = balance + debitLimit`
- `fromCap = dailyPlayCap == null ? ∞ : dailyPlayCap − todayPlayed`
- `fromWindow`:
  - no windows → ∞
  - otherwise, the windows where `days ∋ isoWeekday(local)` and `start ≤ local.time < end`.
    If there are none, `fromWindow = 0`. Otherwise `fromWindow = max(ceil((end − local.time) in minutes))`
    over those windows.
- `minutesAvailable = max(0, min(fromBalance, fromCap, fromWindow))`. If all three are ∞, that can't
  happen, because `fromBalance` is finite.
- `canPlay = minutesAvailable > 0`.
- `reason` (when `!canPlay`): the first that applies of `"outsidePlayWindow"` (fromWindow ≤ 0),
  `"dailyCapReached"` (fromCap ≤ 0), `"debitLimitReached"` (fromBalance ≤ 0). When `canPlay`, `reason = null`.

## 5. CloudKit layout

### Zones

| Zone name | Database (owner's view) | Owner | Shared with |
|-----------|------------------------|-------|-------------|
| `Family-<childId>` | private | parent who added the child | other parents: read-write; child: read-only |
| `Activity` | private | child | all parents: read-only |
| `Prefs` | private | each parent | — |
| `_defaultZone` | **public** | — | readable by every app user; used only for invite codes and share links |

`childId` is a lowercase UUID string.

### Record types and fields

All timestamps are CloudKit `TIMESTAMP` (epoch ms in the REST API). JSON fields are `STRING`.

**Family zone**

| Type | recordName | Fields |
|------|-----------|--------|
| `Child` | `child` | `childId` STRING, `name` STRING, `birthYear` INT64, `timeZone` STRING |
| `Rules` | `rules` | the rule fields above (`maxBank`, `dailyPlayCap` absent = null; `playWindows` JSON STRING, absent = null), `updatedAt` TIMESTAMP, `updatedBy` STRING (display name) |
| `Adjustment` | `adjust-<uuid>` | `minutes` INT64 (signed), `note` STRING, `at` TIMESTAMP, `byParent` STRING |
| `Parent` | `parent-<userRecordName>` | `displayName` STRING, `lookupEmail` STRING? , `lookupPhone` STRING? |
| `AllowList` | `allow-<deviceId>` | `executables` STRING (JSON array of lowercase exe file names, e.g. `["winword.exe"]`) |

**Activity zone** (child-owned)

| Type | recordName | Fields |
|------|-----------|--------|
| `Link` | `link` | `childId` STRING, `familyZoneName` STRING, `familyZoneOwner` STRING |
| `Session` | `session-<uuid>` | `activityType` STRING, `startedAt` TIMESTAMP, `endedAt` TIMESTAMP, `minutes` STRING (JSON `[{"p":int,"t":int,"hr":double?,"cad":double?}]`, `hr`/`cad` are averages for display), `qualifyingMinutes` INT64, `earnedMinutes` INT64, `rulesSnapshot` STRING (JSON Rules), `deviceId` STRING |
| `Spend` | `spend-<deviceId>-<yyyyMMddHHmm UTC of minute start>` | `minutes` INT64, `at` TIMESTAMP (minute start), `deviceId` STRING, `app` STRING |
| `Device` | `device-<deviceId>` | `kind` STRING (`watch`/`ios`/`windows`), `name` STRING, `lastSeenAt` TIMESTAMP, `detectedApps` STRING? (JSON `[{"exe":"x.exe","name":"Display name"}]`, Windows only) |

Ledger mapping: `Session` → earn (`id` = recordName, `minutes` = earnedMinutes,
`at` = endedAt); `Spend` → spend (`at` = at); `Adjustment` → adjust (`at` = at).

**Prefs zone** (each parent, private, not shared)

| Type | recordName | Fields |
|------|-----------|--------|
| `AlertPrefs` | `alerts-<childId>` | `deviceSilent` INT64(0/1), `suspicious` INT64, `debit` INT64, `workout` INT64 |

**Public database**

| Type | recordName | Fields |
|------|-----------|--------|
| `Invite` | `invite-<6-digit code>` | `kind` STRING (`child`/`parent`), `shareURLs` STRING (JSON array of share URL strings), `expiresAt` TIMESTAMP |
| `ShareLink` | `sharelink-<childId>` | `shareURL` STRING (the child's `Activity` share) |

A share URL on its own grants nothing: only invited participants can accept a private
share. That makes the public records safe to expose.

### Flows

**Add a child (Parent mode)**
1. Ask for the name, birth year, time zone (default: the device's), and the child's Apple ID email or phone.
2. Create zone `Family-<childId>`, with `Child`, `Rules` (defaults) and a `Parent` record for each known parent.
3. Create a zone-wide `CKShare` (`publicPermission = .none`). Add the other parents as `.readWrite`
   participants (role `.administrator` where available) and the child as `.readOnly`.
4. Write `Invite` `invite-<code>` (kind `child`, 7-day expiry) holding the share URL, then show the code.

**Join as child (Child mode)**
1. Enter the code → fetch `Invite` from the public DB → `CKFetchShareMetadataOperation` → `CKAcceptSharesOperation`.
2. Create zone `Activity` (if it's missing), write `Link`, and create a zone-wide `CKShare` with every
   `Parent` from the family zone added `.readOnly` (looked up by `lookupEmail`/`lookupPhone`).
3. Write `ShareLink` `sharelink-<childId>` with that share URL.
4. Whenever the family zone's `Parent` records change, reconcile the `Activity` share participants.

**Parent auto-accepts the child's Activity share**: for each child it can see, if the
`Activity` zone for that child isn't in the shared DB yet, fetch `sharelink-<childId>`
and accept it. Retry on each refresh.

**Invite a parent**
1. The parent enters the new parent's Apple ID email/phone and display name.
2. Add them as a `.readWrite` participant to every family share, and write their `Parent` record in every family zone.
3. Write `Invite` (kind `parent`) holding every family share URL, then show the code.
4. The new parent enters the code in Parent mode and accepts all shares, then auto-accepts each child's `Activity` share
   once the child's app has added them.

**Windows enforcer**: the child signs in with CloudKit web auth. The enforcer reads the shared DB
(`zones/list`, then the `Family-*` zone), reads and writes the private `Activity` zone,
and writes `Device`/`Spend`. It never touches the public DB.
