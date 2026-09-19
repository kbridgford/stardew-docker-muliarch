# Box64 pre-SMAPI startup regression: September 19, 2026

Local findings and reproduction notes; no upstream issue or patch has been
published. The fix uses an authenticated newer package and project configuration,
not a Box64 source build. The original container audit remains historical.

## Finding and shipped configuration

The newer packaged Box64 stalls before managed SMAPI startup with its default
CALLRET mode on our amd64 host running ARM64 userspace under QEMU. On one fixed
Debian 13 ARM image, changing only the package and then one configuration value
established a repeatable package boundary and CALLRET-mode dependency.

The image now installs `0.4.5+20260919.38f4831-1` from signed repository snapshot
`d444abc7fb30603e3129c338cd880dab1a2723f9`. Existing TLS/APT verification and
installed-version assertions are unchanged. `scripts/container/exec-game.sh`
forces `BOX64_DYNAREC_CALLRET=0` only on ARM64 for apphost basenames
`StardewModdingAPI` and `Stardew Valley`, including when an inherited setting
requests mode 2. Native amd64, unrelated executables, arguments, and exec-based
signal/exit propagation are unchanged.

Mode 0 disables CALL/RET optimization, not dynarec. Mode 1 also restored the
early managed milestone, but mode 0 is the conservative application-scoped
compatibility choice; no performance comparison or deeper gameplay certification
is claimed. There is no global interpreter fallback or timeout extension.

## Controlled package/configuration evidence

All candidates were installed through signed immutable APT snapshots into
derivatives of ARM base image
`b65c50d0062da50ef3327af0971975fcb43a65a8623096a3d2aa5581a01f5a74`.
All other installed package versions were identical. The application remained
Stardew Valley 1.6.15 build 24356 with SMAPI 4.0.8 and the same root mods.
Each trial used fresh container-only state, no network or host state mounts,
and direct Box64 dispatch rather than the compatibility launcher.

| Package suffix (all `0.4.5+...-1`) | CALLRET | Managed banner within 120s |
|---|---|---|
| `20260913.a83b0ac` | Default | Yes |
| `20260916.3ad88dc` | Default | Yes |
| `20260917.92527de` | Default | No |
| `20260918.e74c643` | Default | No |
| `20260919.38f4831` | Default | No |
| `20260919.38f4831` | Explicit 0 | Yes, repeated |
| `20260919.38f4831` | Explicit 1 | Yes |
| `20260919.38f4831` | Explicit 2 | No (negative control) |
| `20260917.92527de` | Explicit 0 | Yes |

Successful diagnostics took 25-26 seconds including cleanup; failed diagnostics
returned 124 after the bounded wait and cleanup. The stalled main thread used
approximately 99% CPU. These results distinguish the observed busy stall from
simply waiting for the desktop, but a banner alone is not game readiness.

## Mechanism and attribution limits

The adjacent good/bad package interval `3ad88dc2e...92527ded3` contains five
upstream commits, not a single proven culprit. Read-only source inspection
identified a consistent mechanism in `92527ded3`, associated with
ptitSeb/box64#4405: ARM dynablock entry/exit in-use tracking becomes active for
CALLRET modes >= 2, replacing the previous purge-gated tracking. Modes 0 and 1
avoid that path, consistent with our controls.

This establishes a configuration-dependent regression and a strong source-level
lead, **not an instruction-level diagnosis or a source repair**. No intervening
source revisions were compiled or patched. Native ARM hardware was unavailable;
a QEMU/Box64 interaction remains possible. Do not generalize this to native ARM
support or confuse it with ptitSeb/box64#4022, a different loading/saving report.

Primary upstream references (immutable revisions):

- `ptitSeb/box64`, compare `3ad88dc2e...92527ded3`.
- `ptitSeb/box64`, commit `92527ded3`, especially
  `src/dynarec/dynarec_native_pass.c` and ARM64 block entry/exit helpers.
- `ptitSeb/box64` at `38f4831b2`, `docs/USAGE.md`,
  `BOX64_DYNAREC_CALLRET`, and `system/box64.box64rc`.
- `ryanfortner/box64-debs`, signed snapshots in the table below.

| Revision | Immutable package repository snapshot |
|---|---|
| `a83b0ac` | `4bc67b7174a7c1076d19ea4e9c81cc87460222a4` |
| `3ad88dc` | `08332205f7d0f4927c5caa7b0aa08b2a45f5a7c9` |
| `92527de` | `4d58064e1f1ac27ca05a12be9584cc8187342f6e` |
| `e74c643` | `04ac6d5246d2fe4db305eb69e0dec21aa65d6c37` |
| `38f4831` | `d444abc7fb30603e3129c338cd880dab1a2723f9` |

## Final image acceptance

The final no-cache dual-platform build completed in 359 seconds. Both members
retain the resolved Debian 13 GUI base layers; the ARM package probe confirmed
the newer exact version, while native amd64 still has no Box64 installed.
The final ARM member also passed the direct headless diagnostic with mode 0.

| Platform | Normal launcher startup/mods/HTTP | Graphics | Lifecycle |
|---|---|---|---|
| linux/amd64 | Passed, native execution | llvmpipe OpenGL 4.5 | Passed |
| linux/arm64 | Passed, newer Box64 and scoped CALLRET=0 under QEMU | llvmpipe OpenGL 4.5 | Passed |

Normal helper runs used no diagnostic override. Three independent ARM launches
(smoke, TERM case, KILL case) reached the unchanged readiness boundary within
600 seconds each. Both platforms loaded Always On Server, Auto Load Game and
Unlimited Players. Lifecycle checks verified exact config-marker recreation
and host ownership, TERM143, KILL137, and rejection of dead-game readiness.
There was no world creation, multiplayer join, real-save loading, new
authentication testing, or native ARM hardware certification.

The final manifest stayed unchanged through runtime checks. All eight final
runtime container IDs and eleven headless diagnostic container IDs were
confirmed absent. Markers and staged credentials were removed; unrelated
containers, normal/legacy state, backup, Steam files, mods, private settings,
and the original audit matched the immediate baseline. No state migration or
retirement was repeated.

Diagnostic images and unattributed anonymous volumes from early probe
iterations were retained rather than broadly pruned. The final harness uses
tmpfs for the inherited `/config` volume, avoiding new anonymous-volume residue.
Detailed identities and preservation checks are in the private `results.json`.

The focused diagnostic fixtures, architecture/pinning/dispatch checks,
development cases, readiness/lifecycle fixtures, Bash syntax and ShellCheck
passed. This is a tested configuration compatibility fix, not a claim that
the upstream emulator defect has been repaired.

## Offline local reproducer

Use the operator's own previously acquired cache and built image; never
redistribute game binaries, user saves, credentials, or unredacted private logs.
A minimal redistributable non-game reproducer has not been established.

Set `ARM_IMAGE_ID` to the full immutable local ARM64 member ID recorded in the
build output, not the multiarch tag, index digest, or host-selected amd64 member.
The harness verifies the exact image metadata and actual runtime architecture.

```bash
bash tests/box64-regression.sh --image "$ARM_IMAGE_ID" --timeout 120 --env BOX64_DYNAREC_CALLRET=2
bash tests/box64-regression.sh --image "$ARM_IMAGE_ID" --timeout 120 --env BOX64_DYNAREC_CALLRET=0
bash tests/box64-regression-fixtures.sh
```

On the tested September 19 image, the first command intentionally exits 124;
the second exits 0 after observing the SMAPI banner. Execute them separately
rather than chaining with `&&`. The harness calls Box64 directly, **bypassing
the normal launcher's forced compatibility setting**. Exit 0 means only the
early managed banner was observed; 124 means the diagnostic deadline, and
other nonzero statuses mean a diagnostic or cleanup failure.

The harness never builds, pulls images, or downloads games. It uses rootless
Podman, `--network none`, a temporary in-memory `/config`, container-only
HOME/XDG state, bounded logs, private evidence, ownership labels and exact-ID
cleanup. Numeric `BOX64_*` settings are diagnostic-only inputs, not production
helper options. Eleven fixtures cover success, timeout, early exit, failed
creation/CID recovery, interruption, owner mismatch, cleanup failure, wrong
architecture, invalid image, invalid setting and invalid timeout.

Private research and acceptance evidence is retained under
`.local/validation/box64-20260919-1/`; individual probes retain their own
`result.json`, settings, image identity, logs and cleanup receipts.
The primary rollback alias is the Debian 13/older-Box64 manifest
`localhost/stardew-dev-d9e0cf953303:rollback-box64-a83b0ac-20260919`.
The earlier Debian 12 rollback remains separate. Preserve both; never prune
shared image members or replay state migration to change the emulator.
