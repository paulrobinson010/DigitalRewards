# Go AFK for Windows

The Windows enforcer counts a child's play time, debits their Go AFK balance in iCloud,
and closes apps when time runs out. It implements `docs/SPEC.md` §6 and `docs/CONTRACT.md`.

## Projects

| Project | Target | What it is |
|---------|--------|------------|
| `src/DigitalRewards.Core` | net8.0 | Contract logic: rules, qualification, earn resolution (overrides/bonuses), ledger fold, play status. Pure, no I/O. |
| `src/DigitalRewards.CloudKit` | net8.0 | CloudKit Web Services REST client and the contract's record mapping (`ChildSnapshot`). |
| `src/DigitalRewards.Enforcement` | net8.0 | The service's brain behind interfaces: minute accounting, block decisions, offline rule, sync rounds, warnings, state store, agent pipe protocol. |
| `src/DigitalRewards.Service` | net8.0-windows | Windows Service (LocalSystem): WTS sessions, process kill, agent launch (`CreateProcessAsUser`), DPAPI state, named-pipe server. |
| `src/DigitalRewards.Tray` | net8.0-windows (WinForms) | Per-user agent: reports the foreground app every 2 s, shows balance, 10/5/1-minute warnings, "Time's up", iCloud sign-in. |
| `tests/*` | net8.0 | xUnit. Core tests run every case in `shared/test-vectors/*.json`. |

## How it works

```
 child's session                         session 0
┌──────────────────────┐  named pipe   ┌───────────────────────────────┐   HTTPS   ┌──────────┐
│ DigitalRewards.Tray  │ ────────────► │ DigitalRewards.Service        │ ────────► │ CloudKit │
│ foreground exe, idle │ ◄──────────── │ accounting · status · enforce │ ◄──────── │ (iCloud) │
│ balance, warnings    │   status      │ sync every 30 s               │           └──────────┘
└──────────────────────┘               └───────────────────────────────┘
```

- **Counting.** A service can't see the user's screen, so the tray agent reports the foreground
  process every 2 seconds. Time counts as play when that app isn't allowed and there was input in the
  last 5 minutes. Every 60 seconds of play becomes one `Spend` record (`spend-<deviceId>-<yyyyMMddHHmm>`,
  so retries can't double-count).
- **Allowed apps.** These are free to use: anything under `%SystemRoot%`, a list of Windows shell
  components (`AllowPolicy.SystemExecutables`), the DigitalRewards apps, and the parent's
  `AllowList` record for this PC (`allow-<deviceId>`). Everything else costs time.
- **Blocking.** The service blocks when the contract's play status says `canPlay = false` (out of minutes
  past the debit limit, outside play hours, or daily cap reached), or when the PC hasn't synced for
  24 hours. While blocked, every non-allowed process in that session is closed, checked every second,
  so relaunches die immediately. The tray shows a "Time's up" window.
- **Tamper resistance.**
  - The service relaunches the agent if it isn't running or goes quiet for 20 seconds.
  - If the agent is silent for more than 60 seconds in an active session, that time counts as play.
  - The pipe only accepts the installed `DigitalRewards.Tray.exe`, identified by its process image path.
  - The caller's Windows account comes from the pipe itself, so an agent can't claim to be another user.
  - Children must use **standard** accounts: they can't stop the service, edit Program Files, or read the state folder.
- **Balance.** The service applies the CONTRACT §3–5 rules to the cached Family zone (rules, adjustments,
  overrides, bonuses, allow list) and `Activity-<childId>` zone (sessions, spends), plus spends recorded but not yet uploaded.
  Both zones belong to the parent who added the child and are shared with the child, so the PC uses the
  child's **shared** database only and nothing counts against the child's iCloud storage.
- **Sync.** Every 30 seconds per signed-in account:
  1. Upload pending spends (`records/modify`, `create`; `CONFLICT` means already saved).
  2. Pull changes from the shared `Family-<childId>` and `Activity-<childId>` zones (`changes/zone`, incremental via sync tokens).
  3. Every 5 minutes, write the `Device` heartbeat with the apps found on this PC (Uninstall registry plus apps seen in the foreground) for the parent's allow-list picker.
- **State** lives in `%ProgramData%\DigitalRewards`, with an ACL of SYSTEM and Administrators only. There is one DPAPI-encrypted
  file per Windows account, holding the iCloud web token, sync tokens, cached records and pending spends.

## Build and test (any OS)

```sh
cd windows
dotnet build DigitalRewards.sln
dotnet test DigitalRewards.sln
```

`EnableWindowsTargeting` lets the Windows projects build on macOS/Linux. A source-built SDK
(e.g. Ubuntu's `dotnet-sdk-8.0`) lacks the WindowsDesktop targets the tray needs; use Microsoft's SDK.

## CloudKit console setup (once)

1. In the [CloudKit console](https://icloud.developer.apple.com/), open the container
   (default `iCloud.com.digitalrewards.app`; it must match `AppConfig.swift`).
2. **API Access → Tokens → New token**:
   - Name: `Windows enforcer`
   - Sign in callback: **URL Redirect**, `https://paulrobinson010.github.io/DigitalRewards/ck-callback/`.
     Production only accepts https, so this GitHub Pages page (`site/ck-callback/`, published by the
     **Sign-in page** workflow) forwards the token to the tray app on `http://localhost:43117/ck-callback`.
     Turn Pages on once: repository Settings → Pages → Source: **GitHub Actions**. (Development tokens
     may also use `http://localhost:43117/ck-callback` directly.) GitHub Pages on a private repository
     needs a paid GitHub plan; otherwise host `site/` on any static https host and use that URL.
   - Copy the token; it goes into the `CLOUDKIT_API_TOKEN` GitHub secret (or `Install.ps1 -ApiToken`).
3. Make sure the schema from `docs/CONTRACT.md` §6 is deployed to the environment you use
   (`development` while testing, `production` for App Store builds). The enforcer reads with
   `changes/zone` and `records/lookup`, so it needs no extra query indexes.

## Install on a PC (GitHub Actions build, recommended)

GitHub builds a ready-to-install package on every push to `main` that touches `windows/` or
`shared/` (also runnable by hand: Actions → **Windows app** → Run workflow). The CloudKit API token
is baked into the package's `appsettings.json` from a repository secret.

One-time setup on GitHub (Settings → Secrets and variables → Actions):
- **Secret** `CLOUDKIT_API_TOKEN`: the token from the CloudKit console.
- Optional **variable** `CLOUDKIT_ENVIRONMENT`: `production` (default; matches TestFlight and App Store
  builds of the iPhone app) or `development` (matches builds run from Xcode).

To install:
1. Actions → latest **Windows app** run → download the `DigitalRewards-Windows-…` artifact (a zip).
2. Unzip it on the PC and double-click **Install.cmd**. Accept the administrator prompt.
3. To remove it later: double-click **Uninstall.cmd**.

## Install on a PC (build it yourself)

Prerequisites:
- Windows 10/11 x64.
- The .NET 8 SDK on the machine that builds it (the output is self-contained, so the PC itself needs no .NET).
- Each child already set up on their iPhone: they've joined the family in the DigitalRewards app with the parent's code,
  which accepts both of the child's shares (`Family-<childId>` and `Activity-<childId>`). Until then, sign-in on the PC
  says the family isn't fully set up; if a share disappears later, the tray shows "Finish joining your family on your iPhone".

From an **elevated** PowerShell in `windows\install`:

```powershell
.\Install.ps1 -ApiToken <token> -Environment development
# or, from a folder you already published:
.\Install.ps1 -SourceDir C:\path\to\publish -ApiToken <token>
```

This installs to `C:\Program Files\DigitalRewards`, registers the `DigitalRewards` service (automatic start,
restart on failure) and starts it. `Uninstall.ps1 [-RemoveData]` removes it.

### Each child signs in once

1. Make sure the child's Windows account is a **standard user**: Settings → Accounts → Family & other users.
2. The child logs in. The DigitalRewards icon appears in the tray (grey `?`).
3. Right-click it → **Sign in to iCloud…**. The browser opens Apple's sign-in page; the child signs in
   with **their own** Apple ID. Apple redirects to the sign-in page, which forwards to `http://localhost:43117/ck-callback`; the tray hands the token to
   the service, and the icon turns green with the minutes left.

Windows accounts that never sign in aren't restricted, so give parents and guests their own accounts.

## Configuration (`appsettings.json`, next to the service)

| Key | Default | |
|-----|---------|--|
| `CloudKit:ContainerId` | `iCloud.com.digitalrewards.app` | Must match the Apple apps. |
| `CloudKit:Environment` | `development` | `production` for App Store builds of the apps. |
| `CloudKit:ApiToken` | — | From the CloudKit console. |
| `Enforcer:OfflineLimitHours` | 24 | Block after this long without a successful sync. |
| `Enforcer:SyncIntervalSeconds` | 30 | |
| `Enforcer:HeartbeatMinutes` | 5 | `Device.lastSeenAt` cadence (parent's "device stopped reporting" alert). |
| `Enforcer:VerifyAgentPath` | true | Only the installed tray may use the pipe. |
| `Enforcer:AgentPath` | next to the service | |

Logs go to the Windows Event Log (Application, source `DigitalRewards`).

## Limitations / known gaps

- **Not run on Windows yet.**
  - The P/Invoke, WTS, DPAPI, pipe ACL and WinForms code compiles but was written and unit-tested on Linux.
  - The platform-independent logic (accounting, decisions, sync, state, CloudKit encoding) is unit-tested.
  - The service/tray glue needs a first run on a real PC.
- **CloudKit Web Services details were written from memory** and need a spike against a real container.
  See "Assumptions to verify" below.
- **Allowed apps:**
  - Allowing a browser makes browser games free.
  - Store (UWP) games are detected through their frame window but can't be allowed by path, only by exe name.
- **The service can't distinguish a game left running in the background** when the time limit is hit; all non-allowed processes are closed.
- **One child per Windows account.** A Windows account shared by several children isn't supported.
- **An administrator can always switch DigitalRewards off.** That's why children must use standard accounts.

## Assumptions to verify (CloudKit Web Services)

- URL shape `https://api.apple-cloudkit.com/database/1/{container}/{env}/{public|private|shared}/…`
  with `ckAPIToken` and `ckWebAuthToken` query parameters. `users/current` is called on the `public` database.
- An unauthenticated call returns HTTP **421** `AUTHENTICATION_REQUIRED` with a `redirectURL` to Apple's sign-in.
  After sign-in, Apple sends the browser to the token's URL-redirect callback with **`ckWebAuthToken`** in the
  query string. The tray also accepts it in the fragment, or as `ckSession`.
- **Token rotation**: the client adopts a new token if a response carries one in an
  `X-Apple-CloudKit-Web-Auth-Token` header or a top-level `ckWebAuthToken` field. Whether CloudKit rotates
  tokens at all, and their lifetime, is unverified. On 421 the child is asked to sign in again.
- `changes/zone` body `{"zones":[{"zoneID","syncToken","resultsLimit"}]}` → `{"zones":[{"records","syncToken","moreComing"}]}`,
  with deletions as `{"recordName","deleted":true}`. Expired tokens are reported as `CHANGE_TOKEN_EXPIRED`.
- `records/modify` per-record error for creating an existing record is assumed to be `CONFLICT`
  (`EXISTS`/`UNIQUE_FIELD_ERROR` are also treated as "already saved"). `forceReplace` is assumed to create a
  record if it's missing (used for `Device`).
- Shared-database access (`zones/list`, `changes/zone`, `records/lookup` and `records/modify` on `/shared/`) works
  with a web auth token for shares the user accepted on their iPhone, including **writes** to the read-write
  `Activity-<childId>` share.
- A zone that isn't (or is no longer) shared with the child is reported as `ZONE_NOT_FOUND` or `USER_DELETED_ZONE`.
