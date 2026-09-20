# Bundled mod inputs

The build still uses repository-root `mods/` as its named input. There is no
separate mod-pack cache or selection mechanism. Keep the folder names below:
the launcher derives the existing enable switches from them.

## September 19, 2026 candidates

| Folder | Effective package | Manifest identity | Source |
|---|---|---|---|
| Always On Server | 1.20.3-unofficial.5-mikkoperkele | `mikko.Always_On_Server` | `perkmi/Always-On-Server-for-Multiplayer`, tag `1.20.3-unofficial.5-mikko_perkele` |
| AutoLoadGame | 1.0.3, retained | `caraxian.AutoLoadGame` | Existing working payload; no verified newer matching release |
| UnlimitedPlayers | 2024.4.16, retained | `Armitxes.UnlimitedPlayers` | Existing matching upstream release |
| ChatCommands | 1.15.5 | `Lino5000.chatcommands` | `Lino5000/UpdateChatCommands`, tag `v1.15.5` |
| Crops Anytime Anywhere | 1.7.3 | `Pathoschild.CropsAnytimeAnywhere` | Nexus 3000; source tag `crops-anytime-anywhere/1.7.3` |
| TimeSpeed | 2.8.1 | `cantorsdust.TimeSpeed` | Nexus 169; source tag `timespeed/2.8.1` |
| FriendsForever | Advertised 1.2.11; embedded 1.2.3 | `IsaacS.FriendsForever` | Operator-confirmed Nexus 20702, main file 173112 |
| NoFenceDecay | No Fence Decay Redux 1.2.0 | `EnderTedi.NoFenceDecayRedux` | Nexus 20802 |
| NonDestructiveNPCs | Non Destructive NPCs Redux 2.2.1 | `ThaleTheGreat.NonDestructiveNPCsRedux` | Built from MIT source; see the folder's `SOURCE.txt` |

The replacement DLLs, assets and translations replace the old folder payloads;
old PDBs/DLLs are not left alongside them. Existing Always On Server and Friends
Forever templates remain, without schema translation. Crops and TimeSpeed now
have current-schema tuning templates seeded from Compose settings when their
config is missing or empty. Existing nonempty configs and the
three-default/six-optional enable policy are unchanged.

All nine effective mod identities loaded on both native amd64 and ARM64 under
host QEMU with SMAPI 4.5.2. See the native acceptance and optional-mod tuning
sections of the local-development runbook for the respective configuration
policies, evidence and limits: loading is not gameplay certification.

## Replacement packages in Git

At the operator's request, the supplied ChatCommands, NoFenceDecay and
FriendsForever replacements are versioned directly in `mods/`. The original
download archives remain ignored under `downloads/`; game files, credentials
and local validation artifacts remain excluded too. No extra mod download step
is required after cloning.

Versioning these files does not resolve the previously identified upstream
redistribution-permission gaps; no additional license or permission is asserted.
The build workflow does not publish game-containing images or download archives.

For future updates, replace each complete package in the folder named above.
Rename the No Fence Decay Redux package's outer folder to `NoFenceDecay`; do not
rename its entry DLL or edit the mod identity. Keep the Friends Forever template
if replacing that folder. Missing replacement manifests fail the build.

These are the locally inspected archive SHA-256 values, not publisher
signatures or permission grants:

| Package | Archive SHA-256 |
|---|---|
| Chat Commands 1.15.5 | `fc44eee786f631a2f38ff7500bdfab340530239ce47f71aa3a7c29b14766bdb0` |
| No Fence Decay Redux 1.2.0 | `5a79d9c0c1bb649a51d9e399d9684415eda8076e47d1054a6e49177be28fb2d4` |
| Friends Forever supplied ZIP | `713d08eb1f2cdaa8ef6b14d88d0b8f9f52c9680e936aa7b8398ca72dec600b83` |

The Friends Forever ZIP is intentionally unmodified. Although its filename and
download listing say 1.2.11, the embedded manifest says 1.2.3 and references
the original Nexus 1738. Its DLL differs from the original 1.2.3 download.
Do not rewrite the manifest to make the advertised version appear verified;
report the embedded identity in runtime evidence.

Permissively licensed updates retain their upstream license files. TimeSpeed
also includes its GPL license and corresponding-source location. Preserving
the existing AutoLoadGame payload does not resolve its historical provenance
or redistribution uncertainty.
