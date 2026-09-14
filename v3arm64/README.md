# Stardew amd64/ARM64 container project

This project is separate from `v3arm`, whose selected Steam build remains
vanilla **amd64**.
Despite its historical name, `v3arm64` builds both `linux/amd64` and
`linux/arm64` from its local Dockerfile.

From the repository root:

```bash
./pullValleyBin.sh
./scripts/podman-steam.sh doctor v3arm64
./scripts/podman-steam.sh build v3arm64
./scripts/podman-steam.sh run v3arm64 --env-file .local/runtime.local.env --timeout 600
```

`build v3arm64` invokes `podman buildx build --platform linux/amd64,linux/arm64`
with a local `--manifest`, not a single-platform tag. It verifies exactly both
platforms before replacing the project image name. Nothing is pushed to a registry.
The final runtime stage uses `TARGETPLATFORM`; Box64 installation is skipped on
amd64 and required on arm64.

Runtime defaults to ARM64 to preserve the existing workflow. Select native
x86-64 explicitly, after stopping any existing instance:

```bash
./scripts/podman-steam.sh stop v3arm64
./scripts/podman-steam.sh run v3arm64 --platform linux/amd64 --env-file .local/runtime.local.env
```

`smoke v3arm64` accepts the same `--platform` option. Both runtime choices use
the same target name and development state, so do not run them simultaneously.
Compose declares both build platforms; `STARDEW_PLATFORM=linux/amd64` selects
its runtime platform, with ARM64 as the default. Compose uses its configured
build engine; the repository helper is the rootless Podman buildx entry point.

Game acquisition is explicit; builds fail without valid `src/steam` inputs and
never download Steam/game files.

The local `docker/` build context owns the Dockerfile and ARM setup script.
Named contexts supply the shared game cache (`steam`), common Bash helpers
(`devtools`), and repository-root `mods/` (`mods`), shared by every modded Steam
target. The Compose definition is standalone and owns its environment, ports
and save/config mounts; it does not extend another project's service. No game
copy or external symlink traversal through Docker `COPY` is required.

On an x86 host, QEMU/binfmt provides ARM64 container execution. Inside the
image, startup detects the package architecture and uses Box64 for the x86_64
game only on ARM64; amd64 containers run natively. SMAPI installation runs in an explicit
amd64 stage using its bundled runtime. These mechanisms require separate
validation; emulated ARM userspace success is not game readiness.
The longer startup bound accommodates the observed ARM64-under-QEMU run,
which exceeded the helper's default 180 seconds.

See [local development](../docs/local-development.md) for prerequisites,
private authentication, isolated state, limitations and acceptance checks.
