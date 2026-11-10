#!/usr/bin/env bash
# Host tests for the vintage patch, plus a Cortex-M4 compile check.
#
#   tests/host/run.sh                 host tests (gcc, address/UB sanitizers)
#   GIPFEL=path/to/gipfel_mpe tests/host/run.sh
#                                     also compile for the Summit with the
#                                     project's flags and headers, print sizes
#                                     and the firmware symbols the patch uses
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/../../patches/vintage"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

gcc -O2 -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I"$here" "$src/vintage_model.c" "$src/vintage_hooks.c" "$src/vintage_inner_stock.c" \
    "$here/test_vintage.c" -lm -o "$out/test_vintage"
"$out/test_vintage"

if [[ -n "${GIPFEL:-}" ]]; then
    echo
    echo "Cortex-M4 build (gipfel_mpe's CFLAGS, $GIPFEL/patches/common):"
    flags=(-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 -Os -std=c11 -ffreestanding
           -nostdlib -fno-common -fno-tree-loop-distribute-patterns -ffunction-sections
           -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -g)
    for f in vintage_model vintage_hooks vintage_inner_stock vintage_inner_mpe; do
        arm-none-eabi-gcc "${flags[@]}" -I"$GIPFEL/patches/common" -c "$src/$f.c" -o "$out/$f.o"
    done
    arm-none-eabi-size -t "$out"/vintage_model.o "$out"/vintage_hooks.o "$out"/vintage_inner_stock.o
    echo "undefined symbols (must be firmware or MPE symbols only):"
    arm-none-eabi-nm -u "$out"/*.o | awk 'NF==2 {print "  " $2}' | sort -u
    if arm-none-eabi-nm -u "$out"/*.o | grep -qi "fpga\|__aeabi_f\|__aeabi_d\|memcpy\|memset"; then
        echo "FAIL: FPGA call, float helper or libc call found" >&2
        exit 1
    fi
    for f in "$out"/*.o; do
        # size -A: "section size addr" in decimal; any non-empty .data is refused by the patch linker.
        if arm-none-eabi-size -A "$f" | awk '$1 ~ /^\.data/ && $2 > 0 {found=1} END {exit !found}'; then
            echo "FAIL: initialised data (.data) in $(basename "$f"): the patch builder refuses it" >&2
            exit 1
        fi
    done
    echo "ok    no FPGA calls, no float helpers, no libc, no .data"
fi
