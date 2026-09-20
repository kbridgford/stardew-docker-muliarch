# Stardew multiarch Steam container project

`multiarch` is the sole supported project: modded Steam with the inherited
jlesage GUI, built for `linux/amd64` and `linux/arm64` from one local Dockerfile.
GOG, the vanilla project, the custom x11vnc variant, and old helper target names
are intentionally retired; there are no legacy target aliases.

From the repository root:

```bash
./pullValleyBin.sh --validate  # acquire explicitly with ./pullValleyBin.sh if missing
./scripts/podman-steam.sh doctor multiarch
./scripts/podman-steam.sh build multiarch
./scripts/podman-steam.sh run multiarch --platform linux/arm64 --env-file .local/runtime.local.env --timeout 600
./scripts/podman-steam.sh logs multiarch
./scripts/podman-steam.sh stop multiarch
./scripts/podman-steam.sh smoke multiarch --platform linux/arm64 --state-root .local/validation/manual-arm64 --env-file .local/runtime.local.env --timeout 600
```

`build multiarch` invokes `podman buildx build --platform linux/amd64,linux/arm64`
with a local `--manifest`, not a single-platform tag. It verifies exactly both
platforms before replacing the project image name. Nothing is pushed to a registry.
The final runtime stage uses `TARGETPLATFORM`; game/SMAPI execution is native
on both platforms, without Box64.
The GUI base is `jlesage/baseimage-gui:debian-13-v4.14`; validation and SMAPI
installation inherit an explicitly amd64 `debian:trixie-slim` stage. The game
cache is unchanged; both platforms use SMAPI 4.5.2 and updated root mod inputs.
The v4.14 tag selects a release
line, not an immutable digest; record resolved bases for each acceptance run.
ARM preparation overlays the checksum-pinned ValleyCore `1.6.15g` bundle onto a
private game copy, validates managed headers and native ELF architecture, and
quarantines unsupported x86 native libraries outside the game search path.
It does not patch the game cache or root mod files. Native SDL2/OpenAL are
installed; no x86 Steam SDK or guessed ARM store replacement is supplied.
ValleyCore's .NET 6.0.32 is out of support. Store integration, multiplayer and
physical ARM performance remain unverified.
See the [historical Box64 investigation](../docs/box64-startup-regression-2026-09-19.md)
for the retired runtime and retained rollback images.
Build-only `--no-cache` bypasses image-layer reuse, never the local Steam cache.
It does not prune images, refresh game files, or push anything.

Runtime defaults to ARM64 to preserve the existing workflow. Select native
x86-64 explicitly, after stopping any existing instance:

```bash
./scripts/podman-steam.sh stop multiarch
./scripts/podman-steam.sh run multiarch --platform linux/amd64 --env-file .local/runtime.local.env
```

`smoke multiarch` accepts the same `--platform` option. Both runtime choices use
the same target name and normal state at `.local/podman/multiarch`, so do not
run them simultaneously. The generic `all` shortcut selects only this project,
not both runtime architectures; `run all` remains rejected.
Compose declares both build platforms; `STARDEW_PLATFORM=linux/amd64` selects
its runtime platform, with ARM64 as the default. Compose uses its configured
build engine and container name `stardew-multiarch`; the repository helper is
the rootless Podman buildx entry point.

Game acquisition is explicit; builds fail without valid `src/steam` inputs and
never download Steam/game files.

The local `docker/` build context owns the Dockerfile and ARM setup script.
Named contexts supply the shared game cache (`steam`), common Bash helpers
(`devtools`), and repository-root `mods/` (`mods`). Their paths are `src/steam`,
`scripts`, and `mods`, respectively. The replacement packages are versioned in
`mods/`; see [mod inputs](../docs/mod-updates.md) for provenance. Crops Anytime
Anywhere and TimeSpeed expose current-schema tuning through Compose environment
variables, including per-location seconds/minute, freeze controls, crop season/
location selectors and tillable tile types. Templates seed only missing/empty
configs; existing configs remain authoritative. See the runbook's tuning section
for defaults, examples and old-to-new variable names.
The Compose definition is standalone and owns its environment, ports
and save/config mounts; it does not extend another project's service. No game
copy or external symlink traversal through Docker `COPY` is required.

On an x86 host, QEMU/binfmt provides ARM64 container execution. Inside the
image, startup checks the apphost ELF architecture and directly executes the
matching native game. SMAPI installation runs in an explicit
amd64 stage using its bundled runtime. These mechanisms require separate
validation; emulated ARM userspace success is not game readiness.
The longer startup bound accommodates the observed ARM64-under-QEMU run,
which exceeded the helper's default 180 seconds.

Automated lifecycle validation defaults to both platforms sequentially:

```bash
bash tests/runtime-lifecycle.sh multiarch --platform all --env-file .local/runtime.local.env --timeout 600
```

The runner uses private disposable state beneath `.local/validation`, never
migrated user saves. The `run`/`smoke`-only `--state-root DIR` override is
restricted to safe repository-local descendants of `.local/validation`;
without it, the state root is `.local/podman`.

Migration is explicit, never a side effect of normal commands. The approved
sequence is verified backup/copy, initial isolated validation, bounded legacy
cleanup, then a `--no-cache` build and both-platform revalidation. The backed-up
migration and initial cached build/rebuild, architecture probes, disposable
smoke, and lifecycle checks have passed on both platforms. Legacy references
and the original state were retired; the backup and migrated state still verify.
Shared and unproven-unshared image objects were retained rather than pruned.
The subsequent Debian 12 `--no-cache` rebuild and both-platform startup/GLX/lifecycle
acceptance passed on September 14, 2026. Historical private results are recorded in
`.local/validation/consolidate-fresh-20260914-1/results.json`.

The Debian 13 upgrade passed the same automated boundary on September 19,
2026: a fresh two-platform build, actual architecture/package probes,
game/SMAPI/mod startup, HTTP/GLX, config-marker recreation/ownership, TERM/KILL
propagation, dead-readiness rejection, and scoped cleanup. Final evidence is
`.local/validation/debian13-20260919-2/results.json`. The prior Debian 12
manifest is retained locally as
`localhost/stardew-dev-d9e0cf953303:rollback-debian12-20260919`.
Existing state, backup, game cache, mods, and private settings were preserved.
Human interaction, multiplayer, world and real-save checks remain optional
and unverified; fresh authentication testing was not added to this upgrade.

The subsequent, now historical Box64 investigation replaced the temporary
old-package pin with a newer package plus a game-scoped CALLRET setting.
Its fresh no-cache build completed in 359 seconds, and both-platform
startup/mods/HTTP/GLX and lifecycle acceptance passed again, including three
independent ARM starts. Evidence:
`.local/validation/box64-20260919-1/results.json`.
The Debian 13/older-Box64 rollback remains locally as
`localhost/stardew-dev-d9e0cf953303:rollback-box64-a83b0ac-20260919`.
The regression is configuration-dependent; the exact upstream instruction
defect and native ARM behavior remain unproven.

See [local development](../docs/local-development.md) for prerequisites,
private authentication, isolated state, backup/rollback safeguards, limitations
and acceptance checks. No privileged fallback or implicit Steam download is used.

The subsequent native migration passed a fresh dual-platform build and the
same startup/graphics/lifecycle boundary, including all nine updated/retained
mod identities on both platforms and current-schema default Crops/TimeSpeed
configs. ARM guest apphosts and mapped runtime libraries were verified as
ARM64 under host QEMU, without Box64. Evidence:
`.local/validation/native-arm-20260919-3/results.json`.
The pre-ValleyCore rollback remains
`localhost/stardew-dev-d9e0cf953303:rollback-pre-valleycore-20260919`.
Protected data and unrelated workloads were preserved; mod updates are
intentional. This does not certify gameplay or physical ARM hardware.
