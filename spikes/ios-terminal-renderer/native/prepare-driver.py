from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
replacements = {
    'ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" ./Script/apply-patches.sh "$SOURCE_DIR"':
        '# The native build driver applies the ordered patch stack once.',
    'rm -rf "$OUTPUT_DIR" "$LOCAL_CACHE_DIR" "$MODULE_CACHE_DIR" "$SOURCE_DIR/zig-out"':
        'for path in "$OUTPUT_DIR" "$LOCAL_CACHE_DIR" "$MODULE_CACHE_DIR" "$SOURCE_DIR/zig-out"; do\n'
        '        if [ -e "$path" ]; then trash "$path"; fi\n'
        '    done',
    'rm -rf "$OUTPUT_DIR"':
        'if [ -e "$OUTPUT_DIR" ]; then trash "$OUTPUT_DIR"; fi',
}
for before, after in replacements.items():
    if source.count(before) != 1:
        raise SystemExit(f"Unexpected driver anchor: {before}")
    source = source.replace(before, after)
path.write_text(source)
