# DigitalRewards — Apple apps

Two apps in one Xcode project, plus a Swift package:

| Target | Platform | What it does |
|--------|----------|--------------|
| `DigitalRewards` | iOS / iPadOS 17+ | One app with **Child** and **Parent** modes (chosen on first launch). |
| `DigitalRewardsWatch` | watchOS 10+ | Workout logger: Walk/Run, Cycle, Other. Logging only. |
| `RewardsCore` (package) | iOS, watchOS, macOS | Pure logic from `docs/CONTRACT.md`: qualification, earn resolution (overrides + bonuses), ledger fold, play status, rules diff. |

iOS game blocking (Screen Time / Family Controls) is **not** included yet.

All data is in the family's iCloud (CloudKit). There's no server.

## Prerequisites

- Xcode 16 or later, a paid Apple Developer account.
- `brew install xcodegen`
- A real iPhone and Apple Watch for the workout and sharing features. The simulator can't
  accept CloudKit shares between accounts or produce heart-rate data.

## First-time setup

1. `project.yml` sets `DEVELOPMENT_TEAM` and `APP_BUNDLE_ID` (the iPhone app's bundle ID).
   The watch app's ID (`$(APP_BUNDLE_ID).watchkitapp`) and `WKCompanionAppBundleIdentifier`
   are derived from it. Change bundle IDs **only here**, not in Xcode: `xcodegen generate`
   overwrites Xcode edits, and the watch ID must start with the iPhone app's ID or
   App Store validation fails. The iCloud container is set separately in
   `project.yml` (entitlements) and `Shared/AppConfig.swift`.
2. `cd apple && xcodegen generate && open DigitalRewards.xcodeproj`
3. In the Apple Developer portal, Xcode's automatic signing usually does this for you, but check:
   - **iCloud** with CloudKit and container `iCloud.com.digitalrewards.app`, on both App IDs.
   - **Push Notifications** on the iOS App ID (CloudKit silent pushes).
   - **HealthKit** on the watch App ID.
   - **Background Modes** on iOS: Remote notifications and Background fetch (set in Info.plist by `project.yml`).
4. Run the package tests: `cd Packages/RewardsCore && swift test`. They load every case in
   `shared/test-vectors/*.json`, the same vectors the Windows app is tested against.

If the watch app doesn't end up inside the iOS app (XcodeGen versions differ on embedding
single-target watch apps), add it under the iOS target › Build Phases › **Embed Watch Content**,
destination "Products Directory", subpath `$(CONTENTS_FOLDER_PATH)/Watch`.

## Distributing (TestFlight / App Store)

1. **Create the app record yourself** in App Store Connect (Apps › + › New App): platform iOS,
   bundle ID `com.paulrobinson.digitalrewards.app`, SKU anything. The app **name must be
   unique across the whole App Store**. "DigitalRewards" is probably taken, which is the usual reason
   Xcode's "create app record" step fails. Pick something like "DigitalRewards Family".
   Creating records also needs the **Account Holder, Admin or App Manager** role and a signed
   Paid Apps / Free Apps agreement (App Store Connect › Business).
2. **Deploy the CloudKit schema to Production** (below) before testers use a TestFlight build.
   TestFlight and App Store builds talk to the Production environment.
3. Product › Archive, then Distribute App › App Store Connect.

App icons come from `iOS/Assets.xcassets` and `Watch/Assets.xcassets` (one 1024×1024 image each),
drawn by `tools/make_icon.py`. Replace `AppIcon.png` in both with a real design whenever you like.

## CloudKit schema

In the **Development** environment, record types are created automatically the first time each is
saved. Use the app end to end once (add a child, join, do a workout, add an adjustment, a bonus, a
workout edit, change rules, set alert prefs, invite a parent), then check the CloudKit Console
has these types:

| Database | Record types |
|----------|--------------|
| Private / shared (custom zones) | `Child`, `Rules`, `Adjustment`, `SessionOverride`, `Bonus`, `RulesChange`, `Parent`, `AllowList`, `Session`, `Spend`, `Device`, `AlertPrefs` |
| Public | `Invite` |

`Link` and `ShareLink` were used by an earlier design. If they're already in your Production schema,
leave them: CloudKit can't remove types, and nothing uses them now.

Fields are listed in `docs/CONTRACT.md` §6. `Spend` and the `detectedApps` field on `Device` are
written by the Windows app: run it once against Development, or add them by hand in the Console.

**Indexes:** none are needed. The apps never run `CKQuery`. They read zones with a
zone-changes fetch and public records by record name.

**Public database security:** the default roles (any signed-in user can create, only the creator can
write) are what the apps rely on. Leave them.

**Before TestFlight / App Store:** in the CloudKit Console, **Deploy Schema Changes** to Production.
Production builds can't create record types.

## How it fits together

```
Parent iPhone (owns Family-<childId>)   ──share rw──▶ other parents
                                        └─share ro──▶ child
              (owns Activity-<childId>) ──share rw──▶ other parents and the child
Apple Watch   (child's Apple ID) writes Session      ─▶ Activity-<childId> (shared DB)
Child iPhone  (child's Apple ID) writes Device       ─▶ Activity-<childId> (shared DB)
Windows PC    (child's Apple ID) writes Spend/Device ─▶ Activity-<childId> (shared DB)
```

Everything lives in the iCloud of the parent who added the child, so nothing uses the child's
iCloud storage.

- **Add child** (Parent mode): creates both zones, shares them, and shows a 6-digit code. The code is an
  `Invite` record in the public DB holding both share URLs; only invited Apple IDs can accept them.
- **Join** (Child mode): enter the code. The app accepts both shares; it creates nothing itself.
  A child shows as "waiting to join" for parents until one of their devices writes to the Activity zone
  (the iPhone app writes a `Device` record on its first refresh).
- **Invite parent**: adds them read-write to every Family and Activity share you're allowed to change,
  writes a placeholder `Parent` record (`parent-invite-…`) and gives a code. When they join, their app
  accepts every share and replaces the placeholder with `parent-<their user record name>`.
- **Older children** (added before activity moved to the parent's iCloud) have no Activity zone. Open
  the child in Parent mode and tap **New invite code**: that creates and shares the zone, and the child
  enters the new code.
- **Balance** is computed on each device with `RewardsCore` (contract §3–5). The child sees every parent action
  with name and note: adjustments, edited/voided workouts (original struck through), bonuses (and a
  "2× bonus" badge on boosted workouts), and rules changes with a diff summary.
- **Watch** gets rules, birth year and bonuses from the iPhone over WatchConnectivity and directly
  from CloudKit. It saves `Session` with the *base* minutes; bonuses are shown live but applied at fold time.
- **Sync** (`Shared/SyncEngine.swift`): each device keeps a local mirror of the zones it reads, in Caches.
  - Each refresh asks CloudKit which zones changed since the last database change token (private and
    shared DBs), then fetches only the records changed or deleted in those zones since each zone's own
    change token.
  - Records and tokens are written together, as a base file plus small delta files, so a token is never
    saved ahead of its records.
  - The app's own saves and deletes go into the mirror immediately, and screens are built from the
    mirror, so the last known state shows at launch and offline.
  - An expired token, a deleted zone, a purged cache or a different iCloud account makes that part start
    again from scratch. The watch mirrors only the shared DB, which holds the family zone.

## Testing order

1. `swift test` in `Packages/RewardsCore`.
2. Parent device (Apple ID A): choose Parent, set up, add a child using Apple ID C's email. Note the code.
3. Child iPhone (Apple ID C): choose Child, enter the code. The balance screen should appear.
4. Pull to refresh on the parent device: the child should stop showing "Waiting to join".
5. Watch paired to the child's iPhone: open the app once (allow Health), do a 3-minute brisk walk, End.
   The child and parent should see the session.
6. Parent: add/remove minutes, edit and void a workout, add a 2× bonus, change rules. Check the child's history shows each one with the note.
7. Second parent (Apple ID B): on the first parent device, Parents › Invite a parent; on B's device, Parent › set up › Parents › Join a family with a code.
8. Two parents editing rules at once: the second save shows the conflict dialog.

## Known limitations / to verify on device

- **Participant lookup** (`CKFetchShareParticipantsOperation`) only finds Apple IDs by the email/phone
  they're registered with in iCloud. If lookup fails, try the other identifier.
- **Who can add participants**: CloudKit normally only lets the zone *owner* change a share. Inviting
  or removing a parent from a child that another parent added is attempted, and listed as
  "not shared" if CloudKit refuses. That parent then has to do it. The CloudKit administrator
  participant role isn't used because its availability needs checking.
- **"Take over child"** copies the family zone into your iCloud and re-shares it. The child must enter the new
  code (Child › ••• › Join with a new code). The old zone is ignored when both exist.
- **Alerts** are local notifications posted after a refresh triggered by a CloudKit silent push
  or a background refresh. iOS throttles both, so alerts can be late. "PC stopped reporting" only fires
  when a refresh runs.
- No app icons are included.
