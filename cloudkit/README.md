# CloudKit schema

`schema.ckdb` defines every record type and field the apps use (see `docs/CONTRACT.md` §6).
TestFlight and App Store builds run against the **Production** environment, which can't create
record types on the fly. Load the schema into **Development** and deploy it from there:

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
