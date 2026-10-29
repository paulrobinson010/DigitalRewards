# CloudKit schema

`schema.ckdb` defines every record type and field the apps use (see `docs/CONTRACT.md` §6).
TestFlight and App Store builds run against the **Production** environment, which can't create
record types on the fly. Get the types into **Development**, then deploy them.

## Easiest: from the app

1. Run the iPhone app from Xcode (Debug build, so it uses Development) and pick Parent mode.
2. Tap ⋯ › **Create CloudKit schema**. It saves one sample record of every type, then deletes them;
   the types and fields stay. The menu item only exists in debug builds.
3. In the [CloudKit Console](https://icloud.developer.apple.com/), open the container and use
   **Deploy Schema Changes** to Production.

## Alternative: cktool

```sh
# Once: create a management token in the CloudKit Console (account menu → Manage Tokens),
# then save it for cktool:
xcrun cktool save-token --type management

# Import into Development (re-run whenever schema.ckdb changes):
xcrun cktool import-schema \
  --team-id UPF9A27355 \
  --container-id iCloud.com.digitalrewards.app \
  --environment development \
  --file cloudkit/schema.ckdb
```

Then in the [CloudKit Console](https://icloud.developer.apple.com/): the container → **Deploy Schema
Changes…** → Deploy to Production.

Check it afterwards with `xcrun cktool export-schema … --environment production`.
Production schema changes are additive only: fields and types can be added but never removed or retyped.
