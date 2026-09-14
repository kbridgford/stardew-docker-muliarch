---
name: stardew-podman
description: Build, run, smoke-test, or diagnose this repository's Steam containers using a shared local game cache and rootless Podman, including the ARM64 experiment.
---

# Stardew local Podman workflow

Read `docs/local-development.md` and the selected Steam Dockerfile before acting.
Use Bash and the repository helpers, not Python, guessed Compose commands, or
handwritten parallel copies of runtime settings.

## Targets

| Target | Architecture | Behavior |
|---|---|---|
| `v3x86` | amd64 | Existing SMAPI/mod integration and inherited GUI |
| `v3arm-amd64` | amd64 | Vanilla experiment; do not enable SMAPI |
| `v4x86-x11vnc` | amd64 | SMAPI with custom Xvfb/x11vnc |
| `v3arm64` | amd64 + arm64 | Local manifest: native amd64; ARM64 uses Box64 and remains the runtime default |

Directory names are not architecture guarantees. Never substitute the amd64
target for a blocked ARM64 target.
Each project builds from its own `docker/` folder. The helper passes named
contexts for shared game files, scripts and root `mods/` (modded targets only).
Edit root `mods/` for Steam mod changes; legacy project copies remain for GOG.
ARM64 has a standalone Compose definition and its own local Dockerfile.
`build v3arm64` uses Podman buildx to build both platforms and validate the local
manifest before updating its final name; it never pushes game-containing images.
Its final stage selects `TARGETPLATFORM`; Box64 installation is architecture-gated.
Do not revert to a root build context or
try to COPY through an out-of-context symlink.
All Steam runtime stages use
`docker.io/jlesage/baseimage-gui:debian-12-v4.13.2`; GOG is unchanged. At launch,
`exec-game.sh` detects the container architecture: amd64 executes natively,
arm64 requires Box64, and unsupported architectures fail explicitly.

## Procedure

1. Inspect repository status. Preserve unrelated work, existing containers, and
   production saves.
2. Run `./scripts/podman-steam.sh doctor TARGET`.
3. If the cache is missing or invalid, stop and tell the operator to run
   `./pullValleyBin.sh` explicitly in their terminal. For deliberate updates,
   they use `./pullValleyBin.sh --refresh`. **Never invoke either acquisition
   operation automatically.** Do not collect Steam credentials or Guard codes.
   The entire root `src/` is ignored; the cache contract lives in
   `docs/local-development.md`, not a required tracked `src/README.md`.
4. If emulation is missing, show the documented administrator installation
   instructions. Ask before any host change. Never run `sudo podman`, a
   privileged registration container, or an implicit architecture fallback.
5. Build with `./scripts/podman-steam.sh build TARGET`. This holds a shared cache
   lock and validates local inputs. Builds never acquire Steam or game files.
6. Have the operator prepare a mode-600 runtime env file with `VNC_PASSWORD`.
   Do not display its contents, source it as shell code, or log resolved env.
7. Run `./scripts/podman-steam.sh run TARGET --env-file /absolute/private/file`.
   Alternatively, use `smoke TARGET` with the same option for bounded startup,
   a graphics probe, and cleanup of the test container. Use `--timeout 600` for
   ARM64 under QEMU; the observed startup exceeded the default 180-second bound.
   For `v3arm64`, `--platform linux/amd64` explicitly selects its native x86-64
   manifest member; default remains ARM64. Stop before switching platforms;
   they share the target's container name and state. Do not treat a passing
   native run as an ARM pass. `smoke all` covers its ARM member, not both.
8. Use the helper's `logs TARGET` and `stop TARGET` operations. Avoid displaying
   unredacted logs publicly; they can contain save/player identifiers.

`build all` and `smoke all` execute sequentially and fail if any target fails or
is blocked. `run all` is intentionally rejected; use explicit ports for
concurrent interactive targets.

## Readiness and outcomes

- Completion requires automated checks only: four-target cache/build,
  startup/graphics/authentication, lifecycle, relevant regressions, and owned
  cleanup. Human gameplay checks are optional, not blockers.
- A build layer completing, desktop appearing, or container staying alive does
  not prove game readiness.
- The helper checks the game process, HTTP response, and a fresh SMAPI log
  reporting completed mod loading for modded targets. An early SMAPI banner
  does not pass. Its graphics probe is not a multiplayer acceptance test.
- Keep authentication and lifecycle evidence separate from startup readiness.
  Config-volume marker persistence does not prove real game-save correctness;
  process termination does not prove graceful in-game saving.
- Keep native ARM hardware support/performance uncertified and separate from
  actual ARM64 userspace under host QEMU, with Box64 executing the x86_64 game.
- Report incomplete and blocked targets explicitly.

### Passed automated evidence

The final all-four clean smoke sweep passed startup, GLX, and cleanup; its local
log is `.local/validation/smoke-all.log`. No managed test containers remained
after that sweep. All four images built from the shared cache, and actual game
startup passed (ARM64 under QEMU/Box64); the vanilla target ran without SMAPI.
Correct/wrong/absent credentials passed over both raw VNC and the browser
WebSocket transport on every target. The protocol bridge and VNC client tested
transport authentication, not interactive browser UI automation.
Application UID mapping and writable host-owned config passed on all targets.
The subsequent v3arm64 buildx build and repeat build produced exactly amd64
and arm64 members. Both passed explicit-platform startup/GLX; amd64 has no
Box64, while arm64 runs through it. Use manifest-platform checks for that target,
not the host-default architecture returned by inspecting a manifest as an image.
All four targets passed exact config-marker recreation with host ownership,
exact-game-PID SIGTERM (container exit 143), controlled SIGKILL (exit 137),
dead-game readiness rejection and owned cleanup. Cache/orchestration, architecture/exit,
readiness, and context-exclusion regressions also passed.

### Repeating automated lifecycle checks

Use `bash tests/runtime-lifecycle.sh all --env-file /absolute/private/file --timeout 600`
for the full matrix, or replace `all` with one target. This tested runner uses
existing images and development-only markers, not game-save fixtures; it refuses
conflicting containers and retains private evidence under `.local/validation/`.
The final four-target matrix passed with no containers, markers or staged
credentials left behind. Relevant future runtime/helper changes must rerun the
affected gates; the completed baseline does not certify untested changes.

### Optional, unverified human follow-up

Interactive browser/native VNC controls, world creation/selection, server-mode
activation, no-player behavior, actual multiplayer join, and actual game-save
reload are optional and unverified. They are not completion gates; do not
automate a human client or invent a world fixture to finish. Do not claim
gameplay certification or mark these checks passed without evidence.

State is isolated beneath `.local/podman/TARGET/`; GUI ports bind to loopback.
Only `--lan` exposes gameplay UDP. A failed `run` retains its container for
diagnosis; `smoke` removes only the container it created. Stop uses a project
ownership label. Never prune shared images, reset Podman storage, or erase
the cache/saves to make a check pass.
