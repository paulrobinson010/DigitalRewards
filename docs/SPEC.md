# DigitalRewards — Product & Technical Spec (v0.4)

Kids earn gaming time by doing physical activity. Each qualifying minute of
activity buys gaming minutes at a per-child ratio (default **1:10**). Working
harder does not earn more; the only test is whether each minute was at or
above the bar.

**No servers.** All data lives in the family's own iCloud accounts via
**CloudKit**.

**In scope for v1:** Apple Watch app, iPhone/iPad app, Windows app.
**Out of scope:** Android, Mac, web.

## 1. Components

| # | Component | Platform | Purpose |
|---|-----------|----------|---------|
| 1 | **Watch logger** | watchOS | Start/stop a workout, count qualifying minutes. Logging only. |
| 2 | **DigitalRewards app** | iOS / iPadOS | One app, two modes chosen at first launch: **Child** (balance, history, iOS blocking) and **Parent** (children, rules, ledger, alerts). |
| 3 | **PC enforcer** | Windows | Count play time, debit the balance, close non-allowed apps at the limit. CloudKit over its REST API. |
| 4 | **Shared core** | Swift package + C# library | Ledger fold + rules engine, ported, with shared JSON test vectors. |

## 2. Decisions (v1)

### Setup
- Each child has **their own iPhone** with a **child Apple ID** in the parent's
  Family Sharing group. The watch is **paired to the child's iPhone**.
- **Several children** are supported from day one, each with their own rules and balance.
- **Several parents/guardians**, all **equal**: any parent can add children, change
  rules, adjust balances, manage allowed lists and invite other parents. Each parent
  uses their own Apple ID and chooses their own alerts.
- Each child has **their own standard (non-admin) Windows account**. A shared
  PC is fine: one Windows account maps to one child.

### Earning
| Activity | Minute qualifies when (≥ 80% of ~5 s samples pass) |
|----------|----------------------------------------------------|
| Walking / running (outdoor or treadmill) | cadence **≥ 100 steps/min** AND HR **≥ 55%** of estimated max |
| Cycling, and any other workout (sports, swimming, dance, …) | HR **≥ 65%** of estimated max |

- Estimated max HR = 220 − age, taken from the child's birth year in the parent settings. The parent can
  override both percentages and the cadence per child.
- **No minimum session length**: every qualifying minute counts.
- **No daily earn limit.**
- Ratio: **per child, default 10**.

### Balance
- **Debit allowed** down to **−60 gaming minutes** by default, set per child. **No
  repayment deadline**: play is blocked at the limit until earnings bring the balance back above it.
- **Max bank**: optional per child, **default none**.
- **No expiry.**
- The balance is **one pool per child**, shared across PC, iPhone and iPad.

### Schedules (per child, both optional)
- **Play windows**: e.g. weekdays 16:00–20:00. Outside them play is blocked even with credit.
- **Daily play cap**: e.g. at most 120 min/day even with credit.

`canPlay = balance > −debitLimit AND inPlayWindow AND todayPlayed < dailyPlayCap`

### PC
- Time is counted **only while a non-allowed app is in the foreground**.
- Strict mode: **every app costs time except an allowed list**. Allowed by default:
  **Windows system apps only** (Explorer, Settings, Task Manager, lock screen, etc.).
  The parent adds anything else (e.g. Word, a browser).
- At the limit: toasts at **10, 5 and 1 minute(s)** left, then **non-allowed apps are closed**
  and blocked from relaunching. Allowed apps keep working.
- Offline: uses the last known balance and keeps counting locally, syncing later.
  **After 24 h without a sync, non-allowed apps are blocked.**

### iPhone / iPad
- The parent picks **apps and categories** (e.g. the whole Games category + YouTube) with
  Apple's picker on the child's device.

### Parent alerts
All four alerts are on by default; **each parent** toggles them per child for themselves:
- device stopped reporting (possible tampering)
- suspicious session
- child went into debit
- workout completed ("Sam earned 250 min")

## 3. iCloud / CloudKit design

### Zones and sharing

CloudKit has no server-side logic, so trust comes from **ownership**: each
side writes only its own zone and gets a **read-only** share of the other.

| Zone | Owner | Contains | Shared to |
|------|-------|----------|-----------|
| `Family-<childId>` (one per child) | The parent who added the child | `Child`, `Rules`, `Adjustment`, `AllowList`, `Parent` | All other parents **read-write**; that child **read-only** |
| `Activity` | Child | `Session`, `Spend`, `Device` | Every parent, **read-only** |
| `Prefs` | Each parent (not shared) | That parent's alert choices per child | — |

CloudKit share permissions are per participant, so one zone-wide `CKShare` can
give parents read-write and the child read-only.

- **Add a child**: any parent creates the `Family-<childId>` zone (owned by them) and a
  zone-wide `CKShare`, adds the other parents as read-write participants, and sends
  the child an invite link via Messages/AirDrop. Child mode accepts it, creates its own
  `Activity` zone and shares it back read-only to every parent.
- **Invite a parent**: any parent enters the other adult's Apple ID email or phone number. The app
  adds them as a read-write participant to every child's `Family` zone, and writes a
  `Parent` record there. Each child's app sees the new `Parent` record and adds that
  parent to its `Activity` share automatically.
  - Participants who don't own a zone can only add others if they have the share's
    **administrator** role (iOS 16+). Every parent is made an administrator so
    any parent can invite. *Verify in the sharing spike.* The fallback is that only the zone
    owner can invite, and the app asks that parent to do it.
- **Remove a parent**: any parent can remove another from all shares; the
  child's app removes them from `Activity` when their `Parent` record disappears.
- **Ownership risk**: a `Family` zone lives in the iCloud of the parent who created it.
  If that parent leaves (or deletes their account), another parent uses **"Take over
  child"**, which copies the zone into their own iCloud and re-shares it. Children's
  history is safe either way because it's in the child's own `Activity` zone.
- **Concurrent edits**: if two parents edit `Rules` at once, CloudKit rejects the
  second save (`serverRecordChanged`). The app reloads and shows what changed before
  saving again. Adjustments are separate records, so they never conflict.

### Records

```
Child        (Family)   name, birthYear, timeZone
Rules        (Family)   ratio, walkCadenceSpm, walkHrPct, otherHrPct, qualifyFraction,
                        debitLimit, maxBank?, playWindows? (JSON), dailyPlayCap?,
                        updatedAt, updatedBy
Adjustment   (Family)   minutes (±), note, createdAt (createdBy = parent's iCloud user)
Parent       (Family)   recordName = parent's iCloud user ID; displayName
AllowList    (Family)   recordName = deviceId; allowed executables (JSON)
Session      (Activity) recordName = session UUID; activityType, startedAt, endedAt,
                        minutes (JSON per-minute results), qualifyingMinutes,
                        earnedMinutes, rulesSnapshot (JSON), deviceId
Spend        (Activity) recordName = "<deviceId>:<minute-start ISO>"; minutes, deviceId, app
Device       (Activity) recordName = deviceId; kind [watch|ios|windows], name,
                        lastSeenAt, detectedApps (JSON, Windows only)
```

- Unique record names make every write **idempotent**.
- The ledger and Rules history show **which parent** made each adjustment or change.
- Everything except `Rules`/`AllowList`/`Child`/`Parent` is append-only, so syncing merges with no conflicts.

### Balance (computed on every client)
A deterministic fold over `Session.earnedMinutes` (+), `Spend` (−) and `Adjustment`
(±), sorted by timestamp, applying `maxBank` during the fold. It's implemented once in Swift and
once in C#, both checked against the same JSON test vectors.

### Trust and limits
- A child with developer skills could write fake records to their own zone. That's
  accepted for a family app; the parent's "suspicious session" alert catches the obvious cases
  (overlaps, more minutes than wall-clock time, implausible HR or cadence).
- Parent alerts come from CloudKit change notifications on the parent's device, which then
  posts a local notification. Delivery is **best-effort** (iOS may delay background
  work). "Device stopped reporting" is checked whenever the parent app runs a
  background refresh or is opened, so it isn't instant.

## 4. Watch logger (watchOS)

- Start screen: pick an activity (Walk/Run, Cycle, Other), then Play.
- `HKWorkoutSession` + `HKLiveWorkoutBuilder` keeps it running with the screen off and
  streams HR. `CMPedometer.currentCadence` gives step rate for Walk/Run.
- UI: Play/Pause/End, live minutes earned, a green/red "above the bar" indicator, and a
  haptic tick per qualifying minute.
- On End: computes `earnedMinutes` and saves a `Session` to the child's `Activity` zone
  (directly from the watch, or queued and retried if offline). It also saves the workout to HealthKit.

## 5. iPhone / iPad app

### Child mode
- Balance: green in credit, red in debit, plus debit headroom left.
- Today: earned, played, time left today (cap/window).
- History.
- Live updates via CloudKit subscriptions.
- **Enforcement** (FamilyControls / ManagedSettings / DeviceActivity, needs the
  **Family Controls Distribution entitlement**; apply early):
  - `requestAuthorization(for: .child)`, approved by the parent; after that the app can't be deleted
    without the parent.
  - The parent picks apps/categories with `FamilyActivityPicker` on the child's device.
  - When the child can play: remove the shield and start a `DeviceActivity` schedule with threshold events
    every minute up to the minutes available, respecting the window and cap. The monitor
    extension records used minutes in the App Group and re-shields at the last one; the app
    writes them as `Spend` records.
  - Custom shield screen: "Out of minutes. Go for a walk!" plus the balance.

### Parent mode
- List of children (from every `Family` zone this parent owns or is shared into) with their balances.
- Parents screen: invite or remove a parent, "Take over child".
- Per child: rules editor, ledger + add adjustment, devices (last seen),
  per-PC allowed list (ticked from `Device.detectedApps`), alert toggles (just for this parent, stored in their `Prefs`).
- Add child / pairing flow (section 3).

## 6. Windows enforcer

.NET 8:

1. **`DigitalRewards.Service`** (Windows Service, LocalSystem)
   - Maps each Windows user (SID) to a child and that child's CloudKit web-auth
     token (from a one-time Apple sign-in per Windows account at setup; stored with
     DPAPI; refreshed from each response).
   - Talks to **CloudKit Web Services**: reads the child's `Family` zone (rules,
     adjustments, allow list), writes `Spend`/`Device` to the child's `Activity` zone.
   - Every second, checks the foreground window's process for the active user. If it
     isn't on the allowed list (or the Windows system list), counts it as play.
     Each full minute of play produces one `Spend` record.
   - Reports installed and recently run executables in `Device.detectedApps` so the parent
     can build the allowed list.
   - At the limit: closes non-allowed foreground apps and kills them on relaunch (WMI
     process-start events).
   - Offline: counts locally and syncs later; blocks after 24 h without a sync.
   - Recovery: auto-restart; `Device.lastSeenAt` updated every few minutes.
2. **`DigitalRewards.Tray`** (per user session)
   - Shows balance and time left; toasts at 10/5/1 minute(s).
   - Display only; talks to the service over a named pipe.
3. **Installer** (MSIX or WiX): admin install, plus a setup wizard per child account.

**Fallback** if CloudKit Web Services proves awkward: status/spend files via
iCloud Drive (iCloud for Windows). Decide after the spike.

## 7. Phases

1. **Spikes**
   - CloudKit zone-wide sharing: two parents (read-write) + child Apple ID
     (read-only), child's zone back to both parents (read-only), administrator
     role letting a non-owner parent invite.
   - .NET console app: CloudKit web sign-in, read the shared zone, write the private zone,
     token refresh.
   - Family Controls: per-minute `DeviceActivity` thresholds, accuracy,
     extension limits.
2. **Shared core**: ledger fold + rules engine in Swift and C#, with test vectors.
3. **Earn**: Watch logger + app (Child: balance/history; Parent: children,
   rules, pairing, adjustments).
4. **Spend on PC**: service + tray + installer.
5. **Spend on iOS**.
6. **Alerts & polish**.
