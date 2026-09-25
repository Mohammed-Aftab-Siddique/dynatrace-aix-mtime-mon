#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

failures=0

assert_contains()
{
    local file=$1
    local expected=$2
    local description=$3

    if grep -Fqx "$expected" "$file"; then
        printf 'ok - %s\n' "$description"
    else
        printf 'not ok - %s\n' "$description"
        printf '  expected: %s\n' "$expected"
        failures=$((failures + 1))
    fi
}

mkdir -p "$TEST_DIR/input" "$TEST_DIR/empty" "$TEST_DIR/input/nested"
printf 'data\n' > "$TEST_DIR/input/orders.dat"
printf 'data\n' > "$TEST_DIR/input/file with spaces.dat"
printf 'data\n' > "$TEST_DIR/input/.hidden"
printf 'data\n' > "$TEST_DIR/input/nested/ignored.dat"
printf 'data\n' > "$TEST_DIR/input/back\\slash.dat"
printf 'data\n' > "$TEST_DIR/input/quote\"file.dat"

touch -d '@1704067200' \
    "$TEST_DIR/input/orders.dat" \
    "$TEST_DIR/input/file with spaces.dat" \
    "$TEST_DIR/input/.hidden" \
    "$TEST_DIR/input/back\\slash.dat" \
    "$TEST_DIR/input/quote\"file.dat"

printf '%s\n%s\n' "$TEST_DIR/input" "$TEST_DIR/empty" > "$TEST_DIR/directories.conf"

/usr/bin/perl "$ROOT_DIR/aix_mtime_collector.pl" \
    --host 'aix"01' \
    --directories "$TEST_DIR/directories.conf" \
    --output "$TEST_DIR/payload.txt" \
    --now 1704070800 > "$TEST_DIR/summary.txt"
collector_rc=$?

if [ "$collector_rc" -eq 0 ]; then
    printf 'ok - collector exits successfully\n'
else
    printf 'not ok - collector exits successfully (rc=%s)\n' "$collector_rc"
    failures=$((failures + 1))
fi

assert_contains "$TEST_DIR/payload.txt" \
    "custom.file.age.seconds,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\",filename=\"orders.dat\" 3600" \
    'age is calculated from epoch mtime'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.file.mtime.display,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\",filename=\"orders.dat\",mtime=\"2024-01-01T05:30:00+05:30\" 1" \
    'mtime is rendered in IST'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.file.age.seconds,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\",filename=\"back\\\\slash.dat\" 3600" \
    'backslashes are escaped'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.file.age.seconds,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\",filename=\"quote\\\"file.dat\" 3600" \
    'quotes are escaped'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.file.age.seconds,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\",filename=\".hidden\" 3600" \
    'hidden files are included'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.directory.file.count,host=\"aix\\\"01\",dir=\"$TEST_DIR/input\" 5" \
    'only immediate regular files are counted'

assert_contains "$TEST_DIR/payload.txt" \
    "custom.directory.file.count,host=\"aix\\\"01\",dir=\"$TEST_DIR/empty\" 0" \
    'empty directory reports zero'

mkdir "$TEST_DIR/batches"
/usr/bin/perl "$ROOT_DIR/aix_mtime_collector.pl" \
    --host 'test-host' \
    --directories "$TEST_DIR/directories.conf" \
    --output-directory "$TEST_DIR/batches" \
    --max-batch-bytes 300 \
    --now 1704070800 > "$TEST_DIR/batch-summary.txt"
batch_rc=$?
batch_count=$(find "$TEST_DIR/batches" -type f -name 'payload.*.txt' | wc -l | tr -d ' ')
oversized_count=$(find "$TEST_DIR/batches" -type f -name 'payload.*.txt' -size +300c | wc -l | tr -d ' ')
batched_lines=$(cat "$TEST_DIR"/batches/payload.*.txt | wc -l | tr -d ' ')
original_lines=$(wc -l < "$TEST_DIR/payload.txt" | tr -d ' ')

if [ "$batch_rc" -eq 0 ] && [ "$batch_count" -gt 1 ] && \
   [ "$oversized_count" -eq 0 ] && [ "$batched_lines" -eq "$original_lines" ]; then
    printf 'ok - payload is split on line boundaries below the batch limit\n'
else
    printf 'not ok - payload is split on line boundaries below the batch limit\n'
    failures=$((failures + 1))
fi

if grep -Fq 'ignored.dat' "$TEST_DIR/payload.txt"; then
    printf 'not ok - nested files are excluded\n'
    failures=$((failures + 1))
else
    printf 'ok - nested files are excluded\n'
fi

cat > "$TEST_DIR/wrapper.conf" <<EOF
HOST_ID="test-host"
DIRECTORIES_FILE="$TEST_DIR/directories.conf"
COLLECTOR="$ROOT_DIR/aix_mtime_collector.pl"
PERL_BIN="/usr/bin/perl"
RUNTIME_ROOT="$TEST_DIR"
EOF

bash "$ROOT_DIR/aix_mtime_v2.sh" -c "$TEST_DIR/wrapper.conf" --dry-run \
    > "$TEST_DIR/dry-run.txt" 2> "$TEST_DIR/dry-run.err"
wrapper_rc=$?

if [ "$wrapper_rc" -eq 0 ] && grep -Fq 'custom.directory.file.count' "$TEST_DIR/dry-run.txt"; then
    printf 'ok - wrapper dry run produces metrics without curl\n'
else
    printf 'not ok - wrapper dry run produces metrics without curl (rc=%s)\n' "$wrapper_rc"
    failures=$((failures + 1))
fi

cat > "$TEST_DIR/mock-curl" <<'EOF'
#!/usr/bin/env bash
output_file=
payload_file=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output_file=$2
            shift 2
            ;;
        --write-out|--config)
            shift 2
            ;;
        --data-binary)
            payload_file=${2#@}
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[ -s "$payload_file" ] || exit 26

if [ "${MOCK_INVALID:-0}" -eq 1 ]; then
    printf '{"linesOk":0,"linesInvalid":1}' > "$output_file"
else
    lines=$(wc -l < "$payload_file" | tr -d ' ')
    printf '{"linesOk":%s,"linesInvalid":0}' "$lines" > "$output_file"
fi

printf '202'
EOF
chmod +x "$TEST_DIR/mock-curl"
: > "$TEST_DIR/curl.conf"

cat > "$TEST_DIR/wrapper-post.conf" <<EOF
HOST_ID="test-host"
DIRECTORIES_FILE="$TEST_DIR/directories.conf"
CURL_CONFIG="$TEST_DIR/curl.conf"
COLLECTOR="$ROOT_DIR/aix_mtime_collector.pl"
PERL_BIN="/usr/bin/perl"
CURL_BIN="$TEST_DIR/mock-curl"
RUNTIME_ROOT="$TEST_DIR"
EOF

bash "$ROOT_DIR/aix_mtime_v2.sh" -c "$TEST_DIR/wrapper-post.conf" \
    > "$TEST_DIR/post.out" 2> "$TEST_DIR/post.err"
post_rc=$?

if [ "$post_rc" -eq 0 ] && grep -Fq 'SUCCESS:' "$TEST_DIR/post.err"; then
    printf 'ok - wrapper validates successful Dynatrace response\n'
else
    printf 'not ok - wrapper validates successful Dynatrace response (rc=%s)\n' "$post_rc"
    failures=$((failures + 1))
fi

MOCK_INVALID=1 bash "$ROOT_DIR/aix_mtime_v2.sh" -c "$TEST_DIR/wrapper-post.conf" \
    > "$TEST_DIR/invalid.out" 2> "$TEST_DIR/invalid.err"
invalid_rc=$?

if [ "$invalid_rc" -eq 3 ] && grep -Fq 'rejected 1 metric line' "$TEST_DIR/invalid.err"; then
    printf 'ok - wrapper fails when Dynatrace rejects a line\n'
else
    printf 'not ok - wrapper fails when Dynatrace rejects a line (rc=%s)\n' "$invalid_rc"
    failures=$((failures + 1))
fi

printf '%s\n%s\n' "$TEST_DIR/input" "$TEST_DIR/missing" > "$TEST_DIR/partial.conf"
/usr/bin/perl "$ROOT_DIR/aix_mtime_collector.pl" \
    --host 'test-host' \
    --directories "$TEST_DIR/partial.conf" \
    --output "$TEST_DIR/partial-payload.txt" \
    --now 1704070800 > "$TEST_DIR/partial-summary.txt" 2> "$TEST_DIR/partial.err"
partial_rc=$?

if [ "$partial_rc" -eq 2 ] && grep -Fq 'custom.file.age.seconds' "$TEST_DIR/partial-payload.txt"; then
    printf 'ok - inaccessible directory produces partial result\n'
else
    printf 'not ok - inaccessible directory produces partial result (rc=%s)\n' "$partial_rc"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures"
    exit 1
fi

printf 'all tests passed\n'
