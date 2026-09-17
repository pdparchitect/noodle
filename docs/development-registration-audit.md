# Noodle registration audit — 17 September 2026

This records the registrations observed before the Dev rename, using bundle metadata,
`pluginkit -m -A -D -v`, `sfltool dumpbtm`, launchd status and Runbar's registry.
The screenshots combine apps, account services and extension hosts. A background-item
row does not necessarily mean a separate process is running.

## Names and purpose

| Component | Production name / registration | Previous development name | Development name / registration after this change | Purpose / disposition |
| --- | --- | --- | --- | --- |
| Main app | Noodle | Noodle Local | Noodle Dev | Keep one app per environment; separate conversations, bots and settings. |
| Share extension | Send to Noodle; Settings groups it under Noodle | Send to Noodle Local | Send to Noodle Dev | Keep one per environment; opens only its matching Noodle app. |
| Noodle links | `noodle://` | `noodle-local://` | `noodle-dev://` | Separate launch routing. Google OAuth callback schemes stay unchanged. |
| Applet app | Noodle Applet | Noodle Applet Local | Noodle Applet Dev | Keep one per environment; separate libraries and runtime data. |
| Applet documents / links | `.noodlet` / `noodlet://` | `.noodlet-local` / `noodlet-local://` | `.noodlet-dev` / `noodlet-dev://` | Register only the matching environment. Existing Local documents/links remain readable by Dev code for compatibility; new output uses Dev. |
| Applet preview | Noodle Applet → Quick Look | Noodle Applet Local → Quick Look | Noodle Applet Dev → Quick Look | One preview extension per app. |
| Computer app | Noodle Computer | Noodle Computer Local | Noodle Computer Dev | Keep one per environment; separate computer libraries, services and accounts. |
| Computer documents | `.noodlecomputer` | **Also claimed `.noodlecomputer`** | `.noodlecomputer-dev` | Fix the shared file association. Dev no longer registers the production document type. |
| Computer preview + thumbnail | Noodle Computer → Quick Look, Quick Look | Noodle Computer Local → Quick Look, Quick Look | Noodle Computer Dev → Quick Look, Quick Look | Two distinct extension points: full preview and thumbnail. Both are intentional. |
| Account setup / privileged service | Installed release: LocalMacSetup; current source label: Noodle Computer Setup | Noodle Computer Local Setup | Noodle Computer Dev Setup | Keep both environments' services. This component creates/removes managed macOS accounts and homes; it is distinct from the sandboxed Computer UI. Production installation remains untouched. |
| Account desktop helper | Noodle Local Mac Desktop | Noodle Local Mac Desktop Local | Noodle Local Mac Desktop Dev | Runs inside each managed account. “Local Mac” describes the computer type and stays. |
| Runbar | No production launch entry | Build & Launch Local | Build & Launch Dev | All three launchers force development and reject production output. |
| Test app | None | Noodle Computer Tests | Noodle Computer Tests | Test fixture, not another user environment. Old registration is a cleanup candidate. New fixtures use `.noodlecomputer-tests`, never production's type. |

## Stable internal identities

The visible rename preserves existing internal `.local` IDs. Changing these would
create different sandbox containers, app groups, Keychain identities and privacy
registrations. These are compatibility identifiers, not the names shown to users.

| Identity | Production | Dev (preserved) |
| --- | --- | --- |
| Noodle bundle / sandbox | `com.pdparchitect.noodle` | `com.pdparchitect.noodle.local` |
| Share extension | `com.pdparchitect.noodle.share` | `com.pdparchitect.noodle.local.share` |
| Applet bundle / sandbox | `com.pdparchitect.noodle.applet` | `com.pdparchitect.noodle.applet.local` |
| Applet preview / CLI | Applet ID + `.preview` / `.cli` | Dev Applet ID + `.preview` / `.cli` |
| Noodle sharing group | `S8VNVK39LH.com.pdparchitect.noodle.sharing` | `S8VNVK39LH.com.pdparchitect.noodle.local.sharing` |
| Applet app group | `S8VNVK39LH.com.pdparchitect.noodle.applets` | `S8VNVK39LH.com.pdparchitect.noodle.applets.local` |
| Computer bundle / sandbox | `com.pdparchitect.noodle.computer` | `com.pdparchitect.noodle.computer.local` |
| Computer preview / thumbnail | Computer ID + `.preview` / `.thumbnail` | Dev Computer ID + `.preview` / `.thumbnail` |
| Computer app group | `S8VNVK39LH.com.pdparchitect.noodle.computers` | `S8VNVK39LH.com.pdparchitect.noodle.computers.local` |
| Setup / service / desktop signing IDs | Computer ID + `.localmacsetup` / `.localmac` / `.desktop` | Dev Computer ID + the same suffixes |
| launchd / Mach service | `S8VNVK39LH.com.pdparchitect.noodle.computers.localmac` | `S8VNVK39LH.com.pdparchitect.noodle.computers.local.localmac` |
| Managed account records | `/Library/Application Support/Noodle Computer/Local Mac` | `/Library/Application Support/Noodle Computer Local/Local Mac` |
| Computer document UTI | `com.pdparchitect.noodle.computer-reference` | `com.pdparchitect.noodle.computer-reference-dev` |
| Applet document UTI | `com.pdparchitect.noodle.noodlet` | `com.pdparchitect.noodle.noodlet-dev` |

## What needs cleanup

| Observed item | Evidence / exact location | Action |
| --- | --- | --- |
| Second production Computer extension host | Both `/Applications/Noodle Computer.app` and `.build/Noodle Computer.app` have registered preview + thumbnail extensions with the same production IDs. | Keep `/Applications` production. Unregister the exact `.build` copy and remove/archive that generated bundle when it is no longer needed. This is a real duplicate. |
| Second production Noodle share host | Both `/Applications/Noodle.app` and `.build/Noodle.app` have registered `com.pdparchitect.noodle.share`. | Keep `/Applications` production; retire the exact generated `.build` production copy. |
| Computer Tests background item | Background-items database points at `.build/Noodle Computer Tests.app`. Preview/thumbnail child records are cached there, though absent from current pluginkit inventory. | Retire that test bundle and its exact registrations after tests stop. Do not delete a user computer or account. |
| Old Applet build path | Background-items cache mentions `.build/Noodle Applet.app`; pluginkit currently lists the installed Applet preview only. | Old build/cache cleanup candidate, not evidence of a second active account service. |
| Old Local development bundles | `.build/Noodle Local.app` and `.build/Noodle Applet Local.app` | After switching to Dev builds, unregister and retire old generated copies so Launch Services cannot select stale code. Preserve their sandbox data. |
| Old Computer Local paths | `/Applications/Noodle Computer Local.app`, `.build/Noodle Computer Local.app` | Retired after confirming the Dev service registration points into `/Applications/Noodle Computer Dev.app`. Subsequent installations do not recreate them. |
| Other test / backup app bundles | `.build/Noodle Files Preview.app`, `.build/Noodle Overlay Tests.app`, `.build/Noodle.before-mila-repair.app`, and other UI fixture bundles | Review and retire as generated artifacts when unused. Their existence alone is not proof of an active registration. |
| LocalMacSetup | Active production service under `/Applications/Noodle Computer.app/Contents/Helpers/LocalMacSetup.app` | **Keep.** It belongs to production. Its vague label can be corrected by a future production release. |
| Dev Setup | Active development service, originally under `/Applications/Noodle Computer Local.app/Contents/Helpers/LocalMacSetup.app` | **Keep.** Rename display label without changing the service identity or account records. |

Paths beginning `.build/` are relative to `/Users/pdp/Documents/GitHub/pdparchitect/noodle`.
Background-items records appear in multiple user domains; repeated records across
those domains are not automatically duplicate installations. No global background-item
reset, production uninstall, service removal or account deletion is part of this audit.
macOS may retain historical labels until it refreshes registrations; a source rename
alone cannot guarantee immediate removal of cached Settings rows.

## Verification

All three Dev apps were built and their signed bundles checked. Launch Services
registered the three Dev apps; PluginKit readback confirmed the Dev sharing,
Applet preview, and Computer preview/thumbnail extensions at their new paths. Computer Dev was
installed in `/Applications`; the new Dev build path resolves to that one installation.
The temporary Local aliases were subsequently retired during cleanup. Window, About, Help and permission labels
follow the build name. The main app's sharing extension uses `noodle-dev://`.
Runbar's three existing entries were updated through Runbar and read back; their
development-only commands and environment guards remain intact.

The targeted suites passed: 51 Local Mac tests, 7 Computer document tests,
3 Computer identity tests, 5 Applet identity/compatibility tests, 13 Noodle routing
and documentation tests, and 10 installer/launcher tests. Installer fixtures cover
rollback during the Local-to-Dev path change and refusal to replace production.
The message reference was regenerated from the catalogue. No real account or
computer was created, started or deleted during these checks. UI validation remains
for the user.

Sandbox entitlements were not widened. The signed apps retain these keys:

- Noodle Dev: `app-sandbox`, `application-groups`, `device.audio-input`,
  `files.user-selected.read-only`, `network.client`,
  `temporary-exception.files.home-relative-path.read-only`,
  `temporary-exception.files.home-relative-path.read-write`,
  `temporary-exception.mach-lookup.global-name`.
- Applet Dev: `app-sandbox`, `application-groups`, `files.bookmarks.app-scope`,
  `files.user-selected.read-write`, `network.client`,
  `temporary-exception.mach-lookup.global-name`.
- Computer Dev: `app-sandbox`, `application-groups`,
  `files.user-selected.read-write`, `network.client`, `virtualization`,
  `temporary-exception.mach-lookup.global-name`.

All entitlement names above have the `com.apple.security.` prefix. Existing
Sparkle helper boundaries remain unchanged. Computer's preview/thumbnail helpers
retain sandbox-only entitlements; its separately signed account setup, lifecycle
and desktop helpers retain their existing unsandboxed account-management boundary,
with no optional entitlements. Strict signature and bundle-relative linkage checks
passed. This change does not grant macOS privacy consent or exercise app screens.

## Cleanup performed — 17 September 2026, 01:44

Archived and removed these eight inactive generated bundles from `.build`:
`Noodle Computer Tests.app`, `Noodle Files Preview.app`, `Noodle Overlay Tests.app`,
`Noodle.app`, `Noodle Applet.app`, `Noodle Computer.app`, `Noodle Local.app`,
and `Noodle Applet Local.app`. Their registered extensions and Launch Services
entries were removed where present. Recovery tar archives and the exact path/ID
manifest are in `.build/retired-app-builds/20260917-014150/`.

Removed the two obsolete Computer Local aliases after verifying that the system
service is registered under Computer Dev. Re-registered the canonical Dev app and
its preview/thumbnail extensions. PluginKit now shows one installed production
and one Dev instance for each relevant extension; duplicate production build
extensions are gone. All six current production/Dev apps remain present, and both
account daemons remained running. No computer library, account, home directory,
credential or privacy grant was removed.

The installer now preserves only legacy paths that exist: it does not recreate
retired Local aliases. All 11 installer/launcher tests pass.

**Remaining macOS cache:** `sfltool dumpbtm` still retains the two historical
parent records named Noodle Computer Local and Noodle Computer Tests. They are
not proof of remaining app copies. Targeted Launch Services/PluginKit cleanup
did not remove these background-item records. A read-only attempt to fetch just
those records through the system management interface was rejected by macOS; no
private database modification was performed.

[Apple documents `sfltool resetbtm`](https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web)
as resetting login/background-item data and recommends restarting afterward.
This is a broader reset affecting other applications, so it has not been run
without additional user approval.

### Desktop permission recovery

The bundled desktop helper now has a localized Finder label matching its build:
Noodle Local Mac Desktop / Noodle Local Mac Desktop Dev. The physical bundle path
remains `Contents/Helpers/LocalMacDesktop.app` for lifecycle compatibility.
The permission action prepares a standalone, signature-verified copy in the
owner app's sandbox `Application Support/Local Mac Permissions` folder and reveals
that copy for manual addition in System Settings. It retains the corresponding
`.desktop` bundle ID and signed code; it is not a new service or permission
identity. No permissions, background registrations, or account data are reset.

Fresh-account follow-up checks passed on 2026-09-17: 18 helper tests covered signed
permission-copy staging, temporary-home deletion safety, and real interactive
shells in fresh production/Dev fixture homes. Twenty-two app tests covered
permission-gated capture, deletion after failure, approval-state recovery, and
focused-preview transport. The visible panel test was excluded; real permission
screens, managed-account creation/deletion, and Focus capture remain user-tested.
