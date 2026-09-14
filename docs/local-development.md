# Local Steam development with Bash and rootless Podman

Steam images consume **extracted vanilla files in `src/steam`**. No Steam login,
SteamCMD bootstrap, or game download occurs during an image build or container
startup. Acquisition is a separate, explicit host operation. GOG still uses
its existing `docker/game_data` route and existing Compose files.

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

QEMU executes ARM64 container userspace on the x86 host. Box64 inside the
experimental image executes the x86_64 game. These are different layers. The
SMAPI installer runs in an explicitly amd64 build stage, using its bundled
runtime; no ARM64 SDK is installed into an x86 image. A native ARM build host
also needs amd64 emulation for this installer stage. The vanilla target's
validation stage instead follows the build host.

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

## 3. Select and build a target

| Target | Platform | Intended contents |
|---|---|---|
| `v3x86` | linux/amd64 | Existing SMAPI/mod set, inherited GUI |
| `v3arm-amd64` | linux/amd64 | Vanilla game; preserves the original selected experiment |
| `v4x86-x11vnc` | linux/amd64 | SMAPI/mods, custom Xvfb/x11vnc |
| `v3arm64` | linux/amd64 + linux/arm64 | One local manifest: SMAPI/mods, native amd64 or Box64 on arm64 |

```bash
./scripts/podman-steam.sh doctor v3x86
./scripts/podman-steam.sh build v3x86
./scripts/podman-steam.sh build all
```

These commands work from other directories too when invoked using their path.
A missing/corrupt cache fails before invoking a build, with acquisition
instructions. Dockerfiles independently validate cache contents.

`build v3arm64` uses `podman buildx build --platform linux/amd64,linux/arm64`
and `--manifest` to build both architectures from its local Dockerfile. Podman's
buildx command is its build-command compatibility alias, not Docker's buildx
builder service. The helper builds a fresh candidate manifest, verifies exactly
the two requested platforms, and only then updates the final local name.
Failed builds do not replace the previous final image/manifest. Nothing is pushed.
Build/doctor preflight requires emulation for whichever build architecture is
foreign to the host, including the amd64 installer on an ARM host.

Each project owns its `docker/` build context and Dockerfile. Named contexts
provide the published vanilla cache (`steam`) and common Bash helpers
(`devtools`). Every modded Steam target references the repository-root `mods/`
directory through the named `mods` context. Edit that shared copy for Steam
mod changes; the old per-project copies remain untouched for GOG. The vanilla
target does not consume mods.
No project builds from the repository root, duplicates the game, or depends on
Docker following an out-of-context symlink.

The Dockerfiles copy vanilla game/SDK files before applying variant-specific
mods and the common Steam launcher. Host cache contents never become a writable
game mount. Editing a launcher or a mod template does not trigger Steam
acquisition. Per-Dockerfile ignore files exclude GOG installers and unrelated
local files without changing GOG contexts.

Base images, APT packages, SMAPI releases, and emulator packages can still
require network access. This is **Steam/game-download-free building**, not a
fully offline or fully reproducible build. SMAPI remains version-selected by
`SMAPI_VERSION` (default 4.0.8); its installer runs without prompts and expected
artifacts must exist. Compatibility with a newly acquired game needs real
validation rather than inferring success from an installer exit code.

All Steam runtime stages select
`docker.io/jlesage/baseimage-gui:debian-12-v4.13.2`, an explicitly approved
change after Debian 11 security-package URLs failed during real builds. GOG is
unchanged. This also includes the post-v4.8.0 GLX work, but does not by itself
establish game compatibility.

Runtime stages declare their architecture explicitly so an amd64 installer
stage cannot select the runtime's base architecture implicitly. The dual-platform
v3arm64 stage uses the build's `TARGETPLATFORM` and checks `TARGETARCH` against
the actual package architecture. Package
installation uses jlesage's own temporary account initialization/cleanup helpers
and a CA bundle from the validated Debian stage; APT signatures and checksums
remain enabled.

`scripts/container/exec-game.sh` detects the actual container architecture with
`dpkg --print-architecture`. On amd64 it executes the apphost natively. On arm64
it requires Box64 and explicitly executes the x86_64 apphost through it. Unknown
architectures and missing Box64 fail rather than falling back silently. The
vanilla Linux apphost is `Stardew Valley` (with a space), not the game's shell
wrapper `StardewValley`.

Architecture-gated Box64 installation follows the approach used by itzg's
**Bedrock** image, rather than its Java-server image. Setup also checks that
the declared build target matches the container package architecture.
`BOX64_PACKAGE` can select the Box64 package; the source and installed version
are explicit, but package versions are not pinned.

### Compose compatibility

The existing Steam Compose files retain local `docker` build contexts with
named `additional_contexts` and explicit amd64 service platforms.
`v3arm64/docker-compose-steam.yml` selects the dual-platform project with its own build
context and save/config paths. Its Compose file is standalone, with its own
environment and port settings; it no longer extends the v3x86 service.
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

Keep GOG Compose usage unchanged. Do not use GOG files as local Steam cache
inputs.

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
user and have mode 600 or stricter.

```bash
./scripts/podman-steam.sh run v3x86 --env-file .local/runtime.local.env
./scripts/podman-steam.sh logs v3x86
./scripts/podman-steam.sh stop v3x86
```

For `v3arm64`, `run` and `smoke` default to `linux/arm64`. Use
`--platform linux/amd64` to run the native x86-64 member of the same manifest.
Stop the target before switching: both platforms share its name and isolated
development state. The build always includes both platforms; `--platform` is
not a build filter. `smoke all` retains the ARM64 default for this target; test
its amd64 member separately when that variant changes.

`run` uses an already-built local image (`--pull=never`), a project-specific
name/label, and persistent isolated state under `.local/podman/TARGET/`.
It does not use or overwrite the tracked AutoLoad file or existing version
directory saves. Modded targets receive an initial correctly typed AutoLoad
configuration and persist it separately.

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

Local helper/custom x11vnc mode deliberately rejects secure/web-auth mode
requests rather than pretending those separate proxy/auth configurations work.
The custom service requires a password file and never falls back to `-nopw`.

The common Steam launcher handles absent vanilla mods, validates generated JSON,
and starts the selected executable directly. Disabled mods move to
`DisabledMods` so they can be restored on a later start; existing nonempty
configuration remains authoritative. Game exit/signal behavior no longer
depends on an indefinite post-game sleep. GOG launchers/helpers are unchanged.
It creates the XDG config/data/cache directories under `/config` before launch.
Without an existing config directory, SMAPI fell back to a relative
`StardewValley/ErrorLogs` path which collided with the game's wrapper file.

## 5. Validation, failures, and limitations

**Completion requires automated checks only:** the four-target cache/build,
startup/graphics/authentication contract, automated lifecycle coverage, relevant
regressions, and project-owned cleanup. Interactive checks are optional human
follow-up, not completion gates. Automated completion does not certify gameplay.

Fast Bash-only regression suite (synthetic fixtures, no game downloads):

```bash
bash tests/development.sh
bash tests/architecture.sh
bash tests/readiness.sh
bash tests/fixtures/lifecycle-regressions.sh
```

It covers validation, symlinks/modes, publication/recovery, explicit acquisition
through mocked SteamCMD in a pseudoterminal, failure preservation, lock coverage,
Compose defaults, Podman arguments, ownership, private env handling, and rejection
of stale/early SMAPI logs as readiness evidence.

`bash tests/container-context.sh` additionally builds only the validation
stages with synthetic data and checks per-project context exclusions. It may
pull the validation-stage base image and install its Bash/jq packages, but
does not download or execute the game.

Bounded container startup and graphics probe:

```bash
./scripts/podman-steam.sh smoke v3x86 --env-file .local/runtime.local.env --timeout 180
./scripts/podman-steam.sh smoke all --env-file .local/runtime.local.env --timeout 600
```

All-target commands execute sequentially and fail if any target fails or is
blocked. `run all` is rejected; interactive concurrent runs need explicit
per-target port choices.

Readiness requires a game process, browser response, and a fresh SMAPI log
reporting completed mod loading for modded targets. `smoke` additionally runs
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

### Passed automated evidence: September 14, 2026

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

### Automated lifecycle coverage

Run the repeatable cached-image integration matrix with private runtime settings:

```bash
bash tests/runtime-lifecycle.sh all --env-file .local/runtime.local.env --timeout 600
```

Replace `all` with one target to narrow the run. Existing containers are refused;
the runner never adopts unrelated containers, downloads the game or rebuilds
images. It uses a project lock and immutable container IDs for scoped cleanup.
The helper's `--cid-file FILE` option supplies that ID receipt; the path must not
already exist. Podman may remove its receipt when the container is removed, so
the runner retains cleanup logs as evidence.

| Target | Config recreation/ownership | SIGTERM exit | SIGKILL exit | Dead readiness/cleanup |
|---|---|---|---|---|
| `v3x86` | Passed | 143 | 137 | Passed |
| `v3arm-amd64` | Passed | 143 | 137 | Passed |
| `v4x86-x11vnc` | Passed | 143 | 137 | Passed |
| `v3arm64` | Passed under QEMU/Box64 | 143 | 137 | Passed |

The final matrix exited 0 with four targets and zero failures. Private evidence
is recorded in `.local/validation/lifecycle-all.log` and the corresponding
`lifecycle-*/` directory. Thirteen focused lifecycle regressions cover conflicts,
failed creation/startup, owner changes, stale process identity, failed waits,
false readiness, failed cleanup and interruption. Clean/nonzero apphost exit
fixtures also passed; no menu-driven exit is required.

Lifecycle tests use disposable development runs and a unique config-volume
marker, not fabricated or modified game saves. Marker persistence is not actual
game-save correctness. The automated acceptance matrix is complete; no human
gameplay testing is required to close this local-development task.

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
