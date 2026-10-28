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

1. Edit `project.yml`:
   - `DEVELOPMENT_TEAM`: your Team ID.
   - If `com.digitalrewards.app` is taken, change the bundle IDs (iOS app, watch app
     `…watchkitapp`, `WKCompanionAppBundleIdentifier`), the BGTask identifier, and the iCloud
     container everywhere it appears. The container is also in `Shared/AppConfig.swift`.
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

## CloudKit schema

In the **Development** environment, record types are created automatically the first time each is
saved. Use the app end to end once (add a child, join, do a workout, add an adjustment, a bonus, a
workout edit, change rules, set alert prefs, invite a parent), then check the CloudKit Console
has these types:

| Database | Record types |
|----------|--------------|
| Private / shared (custom zones) | `Child`, `Rules`, `Adjustment`, `SessionOverride`, `Bonus`, `RulesChange`, `Parent`, `AllowList`, `Link`, `Session`, `Spend`, `Device`, `AlertPrefs` |
| Public | `Invite`, `ShareLink` |

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
Parent iPhone (owns Family-<childId> zone) ──share rw──▶ other parents
                                         └─share ro──▶ child
Child iPhone  (owns Activity zone)       ──share ro──▶ every parent
Apple Watch   (child's Apple ID) writes Session ─▶ child's Activity zone
Windows PC    (child's Apple ID) writes Spend/Device ─▶ child's Activity zone
```

- **Add child** (Parent mode): creates the family zone, shares it, and shows a 6-digit code. The code is an
  `Invite` record in the public DB holding the share URL; only invited Apple IDs can accept it.
- **Join** (Child mode): enter the code. The app accepts the family share, creates the `Activity`
  zone, shares it read-only with every parent and publishes the share URL as `ShareLink`. Parents'
  apps accept it automatically on their next refresh.
- **Invite parent**: adds them read-write to every family share you're allowed to change, writes a
  placeholder `Parent` record (`parent-invite-…`) and gives a code. When they join, their app
  replaces it with `parent-<their user record name>`, and children's apps add them to the Activity share.
- **Balance** is computed on each device with `RewardsCore` (contract §3–5). The child sees every parent action
  with name and note: adjustments, edited/voided workouts (original struck through), bonuses (and a
  "2× bonus" badge on boosted workouts), and rules changes with a diff summary.
- **Watch** gets rules, birth year and bonuses from the iPhone over WatchConnectivity and directly
  from CloudKit. It saves `Session` with the *base* minutes; bonuses are shown live but applied at fold time.

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
- **Full zone fetch**: every refresh downloads each zone in full, with no change tokens. That's fine for months of
  data. A year of daily PC play is ~20k `Spend` records, so add change-token caching before then.
- Offline display isn't cached on iPhone: the app shows data after the first successful refresh each launch.
- No app icons are included.
