# DigitalRewards — Product & Technical Spec (v0.2, serverless / iCloud)

Kids earn gaming time by doing physical activity. One qualifying minute of
activity buys **10 minutes** of gaming (ratio set by a parent). Working harder
does not earn more; the only test is whether each minute was at or above the
bar.

**No servers.** All data lives in the family's own iCloud accounts via
**CloudKit**. There is nothing to host, run or pay for beyond the Apple Developer
Program.

## 1. Components

| # | Component | Platform | Purpose |
|---|-----------|----------|---------|
| 1 | **Watch logger** | watchOS | Press Play, track the workout, count qualifying minutes. Logging only. |
| 2 | **Kid app** | iOS / iPadOS | Show balance (credit **or** debit), history, today's earned/spent. Also does the iOS game blocking. |
| 3 | **Parent app** | iOS / iPadOS (+ Mac via Catalyst) | Set the rules, invite a child, view the ledger, make manual adjustments, see device health. Replaces the web portal. |
| 4 | **PC enforcer** | Windows | Count game time, debit the balance, close and block games at the limit. Talks to CloudKit over its REST API. |
| 5 | **Shared core** | Swift package + C# library | One ledger/rules engine, ported, with shared test vectors. |
| 6 | Android enforcer | Android | Phase 3, CloudKit REST like the PC. |

The kid app and parent app can be **one app with two modes**, chosen at first launch.

Priority: **Shared core + CloudKit schema → Watch logger + kid app + parent app → PC enforcer → iOS enforcer → Android.**

## 2. iCloud / CloudKit design

### Accounts
- The **parent** uses their own Apple ID.
- The **child** uses their own Apple ID: a child account in the parent's Family
  Sharing group. Family Sharing is also required for Screen Time enforcement on iOS.
- The child's iPhone, iPad and Watch are all signed in as the child.
- The child's Windows PC signs in to iCloud **as the child** inside the enforcer,
  via Apple's web sign-in.

### Zones and sharing (who owns what)

CloudKit has no server-side logic, so trust comes from **ownership**: each side
can only write its own zone, and the other side gets a **read-only** share.

| Zone | Owner | Contains | Shared to |
|------|-------|----------|-----------|
| `Family` | Parent (private DB) | `Rules`, `Adjustment` entries, `GameList` | Child, **read-only** (zone-wide `CKShare`) |
| `Activity` | Child (private DB) | `Session` (earn), `Spend` entries, `Device` heartbeats | Parent, **read-only** (zone-wide `CKShare`) |

- Setup: the parent app creates the `Family` zone and shares it to the child's Apple ID.
  The child accepts on their iPhone, which creates the `Activity` zone and
  shares it back. Both apps then see everything.
- The child can't change the rules or their adjustments. The parent can't edit or delete
  the child's history, only add adjustments. That gives a clean audit trail.
- Multiple children means one `Family` share per child (each child should only see their own
  rules), or one `Rules` record per child in a shared zone. Start with one child.

### Records

```
Rules        (Family)   ratio, minCadenceSpm, minHeartRateBpm, qualifyFraction,
                        minSessionMinutes, dailyEarnCap, maxBank, overdraftLimit,
                        dailyPlayCap, playWindows (JSON), expiryDays, updatedAt
Adjustment   (Family)   minutes (±), note, createdAt
GameList     (Family)   per-PC list of executables that count as games
Session      (Activity) recordName = session UUID; startedAt, endedAt,
                        minutes (JSON per-minute results), qualifyingMinutes,
                        earnedMinutes, rulesSnapshot (JSON), deviceId
Spend        (Activity) recordName = "<deviceId>:<minute-start ISO>"; minutes, deviceId
Device       (Activity) recordName = deviceId; kind, name, lastSeenAt,
                        detectedGames (JSON, PC only)
```

- **Unique record names make every write idempotent**, so retries and offline
  replays can't double-count.
- Everything except `Rules` is append-only, so syncing merges cleanly with no conflicts.

### Balance calculation (on every client, no server)

The balance is a deterministic fold over all `Session`, `Spend` and `Adjustment` entries
sorted by timestamp:
- `Session` adds `earnedMinutes`, which was already computed on the watch with the
  rules in force at the time, including the daily earn cap.
- `max_bank` is applied during the fold: credit above the cap is discarded at that point.
- `Spend` subtracts. `Adjustment` adds or subtracts.
- `expiryDays` (optional) expires the oldest credit first during the fold.
- The **shared core** implements this once in Swift and once in C#, with a shared JSON
  test-vector suite so the two can't disagree.

`canPlay = balance > -overdraftLimit && withinPlayWindow && todaySpend < dailyPlayCap`

### Trade-offs of no server
- **Trust**: a determined child with developer skills could write fake records to their
  own zone using the CloudKit API. For a family app that's acceptable. The parent
  app flags anomalies (sessions overlapping, more minutes than wall-clock time, implausible HR).
- **Rule changes** reach devices on their next sync, usually within seconds via
  CloudKit push. If a device is offline, it uses its cached rules.
- **Cost**: CloudKit private-database storage counts against each user's own iCloud quota.
  The data is tiny (kilobytes per month).

## 3. Watch logger (watchOS)

- `HKWorkoutSession` + `HKLiveWorkoutBuilder` (activity type `.walking`) keeps
  the app running with the screen off and streams heart rate.
- `CMPedometer` gives live cadence (`currentCadence`).
- Every ~5 s: a sample passes if HR **and** cadence are both at or above the threshold. A minute
  **qualifies** if passing samples ≥ `qualifyFraction`.
- UI: Play/Pause/End; live "minutes earned"; green/red "above the bar" indicator;
  haptic tick per qualifying minute.
- On End: computes `earnedMinutes` (ratio, minimum session length, today's earn cap) and saves a `Session`
  record to the child's `Activity` zone via CloudKit (watchOS supports it directly).
  If offline, it queues and retries. Optionally also saves the workout to HealthKit.

**Anti-cheat (good enough, not perfect)**: requiring both HR and cadence means shaking the watch
alone fails; there's no HR off the wrist; the parent app flags anomalies (section 2).

## 4. Kid app (iOS)

- Balance front and centre: green in credit, red in debit, plus debit headroom left.
- Today: earned / spent / remaining today.
- History from the ledger.
- Updates live via CloudKit subscriptions (silent push).
- Hosts the iOS enforcement (section 6).

## 5. Parent app (iOS / Mac)

- Onboarding: create the `Family` zone + rules, then share it to the child via an iCloud share
  link (Messages/AirDrop). The child accepts in the kid app.
- Rules editor with all fields from section 2.
- Ledger with filters; add adjustments with a note.
- Devices: last seen, enforcer health. Notifies if a PC hasn't been seen while it's
  likely in use, or if anomalies are found.
- PC game list: tick which executables reported by the PC count as games.

## 6. PC enforcer (Windows) — priority 1 for spending

.NET 8, two processes:

1. **`DigitalRewards.Service`**: a Windows Service (LocalSystem).
   - Talks to **CloudKit Web Services** (REST) with the app's API token plus a
     user web-auth token. The token is obtained once via Apple sign-in in the setup
     wizard, stored encrypted with DPAPI, and refreshed from each response.
   - Reads `Rules`/`Adjustment`/`GameList` from the shared `Family` zone, and reads/writes
     `Spend`/`Device` in the child's `Activity` zone.
   - Detects game processes (WMI process-start trace plus a periodic scan), reports the
     installed executables it finds in `Device.detectedGames`.
   - While a game runs (*running* or *foreground*, configurable), writes one
     `Spend` per minute.
   - At the limit: terminates game processes and kills any relaunch immediately. Toasts at 10/5/1
     minute(s) remaining.
   - Offline: uses the cached balance and blocks when it reaches the limit. Blocks entirely if offline
     for more than N hours (configurable); syncs queued `Spend` records later.
   - Auto-restart on failure; writes `Device.lastSeenAt` every few minutes.
2. **`DigitalRewards.Tray`**: shows balance in the child's session; display-only.

**Setup requirement:** the child uses a **standard (non-admin) Windows account**.

**Fallback if CloudKit Web Services proves awkward**: the iOS app mirrors a
read-only status file to a public iCloud Drive folder (synced to the PC by *iCloud
for Windows*), and the PC writes spend files back. This is simpler auth but weaker tamper
resistance and slower sync. Decide after the spike (section 9).

## 7. iOS / iPadOS enforcer — priority 2 for spending

Uses `FamilyControls`, `ManagedSettings` and `DeviceActivity`. Requires the **Family
Controls (Distribution) entitlement**; apply to Apple early.

- `AuthorizationCenter.shared.requestAuthorization(for: .child)` on the child's
  device, approved by the parent. After that, the app can't be deleted without the parent.
- Game selection with `FamilyActivityPicker` on the child's device. The tokens are opaque and
  device-local, so they're kept in the App Group.
- Blocking: `ManagedSettingsStore.shield.applications / applicationCategories`.
- Spending:
  1. When there's credit: remove the shield and start a `DeviceActivity` schedule with a
     threshold event at every minute up to the available minutes.
  2. The `DeviceActivityMonitor` extension records each used minute in the App Group and
     re-applies the shield at the last one.
  3. The app writes those minutes as `Spend` records to CloudKit.
  4. On any balance change, re-plan the schedule.
- `ShieldConfiguration` extension: "Out of minutes. Go for a walk!" plus the balance.

## 8. Android (phase 3)

Kid app + enforcer using CloudKit Web Services (same as the PC), `UsageStatsManager`,
a foreground service, and Device Owner or Accessibility for blocking, subject to Google Play policy.

## 9. Phases

1. **Spikes (de-risk first)**
   - CloudKit zone-wide sharing between a parent account and a **child** Apple ID
     (read-only both ways).
   - CloudKit Web Services from a .NET console app: web sign-in, read the shared
     zone, write to the private zone, token refresh.
   - Family Controls: per-minute `DeviceActivity` threshold events, accuracy, extension limits.
2. **Shared core**: ledger fold + rules in Swift and C#, with shared test vectors.
3. **Earn**: Watch logger + kid app (balance/history) + parent app (rules, sharing, adjustments).
4. **Spend on PC**: Windows service + tray.
5. **Spend on iOS**.
6. **Android**.

## 10. Open questions

- Is the child's watch paired to **their own iPhone**, or set up with **Apple Watch Family
  Setup**? Family Setup watches have their own Apple ID, but third-party HealthKit/workout
  support needs checking.
- Does PC play time count only while the game is **in the foreground**, or whenever it's running?
- Does the debit allowance need a repayment deadline?
- Multiple children at launch, or one?
