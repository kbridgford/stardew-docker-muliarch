#!/usr/bin/env bash

native_die() { printf 'Native game: %s\n' "$*" >&2; exit 1; }

native_uint() {
    local file=$1 offset=$2 width=$3 size value
    [[ -f "$file" && ! -L "$file" ]] || native_die "Expected a regular file: $file"
    size=$(stat -c %s "$file")
    (( offset >= 0 && width > 0 && width <= 4 && offset + width <= size )) ||
        native_die "Truncated binary: $file"
    value=$(LC_ALL=C od --endian=little -An -v -tu4 -j "$offset" -N "$width" "$file")
    NATIVE_VALUE=${value//[[:space:]]/}
    [[ "$NATIVE_VALUE" =~ ^[0-9]+$ ]] || native_die "Invalid binary field: $file"
}

native_elf() {
    local file=$1 expected=$2 machine
    native_uint "$file" 0 4
    [[ "$NATIVE_VALUE" == 1179403647 ]] || native_die "Not an ELF apphost/library: $file"
    native_uint "$file" 4 1
    [[ "$NATIVE_VALUE" == 2 ]] || native_die "Expected ELF64: $file"
    native_uint "$file" 5 1
    [[ "$NATIVE_VALUE" == 1 ]] || native_die "Expected little-endian ELF: $file"
    case "$expected" in amd64) machine=62 ;; arm64) machine=183 ;; *) native_die "Unsupported architecture: $expected" ;; esac
    native_uint "$file" 18 2
    [[ "$NATIVE_VALUE" == "$machine" ]] || native_die "Wrong ELF architecture for $expected: $file"
}

# Parse only the managed PE layout needed for the pinned overlay, rejecting
# mixed-mode/ReadyToRun inputs rather than pretending to translate native code.
native_pe() {
    local file=$1 pe sections optional optional_size directory clr_rva clr_size
    local table row va raw_size raw_ptr clr=-1 size metadata_rva metadata_size metadata=-1 i
    local -a addresses=() lengths=() pointers=()
    native_uint "$file" 0 2
    size=$(stat -c %s "$file")
    [[ "$NATIVE_VALUE" == 23117 ]] || native_die "Missing MZ signature: $file"
    native_uint "$file" 60 4; pe=$NATIVE_VALUE
    (( pe >= 64 )) || native_die "Invalid PE offset: $file"
    native_uint "$file" "$pe" 4
    [[ "$NATIVE_VALUE" == 17744 ]] || native_die "Missing PE signature: $file"
    PE_MACHINE_OFFSET=$((pe + 4))
    native_uint "$file" "$PE_MACHINE_OFFSET" 2; PE_MACHINE=$NATIVE_VALUE
    case "$PE_MACHINE" in 332|34404|43620) ;; *) native_die "Unsupported managed Machine: $file" ;; esac
    native_uint "$file" "$((pe + 6))" 2; sections=$NATIVE_VALUE
    (( sections > 0 && sections <= 96 )) || native_die "Invalid PE sections: $file"
    native_uint "$file" "$((pe + 20))" 2; optional_size=$NATIVE_VALUE
    optional=$((pe + 24))
    native_uint "$file" "$optional" 2
    case "$NATIVE_VALUE" in
        267) directory=$((optional + 96)) ;;
        523) directory=$((optional + 112)) ;;
        *) native_die "Unsupported PE optional header: $file" ;;
    esac
    (( directory + 120 <= optional + optional_size )) || native_die "Missing CLR directory: $file"
    native_uint "$file" "$((directory - 4))" 4
    (( NATIVE_VALUE >= 15 )) || native_die "Missing CLR directory: $file"
    native_uint "$file" "$((directory + 112))" 4; clr_rva=$NATIVE_VALUE
    native_uint "$file" "$((directory + 116))" 4; clr_size=$NATIVE_VALUE
    (( clr_rva > 0 && clr_size >= 72 )) || native_die "Not a managed assembly: $file"
    table=$((optional + optional_size))
    (( table + sections * 40 <= size )) || native_die "Truncated section table: $file"
    for ((row=table; row<table+sections*40; row+=40)); do
        native_uint "$file" "$((row + 12))" 4; va=$NATIVE_VALUE
        native_uint "$file" "$((row + 16))" 4; raw_size=$NATIVE_VALUE
        native_uint "$file" "$((row + 20))" 4; raw_ptr=$NATIVE_VALUE
        (( raw_ptr + raw_size <= size )) || native_die "Invalid section extent: $file"
        addresses+=("$va"); lengths+=("$raw_size"); pointers+=("$raw_ptr")
        if (( clr_rva >= va && clr_rva + clr_size <= va + raw_size )); then
            (( clr == -1 )) || native_die "Ambiguous CLR mapping: $file"
            clr=$((raw_ptr + clr_rva - va))
        fi
    done
    (( clr >= 0 )) || native_die "Unmapped CLR header: $file"
    native_uint "$file" "$clr" 4
    (( NATIVE_VALUE >= 72 && NATIVE_VALUE <= clr_size )) || native_die "Invalid CLR header: $file"
    native_uint "$file" "$((clr + 16))" 4; PE_FLAGS=$NATIVE_VALUE
    (( (PE_FLAGS & 1) && !(PE_FLAGS & 16) )) || native_die "Mixed/native entry point unsupported: $file"
    native_uint "$file" "$((clr + 64))" 4
    [[ "$NATIVE_VALUE" == 0 ]] || native_die "Managed-native payload unsupported: $file"
    native_uint "$file" "$((clr + 68))" 4
    [[ "$NATIVE_VALUE" == 0 ]] || native_die "Managed-native payload unsupported: $file"
    native_uint "$file" "$((clr + 8))" 4; metadata_rva=$NATIVE_VALUE
    native_uint "$file" "$((clr + 12))" 4; metadata_size=$NATIVE_VALUE
    (( metadata_size >= 16 )) || native_die "Missing managed metadata: $file"
    for ((i=0; i<sections; i++)); do
        if (( metadata_rva >= addresses[i] && metadata_rva + metadata_size <= addresses[i] + lengths[i] )); then
            (( metadata == -1 )) || native_die "Ambiguous metadata mapping: $file"
            metadata=$((pointers[i] + metadata_rva - addresses[i]))
        fi
    done
    (( metadata >= 0 )) || native_die "Unmapped managed metadata: $file"
    native_uint "$file" "$metadata" 4
    [[ "$NATIVE_VALUE" == 1112167234 ]] || native_die "Invalid managed metadata signature: $file"
}

native_normalized_hash() {
    local file=$1 offset=$2
    { head -c "$offset" "$file"; printf '\0\0'; tail -c "+$((offset + 3))" "$file"; } | sha256sum
}

native_patch() {
    local file=$1 before after offset
    native_pe "$file"
    if [[ "$PE_MACHINE" == 332 ]]; then
        printf 'Preserved I386 managed assembly (CLR flags=%s): %s\n' "$PE_FLAGS" "$file"
        return
    fi
    (( !(PE_FLAGS & 2) )) || native_die "Architecture-specific 32-bit assembly: $file"
    [[ "$PE_MACHINE" != 43620 ]] || return 0
    offset=$PE_MACHINE_OFFSET
    before=$(native_normalized_hash "$file" "$offset")
    printf '\144\252' | dd of="$file" bs=1 seek="$offset" count=2 conv=notrunc status=none
    after=$(native_normalized_hash "$file" "$offset")
    [[ "$before" == "$after" ]] || native_die "Unexpected patch changes: $file"
    native_pe "$file"
    [[ "$PE_MACHINE" == 43620 ]] || native_die "ARM64 patch verification failed: $file"
    printf 'Patched managed Machine only: %s\n' "$file"
}

native_manifest() {
    jq -Rs 'ltrimstr("\uFEFF") |
        gsub("(?<string>\"(?:[^\"\\\\]|\\\\.)*\")|/\\*(?:[^*]|\\*(?!/))*\\*/|//[^\\r\\n]*"; .string // " ") |
        fromjson' "$1"
}

native_mods() (
    set -euo pipefail
    local game=$1 extra=${2:-} directory file id name
    declare -A ids=() names=()
    shopt -s nullglob
    local -a directories=("$game/Mods"/*)
    if [[ -n "$extra" ]]; then directories+=("$extra"/*); fi
    for directory in "${directories[@]}"; do
        [[ -d "$directory" && ! -L "$directory" ]] || native_die "Invalid mod directory: $directory"
        [[ -z "$(find "$directory" -type l -print -quit)" ]] ||
            native_die "Symlinked mod payload: $directory"
        file="$directory/manifest.json"
        [[ -f "$file" && ! -L "$file" ]] || native_die "Missing mod manifest: $directory"
        id=$(native_manifest "$file" | jq -er '[to_entries[] | select((.key|ascii_downcase)=="uniqueid")] |
            if length==1 then .[0].value | select(type=="string" and length>0) | ascii_downcase
            else error("Expected one UniqueID field") end') ||
            native_die "Invalid mod identity: $file"
        name=${directory##*/}; name=${name,,}
        [[ -z "${ids[$id]:-}" && -z "${names[$name]:-}" ]] ||
            native_die "Conflicting mod ID/path: $id"
        ids[$id]=1; names["$name"]=1
    done
)
