---
name: stardew-podman
description: Build, run, smoke-test, or diagnose the multiarch Steam project using a local game cache, rootless Podman, native amd64, and ARM64 with Box64.
---

# Stardew local Podman workflow

Read `docs/local-development.md` and `multiarch/docker/Dockerfile-steam` before acting.
Use Bash and the repository helpers, not Python, guessed Compose commands, or
handwritten parallel copies of runtime settings.

## One project, two platforms

| Project | Runtime platform | Behavior |
|---|---|---|
| `multiarch` | linux/amd64 | SMAPI/mods, inherited GUI, native x86-64 apphost |
| `multiarch` | linux/arm64 (default) | Same SMAPI/mods and GUI; x86-64 apphost through Box64 |

GOG, the vanilla project, custom x11vnc variant, and old helper target names
are retired, without compatibility aliases. Never substitute a native run
for a blocked requested ARM64 run.

The sole build context is `multiarch/docker/`. Named inputs are
`steam=src/steam`, `devtools=scripts`, and `mods=mods`. Edit repository-root
`mods/`; do not recreate duplicate legacy payloads, use the repository root as
the main context, or COPY through an out-of-context symlink.
The standalone Compose file is `multiarch/docker-compose-steam.yml`; the helper
reads its environment defaults without executing them as shell code.

`build multiarch` uses Podman buildx for exactly `linux/amd64,linux/arm64` in a
staged local manifest. It validates both members before updating the final name
and never pushes game-containing images. Failed builds preserve the prior
published manifest. `--no-cache` is build-only: it bypasses image-layer reuse,
not the local Steam files; it neither refreshes the game nor prunes storage.
OS, base-image, SMAPI, and emulator inputs can still require networking.

The runtime base remains `docker.io/jlesage/baseimage-gui:debian-12-v4.13.2`.
The final stage selects `TARGETPLATFORM`; Box64 installation is ARM64-only.
At launch, `scripts/container/exec-game.sh` checks actual package architecture,
uses native amd64 or explicit Box64 dispatch, and rejects unsupported platforms.
On an amd64 host, QEMU/binfmt runs ARM userspace; Box64 then runs the x86-64
game inside it. Do not confuse these layers or infer architecture solely from
host-default image inspection.

## Procedure

1. Inspect repository status. Preserve unrelated work, existing containers, and
   production saves.
2. Run `./scripts/podman-steam.sh doctor multiarch`. Use an explicit
   `--platform linux/amd64` or `--platform linux/arm64` when requested.
3. If the cache is missing or invalid, stop and tell the operator to run
   `./pullValleyBin.sh` explicitly in their terminal. For deliberate updates,
   they use `./pullValleyBin.sh --refresh`. **Never invoke either acquisition
   operation automatically.** Do not collect Steam credentials or Guard codes.
   The entire root `src/` is ignored; the cache contract lives in
   `docs/local-development.md`, not a required tracked `src/README.md`.
4. If emulation is missing, show the documented administrator installation
   instructions. Ask before any host change. Never run `sudo podman`, a
   privileged registration container, or an implicit architecture fallback.
5. Build with `./scripts/podman-steam.sh build multiarch`, adding `--no-cache`
   only for a requested fresh-layer build. The shared cache lock protects local
   inputs. `--platform` is not a build filter; both platforms always build.
6. Use the operator's existing private runtime env file, or have them prepare
   `.local/runtime.local.env` with `VNC_PASSWORD` as documented. The file must
   be owned, mode 600 or stricter, single-link, with nonsymlinked parents.
   Do not display it, source it as shell code, overwrite it, or log resolved env.
7. For an interactive run, use
   `./scripts/podman-steam.sh run multiarch --platform linux/arm64 --env-file .local/runtime.local.env --timeout 600`.
   Select `--platform linux/amd64` explicitly for native x86-64. Both choices
   share the container identity and normal state: stop the existing instance
   through the helper before switching, with operator authorization.
8. For validation, use `smoke multiarch` with explicit disposable state as
   shown below, never normal/migrated user state. It checks startup and graphics
   and removes only its own container. ARM64 under QEMU has exceeded the default
   180-second bound; use `--timeout 600`.
9. Use `./scripts/podman-steam.sh logs multiarch` and
   `./scripts/podman-steam.sh stop multiarch`. Logs can contain private
   save/player identifiers; do not publish them unredacted.

`all` is a shortcut to this sole project, not a both-runtime-platform matrix.
`build all` still builds both members, `smoke all` defaults to ARM64, and
`run all` is rejected. Do not attempt concurrent platforms by changing ports:
the helper container identity is shared.

## State, credentials, and retirement boundaries

Normal state is `.local/podman/multiarch/`, with no legacy fallback. Normal
startup holds a shared lock on `.local/podman/.multiarch-migration.lock` through
state creation/container start; migration/retirement use that same inode
exclusively. Never unlink the lock.

`--state-root DIR` is valid only for run/smoke, appends `/multiarch`, and requires
a safe private owned descendant below `.local/validation`. Symlinked parents,
dot-path forms, the validation root itself, and legacy/migrated path components
are rejected. Existing disposable state requires the helper's matching sentinel;
never fabricate one or copy user saves into test state. This isolates files,
not ports or container identity. Use fresh roots and sequential runs:

```bash
run_id="skill-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
./scripts/podman-steam.sh smoke multiarch --platform linux/amd64 --env-file .local/runtime.local.env --state-root ".local/validation/$run_id-amd64" --timeout 600
./scripts/podman-steam.sh smoke multiarch --platform linux/arm64 --env-file .local/runtime.local.env --state-root ".local/validation/$run_id-arm64" --timeout 600
```

GUI endpoints are loopback browser port 5801 and raw VNC port 5902; use an SSH
tunnel for remote access. Only `--lan` exposes gameplay UDP. A failed `run`
retains its container for diagnosis. Cleanup checks ownership and immutable IDs;
never adopt an unrelated workload. Podman removes `--cid-file` with the container:
it is not a durable receipt. Verify exact IDs and retain private cleanup logs.

Migration and retirement are **explicit, separately authorized operations**,
never side effects of an ordinary build/run request. Read the runbook first:

- `scripts/migrate-multiarch-state.sh --dry-run|--execute` copies an unchanged
  legacy source into an absent destination with an independent verified backup.
  It does not stop workloads, overwrite destination state, or delete the source.
- `--verify RECEIPT` requires the original source and verifies all three trees.
  `--verify-retained RECEIPT CLEANUP_RECEIPT` instead requires completed
  retirement evidence and an absent source, then verifies backup/destination.
  It explicitly does not claim source stability after deletion.
- `scripts/cleanup-legacy-state.sh --dry-run|--execute` requires the exact private
  validation gate, migration evidence, resource identities, and journal. Do not
  fabricate evidence, broaden its allowlist, force image deletion, or prune.

The local consolidation already migrated 138 entries and retired the original
`v3arm64` state and legacy references. Keep the backup beneath `.local/migrations`,
migrated state, other legacy state, cache, root mods, and private env files.
Shared members and ordinary untagged images with unproven reference safety were
intentionally retained. Do not repeat retirement just to build or review this skill.
The pre-cleanup gate is historical after the fresh build. Any rollback requires
separate review, an absent restoration destination, and preservation of newer
user data; there is no automatic rollback command.

## Readiness and outcomes

- Completion requires automated checks only: the single project/two-platform
  build, startup/graphics, lifecycle, relevant regressions, and scoped cleanup.
  Migration/retirement requests additionally require their explicit evidence
  gates. Human gameplay checks are optional, not blockers.
- A build layer completing, desktop appearing, or container staying alive does
  not prove game readiness.
- The helper checks the game process, HTTP response, and a fresh SMAPI log
  reporting completed mod loading. An early SMAPI banner
  does not pass. Its graphics probe is not a multiplayer acceptance test.
- Keep authentication and lifecycle evidence separate from startup readiness.
  Config-volume marker persistence does not prove real game-save correctness;
  process termination does not prove graceful in-game saving.
- Keep native ARM hardware support/performance uncertified and separate from
  actual ARM64 userspace under host QEMU, with Box64 executing the x86_64 game.
- Report incomplete or blocked platforms explicitly; never mark the matrix
  complete from one passing member.

### Passed automated evidence: September 14, 2026

The renamed cached build/rebuild and post-retirement real `--no-cache` build
passed with exactly two platforms. Fresh actual-architecture/dispatch probes,
disposable startup/mod-loading/GLX smoke, and lifecycle passed on both members.
Lifecycle preserved exact config markers and host ownership, propagated TERM
as 143 and KILL as 137, and rejected dead readiness. All eight final test IDs,
markers, and staged env files were cleaned. Retained backup/destination and
cache/input preservation checks passed before and after the final run.

Private final evidence: `.local/validation/consolidate-fresh-20260914-1/results.json`
and `summary.txt`; lifecycle evidence:
`.local/validation/lifecycle-20260914T052055Z-4193463-8775/`.
Podman reported stale index-digest metadata despite fresh members. Use the
recorded actual storage ID, exact platform/member digests, and full inspected
manifest, not host-default inspection or a JSON hash mislabeled as an OCI digest.

The consolidated regressions passed: 41 development, 28 migration, 34 cleanup,
architecture/readiness/lifecycle fixtures, real context checks, and ShellCheck.
VNC raw/WebSocket authentication evidence is historical in the runbook; the
fresh acceptance did not repeat it. Do not describe it as a fresh auth test.
Preserve `docs/stardew-container-audit-2026-09-13.md` as historical evidence,
not current runnable instructions.

### Repeating automated lifecycle checks

```bash
bash tests/runtime-lifecycle.sh multiarch --platform all --env-file .local/runtime.local.env --timeout 600
```

The runner defaults to both platforms sequentially; `--platform linux/amd64`
or `--platform linux/arm64` narrows debugging, not full acceptance. It uses
existing images and fresh private disposable state, never migrated state or
game-save fixtures. It refuses conflicting containers and retains private
evidence under `.local/validation/`. Relevant future runtime/helper changes
must rerun affected gates; the completed baseline does not certify new changes.

### Optional, unverified human follow-up

Interactive browser/native VNC controls, world creation/selection, server-mode
activation, no-player behavior, actual multiplayer join, and actual game-save
reload are optional and unverified. They are not completion gates; do not
automate a human client or invent a world fixture to finish. Do not claim
gameplay certification or mark these checks passed without evidence.

Never prune shared images, reset Podman storage, or erase cache, backups, or
saves to make a check pass.
