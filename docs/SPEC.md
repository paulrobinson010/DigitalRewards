# DigitalRewards — Product & Technical Spec (v0.1)

Kids earn gaming time by doing physical activity. One qualifying minute of
activity buys **10 minutes** of gaming (ratio set by a parent). Working harder
does not earn more; the only test is whether each minute was at or above the
bar.

## 1. Components

| # | Component | Platform | Purpose |
|---|-----------|----------|---------|
| 1 | **Watch logger** | watchOS | Press Play, track the workout, count qualifying minutes. Logging only. |
| 2 | **Kid app** | iOS (Android later) | Show balance (credit **or** debit), history, today's earned/spent. Also does the iOS game blocking. |
| 3 | **Parent portal** | Web | Set the rules, pair devices, view the ledger, make manual adjustments, receive tamper alerts. |
| 4 | **PC enforcer** | Windows | Count game time, debit the balance, close and block games at the limit. |
| 5 | **Backend** | Supabase (Postgres + Auth + Realtime + Edge Functions) | Single source of truth: rules, ledger, devices. |
| 6 | Android enforcer | Android | Phase 3. |

Priority: **Watch logger → backend → PC enforcer → iOS enforcer → portal polish → Android.**

## 2. Core concepts

- **Family**: one or more parent accounts, one or more children.
- **Child**: has one rule set, one balance, and many devices.
- **Device**: a watch, phone, tablet or PC paired to exactly one child via a
  one-time code shown in the parent portal.
- **Ledger**: append-only entries in *gaming minutes*. Balance = sum of entries.
  - `earn` (+): from an activity session
  - `spend` (−): from enforcer usage heartbeats
  - `adjust` (±): parent manual change, with a required note
  - `expire` (−): optional expiry of old credit
- **Debit / overdraft**: the balance may go negative down to `-overdraft_limit`.
  Play is allowed while `balance > -overdraft_limit`. Future earnings repay
  the debt automatically (no special logic; it's just a sum).

### Rule set (per child, editable in the portal)

| Rule | Default | Notes |
|------|---------|-------|
| `ratio` | 10 | Gaming minutes per qualifying activity minute |
| `min_cadence_spm` | 100 | Steps/min; ~100 spm ≈ brisk walk |
| `min_heart_rate_bpm` | derived | Default 55% of an age-estimated max HR (≈ 0.55 × (220 − age)); parent can override |
| `qualify_fraction` | 0.8 | Share of a minute's samples that must pass both thresholds |
| `min_session_minutes` | 5 | Shorter sessions earn nothing |
| `daily_earn_cap` | 600 | Gaming minutes earnable per day (null = none) |
| `max_bank` | 1200 | Maximum positive balance; excess is discarded |
| `overdraft_limit` | 0 | Allowed debit, in gaming minutes |
| `daily_play_cap` | null | Hard limit per day even if there is credit |
| `play_windows` | null | e.g. weekdays 16:00–20:00; outside these, blocked regardless of balance |
| `expiry_days` | null | Credit older than N days expires (FIFO) |

The server is authoritative: the watch reports *raw per-minute results* and the
server applies the current rules, caps and ratio when writing `earn`.

## 3. Watch logger (watchOS)

- `HKWorkoutSession` + `HKLiveWorkoutBuilder` (activity type `.walking`,
  outdoor/indoor selectable) keeps the app running with the screen off and
  streams heart rate.
- `CMPedometer` on the watch gives live cadence (`currentCadence`).
- Every ~5 s: sample HR and cadence; a sample passes if **both** are at or above
  the threshold. A minute **qualifies** if passing samples ≥ `qualify_fraction`.
- UI: big Play/Pause/End; live "minutes earned" counter; a green/red indicator
  showing whether you're currently above the bar; haptic tick each time a minute
  qualifies.
- Saves the workout to HealthKit (optional, rings credit).
- Upload: a session summary `{session_id (UUID), started_at, ended_at,
  minutes: [{index, passed_samples, total_samples, avg_hr, avg_cadence}]}`.
  The watch talks to the backend directly over Wi-Fi/LTE (an independent watch app) and
  queues offline uploads, retrying with the same `session_id` (idempotent).
- Rules are fetched from the backend and cached on the watch for live feedback.

**Anti-cheat (good enough, not perfect)**
- Requires heart rate *and* cadence, so shaking the watch alone doesn't count.
- No HR when the watch is off the wrist, so the minute fails.
- Server checks: qualifying minutes ≤ wall-clock duration; sessions can't
  overlap; daily cap; the device must be paired to that child.
- Optional later: GPS speed check for outdoor walks.

## 4. Kid app (iOS)

- Balance front and centre: green when in credit, red when in debit, plus how
  much debit headroom is left.
- Today: earned / spent / remaining today (if `daily_play_cap`).
- History list from the ledger.
- Live updates via Supabase Realtime.
- Hosts the iOS enforcement (section 6), so there's one app per child device.

## 5. PC enforcer (Windows) — priority 1 for spending

.NET 8, two processes:

1. **`DigitalRewards.Service`**: a Windows Service running as LocalSystem.
   - Holds the device token and talks to the backend.
   - Detects game processes (WMI `Win32_ProcessStartTrace` / ETW plus periodic
     scan) against a game list: executable names and Steam/Epic install folders.
     The parent picks games from a list the PC reports to the portal.
   - While any game process is running (configurable: *running* vs *foreground*),
     sends a `spend` heartbeat each minute.
   - At the limit (balance ≤ −overdraft, outside a play window, or daily cap reached):
     terminates game processes and kills any relaunch immediately.
   - Offline: keeps a local balance, allows play until it runs out, then blocks;
     reconciles when back online. Blocks if offline > N hours (configurable).
   - Recovery: service set to auto-restart; heartbeat to the server every minute.
     If heartbeats stop while the PC is up, the parent is alerted.
2. **`DigitalRewards.Tray`**: runs in the child's session; shows balance and
   toasts at 10/5/1 minute(s) remaining. It's display-only and can't change anything.

**Setup requirement:** the child uses a **standard (non-admin) Windows account**.
Otherwise they can stop the service. The installer (MSIX or WiX) needs admin rights.

## 6. iOS / iPadOS enforcer — priority 2 for spending

Uses Apple's Screen Time APIs: `FamilyControls`, `ManagedSettings`,
`DeviceActivity`. Requires the **Family Controls (Distribution) entitlement**,
requested from Apple.

- Authorization: `AuthorizationCenter.shared.requestAuthorization(for: .child)`
  on the child's device. The child must be in the parent's Family Sharing group,
  and a parent approves. After that, the app **can't be deleted** without the parent.
- Game selection: `FamilyActivityPicker` on the child's device (parent present).
  The resulting tokens are opaque and device-specific, so they're stored locally in the App Group.
- Blocking: `ManagedSettingsStore.shield.applications/applicationCategories`.
- Spending (to prove in a spike):
  1. When there's credit, remove the shield and start a `DeviceActivity` schedule
     with threshold events at every minute up to the available play minutes.
  2. The `DeviceActivityMonitor` extension receives `eventDidReachThreshold`,
     records the used minute to the App Group, and re-applies the shield at the last one.
  3. The app (or a background task) syncs used minutes as `spend` entries.
  4. When the balance changes (Realtime/push), re-plan the schedule.
- Custom shield screen (`ShieldConfiguration` extension): "Out of minutes. Go
  for a walk!" with the current balance.

**Known risks to prove early:** the per-minute event limit and timing accuracy;
extension memory and runtime limits; network access from the extensions (assume none,
so use App Group plus app sync).

## 7. Parent portal (web)

Next.js (or SvelteKit) on Supabase Auth.

- Family setup, invite a second parent.
- Child profiles, each with its rule set (section 2).
- Device pairing: generate a 6-digit code; enter it in the watch/app/PC.
- Ledger view and manual adjust (with a note).
- Device list showing last-seen, enforcer health, and tamper alerts (email/push).
- PC game list: tick which reported executables count as games.

## 8. Data model (Postgres)

```
families(id, name, created_at)
parents(user_id → auth.users, family_id)
children(id, family_id, name, birth_year, timezone)
rules(child_id PK, ratio, min_cadence_spm, min_heart_rate_bpm, qualify_fraction,
      min_session_minutes, daily_earn_cap, max_bank, overdraft_limit,
      daily_play_cap, play_windows jsonb, expiry_days, updated_at)
devices(id, child_id, kind[watch|ios|android|windows], name, token_hash,
        last_seen_at, meta jsonb)
pairing_codes(code, child_id, kind, expires_at)
activity_sessions(id uuid PK, child_id, device_id, started_at, ended_at,
                  minutes jsonb, qualifying_minutes, created_at)
ledger(id, child_id, kind[earn|spend|adjust|expire], minutes int,
       ref text UNIQUE, device_id, note, created_at)
pc_games(id, device_id, exe_name, path, is_game bool)
```

- `ref` makes writes idempotent (e.g. `session:<uuid>`, `spend:<device>:<minute-ts>`).
- Row-level security: parents see their family; device tokens can only write
  their own child's sessions/spend and read the balance and rules.
- Edge functions: `submit_session`, `spend_heartbeat`, `pair_device`,
  `get_status` (balance, can_play, reason, remaining today).

## 9. Phases

1. **Foundation**: Supabase schema + RLS + edge functions; minimal portal
   (login, child, rules, pairing).
2. **Earn**: Watch logger + kid iOS app (balance/history only).
3. **Spend on PC**: Windows service + tray.
4. **Spend on iOS**: Family Controls spike first, then the full feature.
5. **Polish**: notifications, tamper alerts, play windows, expiry.
6. **Android**: kid app + enforcer (UsageStats + foreground service + Device Owner
   or Accessibility, subject to Play policy).

## 10. Open questions

- Does each child have their **own iPhone** paired to the watch, or a watch on
  **Apple Watch Family Setup** (managed from a parent's phone)? Family Setup limits
  third-party HealthKit/workout access and needs checking. The independent-watch-app
  design above is meant to cover both.
- Does PC play time count only while the game is **in the foreground**, or whenever it's running?
- Does the debit allowance need a time limit (e.g. must be repaid within 7 days)?
- Should the portal also be available as a parent iOS app, or is web enough?
