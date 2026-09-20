# Local Steam development with Bash and rootless Podman

Steam images consume **extracted vanilla files in `src/steam`**. No Steam login,
SteamCMD bootstrap, or game download occurs during an image build or container
startup. Acquisition is a separate, explicit host operation. `multiarch` is
the only supported project: modded Steam with the inherited jlesage GUI.
GOG, the vanilla project, the custom x11vnc variant, and old helper target
names are intentionally retired, without compatibility aliases.

The helper does not install host packages, invoke Steam acquisition for you, or
require a Compose provider. It uses Bash, `jq`, GNU coreutils, `find`, `flock`,
`curl`, and rootless Podman. Acquisition additionally requires `tar`, `sed`,
and an x86_64 Linux host able to run SteamCMD's 32-bit executable.

## 1. Prepare the host

Use an ordinary account with subordinate UID/GID mappings, enabled user
namespaces, and rootless networking/storage support. On Debian, a host
administrator can install prerequisites:

```bash
apt-get update
apt-get install -y podman uidmap passt slirp4netns fuse-overlayfs \
    bash jq curl tar coreutils findutils util-linux libc6-i386 lib32gcc-s1
```

Do not run the downloader or Podman as root. The root-in-container initializer
is isolated by a user namespace; the helper explicitly maps application UID/GID
1000 to the invoking host user. It never uses `--privileged`.

### ARM64 on the current x86_64 host

Run these commands **as root**, separately from the development helper:

```bash
apt-get update && apt-get install -y qemu-user qemu-user-binfmt
```

Then check as the ordinary user:

```bash
cat /proc/sys/fs/binfmt_misc/qemu-aarch64
podman run --rm --platform linux/arm64 --network none \
    --read-only --cap-drop all --security-opt no-new-privileges \
    --userns keep-id --user 0:0 docker.io/library/alpine:3.20 uname -m
```

The registration must be enabled and contain flag `F`; the container should
print `aarch64`. This proves emulated userspace works, **not that Stardew works**.
The observed local host passed this probe after operator installation.

QEMU executes ARM64 container userspace on the x86 host. The ARM64 image runs
native ARM64 game/SMAPI apphosts through ValleyCore, without Box64. The
SMAPI installer runs in an explicitly amd64 build stage, using its bundled
runtime; no ARM64 SDK is installed into an x86 image. A native ARM build host
also needs amd64 emulation for this installer stage.

## 2. Acquire your game explicitly

From the repository root, in an interactive terminal:

```bash
./pullValleyBin.sh
```

Supply the account name, then respond to SteamCMD's password/Steam Guard
prompts. You need an account entitled to the game. Never export Steam passwords
or Guard codes as Docker arguments or paste them into a Copilot conversation.
The operator completed acquisition for the validation recorded below; credentials
were not collected in the implementation session.

SteamCMD and account state are kept privately under
`${XDG_DATA_HOME:-$HOME/.local/share}/stardew-dev/steamcmd`, outside the repository.
Only vanilla game files and the required SDK libraries are copied into `src`.

```text
src/
  .steam-cache.lock
  .steam-staging/              # private download staging
  .steam-backup/               # only during publication/recovery
  steam/
    manifest.json
    SHA256SUMS
    game/
    steam-sdk/
      sdk32/steamclient.so
      sdk64/steamclient.so
```

The entire root `src/` directory is ignored by Git; staging/session/runtime files are
excluded from the Steam build context. Do not publish local images containing
game files or commit the cache.

Commands:

```bash
./pullValleyBin.sh             # acquire if missing; otherwise validate/reuse
./pullValleyBin.sh --validate  # no network; check current cache
./pullValleyBin.sh --refresh   # explicit update through private staging
./pullValleyBin.sh --recover   # explicit interrupted-publication recovery
./scripts/validate-steam-cache.sh
```

The manifest records schema/app/platform/branch, available Steam build ID,
launcher identity, acquisition time, and a complete checksummed file/type/mode
inventory. Missing game content/runtime descriptors or SDK libraries fail
validation. Extra files, modifications, escaping symlinks, mods, saves, and
account state are rejected. Checksums detect changes, not publisher
authenticity or whether Steam has a newer version.

Refresh downloads into a private directory under `src/.steam-staging`, validates
it, and publishes while holding the exclusive cache lock. A failed download
leaves the old cache unchanged. For extracted directories, publication uses
recoverable renames rather than claiming a single atomic replacement.

If interrupted between renames, `--recover` restores a valid previous generation
when the main cache is absent. If both generations exist, it validates the
published generation and asks you to move the backup outside `src` before
continuing. Inspect and retain the generation you want; never repair this by
blindly deleting the cache.

Supported builds hold a shared lock while the engine consumes the context.
Raw engine/Compose invocations validate their copied payload but cannot
automatically coordinate with host refresh; do not refresh concurrently with
an unmanaged build.

## 3. Build the single project

| Project | Runtime platform | Intended contents |
|---|---|---|
| `multiarch` | linux/amd64 | SMAPI/mods, inherited GUI, native x86-64 apphost |
| `multiarch` | linux/arm64 (default) | Same SMAPI/mods and GUI, native ARM64 ValleyCore apphost |

```bash
./scripts/podman-steam.sh doctor multiarch
./scripts/podman-steam.sh build multiarch
./scripts/podman-steam.sh build multiarch --no-cache  # optional fresh image layers
```

These commands work from other directories too when invoked using their path.
A missing/corrupt cache fails before invoking a build, with acquisition
instructions. Dockerfiles independently validate cache contents.

`build multiarch` always uses `podman buildx build --platform linux/amd64,linux/arm64`
and `--manifest` to build both architectures from its local Dockerfile. Podman's
buildx command is its build-command compatibility alias, not Docker's buildx
builder service. The helper builds a fresh candidate manifest, verifies exactly
the two requested platforms, and only then updates the final local name.
Failed builds do not replace the previous final image/manifest. Nothing is pushed.
Build/doctor preflight requires emulation for whichever build architecture is
foreign to the host, including the amd64 installer on an ARM host.

Build-only `--no-cache` bypasses image-layer reuse, never `src/steam`; it does
not refresh/download the game, prune storage, or change the selected base.
The generic `all` shortcut selects the sole project, not both runtime platforms.
Removed target names fail before state creation, builds, or container operations,
instead of redirecting to `multiarch`.

`multiarch/docker/` owns the build context and `Dockerfile-steam`. Named
contexts provide the published vanilla cache (`steam=src/steam`), common Bash
helpers (`devtools=scripts`), and shared mods (`mods=mods`). Edit repository-root
`mods/` for mod changes. The replacement packages described in
[mod inputs](mod-updates.md) are versioned in those folders; original download
archives remain ignored. The build does not use the repository root as its main
context, duplicate the game, or depend on out-of-context symlink traversal.

The Dockerfile copies vanilla game/SDK files before applying
mods and the common Steam launcher. Host cache contents never become a writable
game mount. Editing a launcher or a mod template does not trigger Steam
acquisition. The Dockerfile's ignore file excludes unrelated local inputs.

Base images, APT packages, SMAPI releases, and ValleyCore can still
require network access. This is **Steam/game-download-free building**, not a
fully offline or fully reproducible build. SMAPI remains version-selected by
`SMAPI_VERSION` (default 4.5.2), aligned with the pinned ARM bundle; its installer runs without prompts and expected
artifacts must exist. Compatibility with a newly acquired game needs real
validation rather than inferring success from an installer exit code.

The runtime stage selects
`docker.io/jlesage/baseimage-gui:debian-13-v4.14`. Validation and the SMAPI
installer also use Debian 13: `validated` starts from `debian:trixie-slim`,
and `game` inherits that explicitly amd64 stage. The installer uses `libicu76`;
runtime dependencies use `libicu76`, `libasound2t64`, and `libssl3t64`.
Do not mix Bookworm libraries into this runtime or add compatibility SONAME
symlinks to bypass missing dependencies.

The GUI tag selects the v4.14 release line, not an immutable digest. Record
resolved base manifests when validating an update; `--no-cache` disables
build layers but is not itself a guarantee of refreshing mutable base tags.
The prior Debian 12/v4.13.2 results below remain historical. A newer base and
its GLX support do not, by themselves, establish game compatibility.

Runtime stages declare their architecture explicitly so an amd64 installer
stage cannot select the runtime's base architecture implicitly. The dual-platform
multiarch stage uses the build's `TARGETPLATFORM` and checks `TARGETARCH` against
the actual package architecture. Package
installation uses jlesage's own temporary account initialization/cleanup helpers
and a CA bundle from the validated Debian stage; APT signatures and checksums
remain enabled. The inspected v4.14 account definitions changed upstream,
but its package-init helper still provides `init_env` and `cleanup_env`.
The earlier Debian 13 upgrade used this same wrapper. Native game preparation
is a separate subsequent change; it does not modify the source game cache.

`scripts/container/exec-game.sh` detects the actual container architecture with
`dpkg --print-architecture` and validates the actual ELF architecture. Both
platforms directly execute their native apphosts; wrong architecture, unsupported
platforms and missing executables fail without an emulator fallback. The
vanilla Linux apphost is `Stardew Valley` (with a space), not the game's shell
wrapper `StardewValley`.

The amd64 preparation stage installs SMAPI 4.5.2, checks mod identities, and
produces separate outputs. AMD64 keeps its original runtime and Steam SDK.
ARM64 overlays ValleyCore `1.6.15g`, validates managed PE/CLR metadata, and changes
only the supported AMD64 Machine marker to ARM64. Valid AnyCPU/32-bit assemblies
remain unchanged for SMAPI's rewriter. Sources under `src/steam` and `mods/` are
never architecture-patched. Mod manifests may contain JSON comments and a BOM;
validation preserves quoted strings and rejects malformed or ambiguous IDs.

Pinned archive SHA-256:

- SMAPI 4.5.2 installer:
  `dd01ddca7b566bfe0d3b3d2d03833496abc56c53da976241f2ab443f5484acc4`.
- ValleyCore-SMAPI 1.6.15g:
  `e5949546b0574aaa7b8bf87939569c3cd4d1336857717d01aa9fb88bb3d7c467`.

Native SDL2/OpenAL packages supply ARM audio/window dependencies. Known x86
game libraries are quarantined outside the ARM game search path in
`/data/Stardew/unsupported-x86`, and x86 Steam SDK files are not copied to ARM.
There are no fake store API replacements. Startup does not certify Steam/Galaxy
integration, multiplayer, lazy native imports, audio hardware, or real saves.
ValleyCore bundles **out-of-support .NET 6.0.32**; runtime modernization is
separate work, not a silent dependency update. ARM-under-QEMU validation is not
a physical ARM hardware or performance result.

The native image has no Box64 package, repository or CALLRET override.
[Box64 findings](box64-startup-regression-2026-09-19.md) and retained images
remain historical rollback evidence. `tests/box64-regression.sh` rejects new
native-labeled images; it is not a native-runtime test. The current rollback is
`localhost/stardew-dev-d9e0cf953303:rollback-pre-valleycore-20260919`.

### Compose compatibility

`multiarch/docker-compose-steam.yml` retains its local `docker` build context
and named `additional_contexts`, with its own save/config paths. It is standalone,
with its own environment and port settings, and extends no other service.
Its container name is `stardew-multiarch`.
Its build lists both platforms; `STARDEW_PLATFORM` selects the runtime platform
(default `linux/arm64`). This Compose setting does not override the helper's
explicit `--platform` argument.
Compose support for named contexts is required;
the native Podman helper passes them directly without a Compose provider.
VNC credentials must be supplied at runtime.

The Podman helper reads the existing flat Compose environment list without
executing it as shell code. This keeps defaults and the host aliases
`ENABLE_AUTOLOADGAME`/`ENABLE_UNLIMITEDPLAYERS` consistent. Unsupported YAML or
interpolation syntax fails explicitly; it is not a general YAML parser.

### Optional mod configuration defaults

Crops Anytime Anywhere and TimeSpeed use their own defaults when enabled on a
fresh installation. The container does not generate configuration for either
mod or translate the old settings into newer schemas. Their enable switches,
`ENABLE_CROPSANYTIMEANYWHERE_MOD` and `ENABLE_TIMESPEED_MOD`, remain supported
and default to `false`. Other mods retain their existing configuration handling.

The old `CROPS_ANYTIME_ANYWHERE_*` and `TIME_SPEED_*` settings are retired.
Remove them from exported host variables and private env files; the Podman
helper rejects them explicitly rather than silently ignoring customization.
Standalone Compose no longer forwards these settings either.

Existing nonempty `config.json` files are left untouched. This is not an
automatic reset of user configuration: upstream defaults apply only when a
mod creates a new configuration. Defaults belong to the installed mod version;
the project no longer promises the old crop rules, time speed, festival policy
or host-only time controls for these two optional mods.

## 4. Run in isolated development state

Create a private env file with an editor:

```bash
mkdir -p .local
touch .local/runtime.local.env
chmod 600 .local/runtime.local.env
${EDITOR:-vi} .local/runtime.local.env
```

Use literal, unquoted `KEY=value` lines, for example:

```text
VNC_PASSWORD=<your-private-VNC-password>
ENABLE_AUTOLOADGAME=true
ALWAYS_ON_SERVER_PET_NAME=Dev pet
```

The angle-bracket value is a placeholder, not a usable default. Legacy VNC
authentication may only use the first eight password characters. Keep GUI
access on loopback or inside an SSH tunnel; do not treat VNC passwords as TLS.
Private env values override host values. Steam account variables are rejected
and secret values are not printed. Private files must belong to the invoking
user and have mode 600 or stricter; symlinked parents and hardlinked env files
are rejected.

```bash
./scripts/podman-steam.sh run multiarch --platform linux/arm64 --env-file .local/runtime.local.env --timeout 600
./scripts/podman-steam.sh logs multiarch
./scripts/podman-steam.sh stop multiarch
./scripts/podman-steam.sh run multiarch --platform linux/amd64 --env-file .local/runtime.local.env
```

For `multiarch`, `run` and `smoke` default to `linux/arm64`. Use
`--platform linux/amd64` to run the native x86-64 member of the same manifest.
Stop the target before switching: both platforms share its name and isolated
development state. The build always includes both platforms; `--platform` is
not a build filter. `smoke all` retains the ARM64 default; it is not a
both-platform runtime test. `run all` remains rejected.

`run` uses an already-built local image (`--pull=never`), a project-specific
name/label, and persistent normal state under `.local/podman/multiarch/`.
It does not use or overwrite the tracked AutoLoad file or silently migrate
legacy saves. An initial correctly typed AutoLoad configuration persists
separately. Normal startup uses a shared lock on
`.local/podman/.multiarch-migration.lock` through state creation and Podman
start, releasing it before readiness checks; migration requires the exclusive
lock on that same path so publication cannot race startup. The lock must be
an owned private regular file with a single link; state directories must be
private (mode 700). Migration must lock that same file/inode exclusively and
never unlink it. Explicit disposable-state runs do not take the migration lock.

`run` and `smoke` alone accept `--state-root DIR`. The default root is
`.local/podman` (the helper appends `multiarch`). An explicit root must be a
canonical, safe descendant of this repository's `.local/validation`, expressed
as a repository-relative or absolute path. Ancestors must be private, owned,
and nonsymlinked. Reusing an existing overridden `multiarch` state directory
requires the helper's matching `.disposable-state` sentinel; copied or migrated
state without that marker is refused. Do not fabricate the marker to bypass
this protection. The override isolates data, not container
identity or ports: runs must still be sequential. Lifecycle tests allocate
their own private disposable root there and must never use migrated user saves.
The validation root itself, dot-path forms, symlinks, and legacy/migrated state
components are rejected.

Default endpoints:

- Browser: `http://127.0.0.1:5801/`
- Native VNC: TCP port 5902 (`vncviewer 127.0.0.1::5902`)
- Gameplay: loopback UDP 24642

`--web-port`, `--vnc-port`, and `--game-port` select alternatives. Podman reports
binding conflicts without taking over another service. `--lan` exposes only
gameplay UDP; GUI ports remain loopback. A trusted remote operator can use:

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:15801:127.0.0.1:5801 \
  -L 127.0.0.1:15902:127.0.0.1:5902 operator@docker-host
```

Then use local browser port 15801 or native VNC port 15902.

The local helper deliberately rejects secure/web-auth mode
requests rather than pretending those separate proxy/auth configurations work.

The common Steam launcher validates generated JSON,
and starts the selected executable directly. Disabled mods move to
`DisabledMods` so they can be restored on a later start; existing nonempty
configuration remains authoritative. Game exit/signal behavior no longer
depends on an indefinite post-game sleep.
It creates the XDG config/data/cache directories under `/config` before launch.
Without an existing config directory, SMAPI fell back to a relative
`StardewValley/ErrorLogs` path which collided with the game's wrapper file.

## 5. Explicit migration and validation-gated retirement

Migration is implemented in Bash/jq with explicit inspection, execution, and
verification modes. Ordinary helper commands never migrate, overwrite, or
delete legacy state automatically.

```bash
./scripts/migrate-multiarch-state.sh --dry-run
./scripts/migrate-multiarch-state.sh --execute
./scripts/migrate-multiarch-state.sh --verify .local/migrations/v3arm64-RUN/receipt.json
```

Replace `v3arm64-RUN` with the actual private receipt directory printed by
migration. Execute only once, with an absent destination; do not rerun migration
to verify an existing copy. `--verify` requires the original source and compares
it, the independent backup, and the destination against the recorded inventory.
It checks historical container evidence, not whether containers are currently
running; cleanup must perform its own current resource checks.

The local migration completed on September 14, 2026: all 138 inventory entries
matched across source, backup, and destination. The retained evidence directory
is `.local/migrations/v3arm64-20260914T035009Z-186622a5a62b5dda998ab57a/`.
Its inventory and receipt are private; do not publish their contents.

Migration/retirement also require the capability-checked GNU copy/publication
options and a `jq` build that preserves integer nanosecond timestamps. Unsupported
tools fail before mutation; do not bypass these guards on an older host.

The required sequence is:

1. With old and new managed containers not running, inspect
   `.local/podman/v3arm64`. Refuse unsafe/symlinked paths, unexpected ownership,
   missing source, or an existing `.local/podman/multiarch` destination.
   Coordinate with normal startup through a scoped migration lock; do not
   stop workloads automatically or use a privileged fallback.
2. Copy the source to a unique private backup beneath `.local/migrations`,
   without following external symlinks. Verify file/type/mode/content
   inventories, then stage and verify a copy from that backup before
   fail-if-exists publication to `.local/podman/multiarch`. Preserve ownership
   and private contents without printing credentials, logs, config, or saves.
   Keep the source in place and retain the independent verified backup.
3. Pass synthetic migration tests, the renamed project's initial build, and
   both-platform smoke/lifecycle validation using disposable state. Verify
   source, backup, and destination without loading a user's saved world.
   Failure blocks cleanup; retain legacy resources and source state.
4. Only after explicit successful evidence, re-inventory this workspace's
   allowlisted legacy containers/images. Validate ownership and immutable
   container IDs before bounded removal. Handle manifests and their members
   explicitly; retain shared members and the validated `multiarch` manifest.
   Reverify the backup and unchanged source before deleting only the exact
   `.local/podman/v3arm64` source. Changed source data requires reconciliation,
   not deletion. Record private nonsecret cleanup evidence and verify removals.
5. After cleanup, rebuild with fresh image layers:

   ```bash
   ./scripts/podman-steam.sh build multiarch --no-cache
   ```

   Verify exactly amd64 and arm64 manifest members and revalidate both runtime
   architectures, native/Box64 dispatch, smoke, and lifecycle behavior in
   disposable state. Recheck the retained backup, migrated state and cache.
   A failed build must retain the prior validated manifest and data; it is
   not completed consolidation.
6. Review/update `.github/skills/stardew-podman/SKILL.md` **last**, against the
   implemented interfaces and successful final evidence.

Never broadly prune storage. Keep the verified backup, migrated state, other
legacy state directories, root `mods/`, `src/steam`, private runtime env file,
unrelated resources, and shared image members. Cleanup is not authorization
to delete any of those.

### Recorded legacy retirement

After the pre-cleanup gate passed, the explicit retirement commands were:

```bash
./scripts/cleanup-legacy-state.sh --dry-run
./scripts/cleanup-legacy-state.sh --execute
```

This is bounded migration tooling, not an ordinary build/run prerequisite.
It requires `.local/validation/consolidate-final-gate/gate.json`, verifies its
private evidence checksums and exact pre-cleanup manifest, and uses a durable
private journal for partial retries. Do not fabricate or edit gate evidence,
or replay retirement during normal development. A later no-cache build changes
the image being verified; the old gate remains historical evidence.

Retirement removed the original `.local/podman/v3arm64`, the stopped owned
legacy container, and all four allowlisted legacy image references. The old
manifest index was removed without deleting the two members shared with
`multiarch`. The three ordinary legacy images were **untagged, not deleted**:
their underlying objects were intentionally retained because complete reference
safety was unproven. No global prune or forced image deletion was performed.
Other legacy state directories, the independent backup, migrated state, cache,
shared mods, and private runtime settings were preserved.

The migration evidence directory contains `cleanup/journal.json` and
`cleanup/receipt.json`. The private post-check is
`.local/validation/consolidate-cleanup-20260914-1/postcheck.json`.
After retirement, use the separate retained-state verifier:

```bash
migration=.local/migrations/v3arm64-20260914T035009Z-186622a5a62b5dda998ab57a
./scripts/migrate-multiarch-state.sh --verify-retained \
  "$migration/receipt.json" "$migration/cleanup/receipt.json"
```

It requires completed cleanup evidence and an absent original source, then
compares the backup and destination with the original private inventory.
All 138 entries passed. It explicitly does **not** claim source stability after
deletion; ordinary `--verify` correctly refuses then. Absolute, repository-relative,
and mixed receipt paths are supported, while unsafe/noncanonical paths fail.
This check compares the migrated snapshot: intentionally playing or editing
the normal state later will require reconciliation, not deletion of new data.

For rollback, stop the new managed instance explicitly and preserve any new
state separately before considering restoration. Verify the retained source
(before cleanup) or independent backup, and restore only to an absent
destination through an explicit reviewed recovery operation. Never overwrite
new user changes or delete the backup. There is no automatic rollback command;
a recovery operation requires separate review and authorization.

## 6. Validation, failures, and limitations

**Completion requires automated checks only:** the single-project/two-platform cache/build,
startup/graphics/authentication contract, automated lifecycle coverage, relevant
regressions, verified migration, gated project-owned cleanup, and fresh-build
revalidation. Final skill review follows those checks. Interactive checks are
optional human follow-up, not completion gates. Automated completion does not
certify gameplay.

The current support matrix is the two `multiarch` platform rows in section 3.
The renamed project's cached build and repeat build passed, producing exactly
one amd64 and one arm64 member without leftover candidate aliases. Actual
package-architecture/Box64 probes, disposable startup/GLX smoke tests, and
both-platform lifecycle checks passed. The local pre-cleanup image report is
`.local/validation/consolidate-image-gate-20260914-1/summary.txt`.

The consolidated implementation also passed 41 development cases, architecture
dispatch/exit fixtures, seven readiness cases, 28 synthetic migration cases,
34 synthetic cleanup cases, lifecycle regressions (including both-platform selection, failures, and
interruption), and three real context-only synthetic-cache checks. ShellCheck
and diff whitespace checks passed. Migration was reverified after runtime tests;
root mods, the Steam cache, and the historical audit remained unchanged.

The private pre-cleanup gate at
`.local/validation/consolidate-final-gate/gate.json` binds the migration receipt,
pre-cleanup manifest, and successful evidence-log checksums. Legacy cleanup
completed with retained-state verification. The subsequent no-cache acceptance
also passed; historical results below were not used as a substitute.

### Native ARM64 and updated mods: September 19, 2026

The final fresh two-platform build and automated acceptance passed with
SMAPI 4.5.2 and the updated root `mods/` folders. ARM uses native ValleyCore
apphosts/runtime, not Box64; the validation host still uses QEMU for ARM
container userspace.

| Runtime | Default/all-enabled mods | Guest apphost/runtime mappings | HTTP/GLX | Lifecycle |
|---|---|---|---|---|
| linux/amd64 | 3 / 9 loaded by identity | Native x86-64 | Passed; llvmpipe OpenGL 4.5 | Passed |
| linux/arm64 under QEMU | 3 / 9 loaded by identity | Native ARM64, no Box64 or quarantined x86 mappings | Passed; llvmpipe OpenGL 4.5 | Passed |

Crops Anytime Anywhere and TimeSpeed created their current-schema default
configs on both platforms without old environment-template translation.
Friends Forever loaded under its supplied embedded `IsaacS.FriendsForever`
identity/version 1.2.3; the operator-confirmed archive is advertised as 1.2.11.
That metadata discrepancy is preserved, not relabeled. See
[mod inputs and provenance](mod-updates.md).

Repeated independent ARM launches, marker recreation/host ownership, TERM143,
KILL137, dead-readiness rejection and exact owned cleanup passed. The final
manifest was stable, all recorded acceptance containers were absent, and
staged credentials/lifecycle markers were removed. The Steam cache, normal and
legacy state, backup, private settings, historical audit and unrelated workloads
were unchanged. Mod changes are intentional and separately checksummed.

Final private evidence:
`.local/validation/native-arm-20260919-3/results.json`; its `lifecycle-path`
points to the final lifecycle matrix. The preceding complete successful matrix
is retained under `.local/validation/native-arm-20260919-2/`. Earlier rejected
mod evidence and baseline comparisons remain under `native-arm-20260919-1/`.
The final rebuild includes strict JSON-comment token separation; the full
matrix was repeated after that guard changed.

Preparation/native dispatch fixtures, 42 development cases, readiness/lifecycle
fixtures, legacy Box64 guards, real named-context checks, syntax and ShellCheck
passed. Imported upstream translation files retain their original line endings.
No gameplay, world creation, real-save load, multiplayer/store integration,
fresh VNC authentication or physical ARM performance is certified. Headless
audio initialization errors also occurred in the previous Box64 baseline.
The .NET 6 runtime remains out of support.

### Historical newer Box64 compatibility acceptance: September 19, 2026

The subsequent package-only investigation and fix are documented in
[Box64 startup findings](box64-startup-regression-2026-09-19.md). The adjacent
tested boundary is September 16 good / September 17 bad. Explicit CALLRET=2
reproduced the pre-SMAPI stall; modes 0 and 1 restored the early milestone.
The shipped fix uses the newer September 19 package with game-scoped
CALLRET=0, not the earlier fallback package or a Box64 source patch.
The source interval contains five commits; exact instruction-level attribution
and native ARM behavior remain unproven.

A fresh no-cache dual-platform build passed in 359 seconds. Both actual
platforms passed normal-launcher game/mod/HTTP startup, llvmpipe OpenGL 4.5,
and the existing lifecycle matrix, without extending the 600-second deadline.
ARM passed three independent full starts using the newer package and the
launcher-applied setting. Exact marker recreation/host ownership, TERM143,
KILL137 and dead-readiness rejection passed. Cache, mods, state, backup,
settings, audit, unrelated containers and the published manifest were preserved.
All nineteen recorded diagnostic/final test container IDs were confirmed absent.
Diagnostic images and unattributed early anonymous volumes were retained, not
pruned; the final diagnostic now uses temporary in-memory `/config`.

Private evidence: `.local/validation/box64-20260919-1/results.json`;
lifecycle: `.local/validation/lifecycle-20260919T190412Z-750346-20234/`.
The final index storage ID is
`89918efcc83f842fedb6cf5cfff53b57792fc4df4f2ccf8b30f643a8043c2aab`.
That investigation's rollback is Debian 13 with the older tested Box64:
`localhost/stardew-dev-d9e0cf953303:rollback-box64-a83b0ac-20260919`.
Keep this distinct from the historical Debian 12 rollback below. Existing
startup/graphics/lifecycle limits still apply; no deeper gameplay or fresh
authentication acceptance was added.

### Historical Debian 13 upgrade acceptance: September 19, 2026

All stages now use Debian 13. The final no-cache dual-platform build completed
in 361 seconds, including SMAPI installation in the amd64 Trixie stage.
The runtime base resolved to GUI v4.14, and both final members were verified
against the matching pulled base layer prefixes. No game download, SMAPI/mod
upgrade, account-init workaround change, or launcher change was needed.

The first ARM attempt timed out before SMAPI at the unchanged 600-second
startup limit. Its rolling Box64 dependency had advanced to
`0.4.5+20260919.38f4831-1`. A same-image headless comparison reached SMAPI only
with the previously validated executable; this diagnostic was not counted as
game acceptance. After explicit approval, the old package and signed snapshot
`4bc67b7174a7c1076d19ea4e9c81cc87460222a4` were pinned and both images were
rebuilt from fresh layers.
That upgrade's final image installed `0.4.5+20260913.a83b0ac-1` through verified
APT metadata; it does not copy the diagnostic binary.

| Platform | Actual runtime | Game/mod startup and HTTP | GLX | Lifecycle |
|---|---|---|---|---|
| linux/amd64 | Debian 13, native apphost, no Box64 | Passed | llvmpipe, OpenGL 4.5 | Passed |
| linux/arm64 | Debian 13, pinned Box64 under host QEMU | Passed within 600s | llvmpipe, OpenGL 4.5 | Passed |

Both fresh SMAPI logs loaded Always On Server, Auto Load Game, and Unlimited
Players. Both lifecycle cases preserved exact config-marker contents and
1000:1000 host ownership, propagated TERM as 143 and KILL as 137, rejected
dead-game readiness, and cleaned their own resources. All eight final
probe/smoke/lifecycle container IDs were confirmed absent.
The 41 development cases, architecture/exit/pinning checks, readiness and
lifecycle fixtures, three real context checks, Bash syntax, and ShellCheck
passed. Pinning tests reject missing/mutable/malformed inputs and installed
version mismatch; native setup still bypasses Box64 entirely.

The game cache, mods, existing normal/legacy state, backup, private settings,
historical receipts, and original audit match their immediate pre-upgrade
snapshots. No migration or retirement was repeated. The known-good Debian 12
manifest is retained locally as
`localhost/stardew-dev-d9e0cf953303:rollback-debian12-20260919`; it was restored
on failed acceptance and preserved unchanged after final success. Failed
builds preserve the current publication, but a successful build can publish
an image that later fails runtime checks: retain a verified rollback manifest
through acceptance rather than relying on build staging alone.

Private final evidence is
`.local/validation/debian13-20260919-2/results.json`, with full manifest,
base/package, smoke, and preservation records in the same directory or the
initial `debian13-20260919-1/` evidence directory. Lifecycle evidence is
`.local/validation/lifecycle-20260919T181031Z-421351-23846/`.
The verified final index storage ID is
`42ee6a7aa445adf6bd7fe51c0275d0a948e40a39fe4ea35dbd55017883ca7511`;
member digests are recorded in `results.json`.

On this Podman host, a direct `create --platform linux/arm64` manifest probe
selected amd64, while `run --platform linux/arm64` selected ARM64. The helper
and corrected acceptance probes use `run` and verify actual package
architecture. Podman's host-member warning is not a substitute for this
check, and a platform label alone is not a pass.

Acceptance stopped at the existing startup/graphics/lifecycle boundary.
Interactive GUI controls, fresh VNC authentication, gameplay, multiplayer,
world hosting, real-save loading, native ARM hardware, and performance were
not tested or certified. No timeout extension was used to make ARM pass.

### Historical post-cleanup acceptance: September 14, 2026

The real `build multiarch --no-cache` completed successfully in 225 seconds
using the existing local Steam files. Exactly two fresh manifest members were
published, with changed member digests and no candidate aliases. The full
manifest remained unchanged throughout runtime validation.

| Runtime platform | Actual dispatch | Startup/mods/GLX | Isolated lifecycle |
|---|---|---|---|
| linux/amd64 | Native apphost; Box64 absent | Passed | Passed |
| linux/arm64 | x86-64 apphost through Box64, ARM userspace under host QEMU | Passed | Passed |

Each lifecycle case preserved the exact marker and host ownership, propagated
TERM as 143 and KILL as 137, rejected dead readiness, and cleaned only its owned
resources. All eight probe/smoke/lifecycle container IDs were confirmed absent.
Test markers and staged env files were removed. No migrated user state or real
save was used as a test fixture.

Retained-state verification passed before the build, after publication, and
after runtime validation. The backup and destination still match all 138
recorded entries. The cache, shared mods, historical audit, private settings,
other legacy state, and historical receipt bytes remained unchanged. Legacy
references, the old container, and the original state remain absent.

Private evidence is in `.local/validation/consolidate-fresh-20260914-1/`:
`summary.txt`, `results.json`, and the before/after manifest records. Lifecycle
evidence is `.local/validation/lifecycle-20260914T052055Z-4193463-8775/`.
The verified fresh index storage ID is
`sha256:d0024126d1d08d3c56e35dd87c6a5d46894812cdcef112095a932ee0cf7d9191`;
exact platform/member digests are in `results.json`.

**Podman reporting caveat:** image-listing digest metadata stayed at the previous
index value despite a new storage ID and new members. That value is not claimed
as the current index digest. Use the inspected full manifest, exact member
digests, and storage ID together; host-default image inspection can resolve only
the amd64 member. A hash of formatted inspection JSON is evidence integrity,
not automatically the registry/OCI digest.

Fresh acceptance did not repeat VNC authentication testing; the transport/auth
results below remain clearly historical. It does not certify interactive GUI
controls, gameplay, multiplayer, world hosting, native ARM hardware, emulated
gameplay performance, or game-save correctness.

Fast Bash-only regression suite (synthetic fixtures, no game downloads):

```bash
bash tests/development.sh
bash tests/architecture.sh
bash tests/readiness.sh
bash tests/fixtures/lifecycle-regressions.sh
bash tests/migration.sh
bash tests/cleanup.sh
```

It covers validation, symlinks/modes, publication/recovery, explicit acquisition
through mocked SteamCMD in a pseudoterminal, failure preservation, lock coverage,
Compose defaults, Podman arguments, ownership, private env handling, and rejection
of stale/early SMAPI logs as readiness evidence.

`bash tests/container-context.sh` additionally builds only the validation
stages with synthetic data and checks the surviving project's context exclusions. It may
pull the validation-stage base image and install its Bash/jq packages, but
does not download or execute the game.

Bounded container startup and graphics probe:

```bash
./scripts/podman-steam.sh smoke multiarch --platform linux/amd64 --state-root .local/validation/manual-amd64 --env-file .local/runtime.local.env --timeout 180
./scripts/podman-steam.sh smoke multiarch --platform linux/arm64 --state-root .local/validation/manual-arm64 --env-file .local/runtime.local.env --timeout 600
```

Use fresh private validation roots for repeat runs; never point tests at normal
or migrated user state. These explicit platform runs are sequential and fail
if startup is blocked. `all` in the helper is only a project shortcut.

Readiness requires a game process, browser response, and a fresh SMAPI log
reporting completed mod loading. `smoke` additionally runs
`glxinfo -B`, then removes its own container. The default startup bound is 180
seconds; use `--timeout 600` for ARM64 under QEMU, whose observed startup exceeded
that default. Readiness does not prove authenticated interactive access, world
loading, full mod compatibility, multiplayer joining, or persistence.
Authentication and lifecycle checks are separate automated evidence; optional
human follow-up is listed below.

Failures retain private diagnostics in the target's attempt directory. A failed
`run` keeps its container for diagnosis; `smoke` cleans up only what it created.
The helper refuses to stop containers without the matching project label.
Logs can contain player/save identifiers; do not publish them unredacted.

### Automated lifecycle coverage

Run the repeatable cached-image integration matrix with private runtime settings:

```bash
bash tests/runtime-lifecycle.sh all --platform all --env-file .local/runtime.local.env --timeout 600
```

The project argument accepts `all` or `multiarch`. The platform argument accepts
`all`, `linux/amd64`, or `linux/arm64`, and defaults to `all`: unlike helper
`smoke all`, the lifecycle default exercises both platforms sequentially.
Select one platform to narrow debugging, not to claim both-platform acceptance.

Existing containers are refused; the runner never adopts unrelated containers,
downloads the game, or rebuilds images. It allocates a unique private disposable
state root under its `.local/validation` evidence directory and passes that
root to the helper. It must never copy, fabricate, load, or modify user saves
as test fixtures. A unique config marker tests volume persistence, not actual
game-save correctness.

The runner uses a project lock and immutable container IDs for scoped cleanup.
The helper's `--cid-file FILE` option supplies that ID receipt; the file must not
already exist and its parent must be an existing private descendant directory
under `.local/validation`. Podman removes this file when the container is removed;
it is not a durable receipt. The runner retains cleanup logs as evidence and
verifies exact container IDs, rather than treating a missing CID file as proof
of cleanup. Only test-owned markers/resources are cleaned. The consolidated
cached-image matrix passed both architectures: exact marker recreation and
host ownership, TERM exit 143, KILL exit 137, dead-readiness rejection, and
scoped cleanup. Its private evidence is
`.local/validation/lifecycle-20260914T035848Z-1247622-181/`.

### Historical automated evidence: September 14, 2026, before consolidation

**Historical only:** the following records the previous project layout and
target names, not runnable instructions or the current support matrix. Preserve
the [historical audit](stardew-container-audit-2026-09-13.md) as written.

The operator-acquired cache identifies Steam build `16826371`; the game reports
Stardew Valley `1.6.15` build `24356`. Modded images use SMAPI `4.0.8`. All four
images built from the same cache without invoking Steam acquisition. Subsequent
launcher rebuilds reused the cached game layers, and cache validation remained
unchanged.

The final clean all-four smoke sweep **passed startup, GLX, and cleanup**;
the local log is `.local/validation/smoke-all.log`. It is complete, not still
running. A project-label query confirmed no managed test containers remained.
These were actual game startup runs, not only synthetic fixtures.

| Target | Image architecture | Startup observation | GLX and VNC transport |
|---|---|---|---|
| `v3x86` | amd64 | Game initialized; 3 mods loaded | Passed |
| `v3arm-amd64` | amd64 | Native game apphost running; SMAPI absent | Passed |
| `v4x86-x11vnc` | amd64 | Game initialized; 3 mods loaded | Passed |
| `v3arm64 --platform linux/amd64` | amd64 | Native apphost; 3 mods loaded; Box64 absent | Passed |
| `v3arm64 --platform linux/arm64` | arm64 | Explicit Box64 dispatch; game initialized; 3 mods loaded | Passed under host QEMU |

The three loaded mods are Always On Server, Auto Load Game, and Unlimited
Players. SMAPI flags Always On Server as bypassing its normal safety checks;
loading successfully is not a guarantee of correct hosting behavior.

All desktops provide Mesa llvmpipe OpenGL 4.5. Correct VNC credentials were
accepted and wrong/absent credentials rejected on every target, both through
raw TCP and through the actual browser WebSocket route. WebSocket validation
used a loopback protocol bridge and VNC client, not interactive browser UI
automation. Browser input/rendering remains optional, unverified human
follow-up, not a completion gate.

Application UID/GID 1000 maps to the invoking host user and can write isolated
configuration. On all four targets, a disposable `/config` marker survived
recreation with exact contents and host ownership preserved. Sending SIGTERM
to each exact game PID stopped its container with exit 143; controlled SIGKILL
produced exit 137. Dead-game readiness was rejected, rather than accepting a
false-live desktop. Test containers, markers and staged credentials were cleaned up.
This verifies volume persistence and exit propagation, not real game-save
integrity or graceful in-game saving.

Known runtime diagnostics include unavailable audio hardware and Steam
achievements without a running Steam client. Initialization continued after
these errors. Box64 also reports optional-library/symbol warnings; the observed
ARM run continued through game initialization and mod loading. None of this
establishes native ARM hardware compatibility or acceptable emulated gameplay
performance.

The 31 cache/downloader/orchestration cases in `tests/development.sh`,
architecture dispatch/exit fixtures in `tests/architecture.sh`, seven readiness
cases in `tests/readiness.sh`, and real validation-stage/context-exclusion checks
in `tests/container-context.sh` passed. ShellCheck passed with external
container-source resolution (`SC1091`) excluded.
Buildx regressions include staged manifest publication, invalid/failed builds,
both-host emulation preflight, explicit runtime selection and missing manifests.
The real dual-platform build and a repeat cached build passed with exactly
one amd64 and one arm64 manifest member, without accumulating candidate tags.
Both members passed explicit-platform startup and GLX smoke checks. Their
actual package architectures and native/Box64 installation choices were checked
inside the running userspace, not inferred from a manifest's host-default
`podman image inspect` result.

#### Historical lifecycle results

| Target | Config recreation/ownership | SIGTERM exit | SIGKILL exit | Dead readiness/cleanup |
|---|---|---|---|---|
| `v3x86` | Passed | 143 | 137 | Passed |
| `v3arm-amd64` | Passed | 143 | 137 | Passed |
| `v4x86-x11vnc` | Passed | 143 | 137 | Passed |
| `v3arm64` | Passed under QEMU/Box64 | 143 | 137 | Passed |

The pre-consolidation matrix exited 0 with four targets and zero failures. Private evidence
is recorded in `.local/validation/lifecycle-all.log` and the corresponding
`lifecycle-*/` directory. Thirteen focused lifecycle regressions cover conflicts,
failed creation/startup, owner changes, stale process identity, failed waits,
false readiness, failed cleanup and interruption. Clean/nonzero apphost exit
fixtures also passed; no menu-driven exit is required.

Those lifecycle tests used development runs and a unique config-volume marker,
not fabricated or modified game saves. Marker persistence was not actual
game-save correctness. That earlier acceptance matrix was complete, but is not
evidence for the renamed project's new migration or disposable-state guarantees.

### Optional, unverified human follow-up

- Check interactive browser and native VNC rendering/input controls.
- Create or select a playable world and inspect in-world mod behavior.
- Exercise server-mode activation, no-player behavior, and relevant prompts.
- Join with an actual multiplayer client.
- Save a recognizable world change and verify actual game-save reload after
  recreation using the same isolated development state.

None of these checks blocks automated completion, and none is claimed passed.
There is no need to automate a human client or create a world fixture to finish
this task. This is not gameplay certification; native ARM support and gameplay
performance remain uncertified.

## References

- [Podman buildx alias, platforms and local manifests](https://docs.podman.io/en/v5.4.2/markdown/podman-build.1.html)
- [Podman user namespace and run options](https://docs.podman.io/en/v5.4.2/markdown/podman-run.1.html)
- [Podman Compose delegates to external providers](https://docs.podman.io/en/v5.4.2/markdown/podman-compose.1.html)
- [GitHub agent skills](https://docs.github.com/en/copilot/concepts/agents/about-agent-skills)
- [SMAPI 4.0.8 installer source](https://github.com/Pathoschild/SMAPI/blob/4.0.8/src/SMAPI.Installer/InteractiveInstaller.cs)
- [jlesage GLX release](https://github.com/jlesage/docker-baseimage-gui/releases/tag/v4.8.0)
- [itzg Bedrock architecture-gated Box64 setup](https://github.com/itzg/docker-minecraft-bedrock-server/blob/e2b5c995b7038062e2423496bbfee9a4f98fd64f/build/setup-arm64)
- [itzg Bedrock runtime dispatch](https://github.com/itzg/docker-minecraft-bedrock-server/blob/e2b5c995b7038062e2423496bbfee9a4f98fd64f/bedrock-entry.sh#L511-L516)
- [Historical project audit](stardew-container-audit-2026-09-13.md)
