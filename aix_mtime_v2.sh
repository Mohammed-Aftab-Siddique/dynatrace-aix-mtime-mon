#!/usr/bin/ksh

PATH=/usr/bin:/bin:/usr/sbin
export PATH
umask 077

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -z "$SCRIPT_DIR" ]; then
    echo "ERROR: cannot determine script directory" >&2
    exit 1
fi

CONFIG_FILE=${AIX_MTIME_CONFIG:-"$SCRIPT_DIR/aix_mtime.conf"}
DRY_RUN=0

usage()
{
    echo "Usage: $0 [-c CONFIG_FILE] [--dry-run]" >&2
}

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

while [ "$#" -gt 0 ]
do
    case "$1" in
        -c)
            [ "$#" -ge 2 ] || { usage; exit 1; }
            CONFIG_FILE=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ ! -r "$CONFIG_FILE" ]; then
    log "ERROR: cannot read configuration: $CONFIG_FILE"
    exit 1
fi

. "$CONFIG_FILE"

PERL_BIN=${PERL_BIN:-/usr/bin/perl}
CURL_BIN=${CURL_BIN:-/usr/bin/curl}
COLLECTOR=${COLLECTOR:-"$SCRIPT_DIR/aix_mtime_collector.pl"}
RUNTIME_ROOT=${RUNTIME_ROOT:-/tmp}
MAX_PAYLOAD_BYTES=${MAX_PAYLOAD_BYTES:-900000}

if [ -z "${HOST_ID:-}" ]; then
    log "ERROR: HOST_ID is not configured"
    exit 1
fi

if [ -z "${DIRECTORIES_FILE:-}" ] || [ ! -r "$DIRECTORIES_FILE" ]; then
    log "ERROR: directory list is not readable: ${DIRECTORIES_FILE:-<unset>}"
    exit 1
fi

if [ ! -x "$PERL_BIN" ]; then
    log "ERROR: Perl is not executable: $PERL_BIN"
    exit 1
fi

if [ ! -r "$COLLECTOR" ]; then
    log "ERROR: collector is not readable: $COLLECTOR"
    exit 1
fi

case "$RUNTIME_ROOT" in
    /*) ;;
    *)
        log "ERROR: RUNTIME_ROOT must be an absolute path"
        exit 1
        ;;
esac

WORK_DIR="$RUNTIME_ROOT/aix_mtime.$$"
PAYLOAD_DIR="$WORK_DIR/payloads"
RESPONSE_FILE="$WORK_DIR/response.json"

cleanup()
{
    if [ -d "$PAYLOAD_DIR" ]; then
        for CLEANUP_FILE in "$PAYLOAD_DIR"/payload.*.txt
        do
            [ -f "$CLEANUP_FILE" ] && rm -f "$CLEANUP_FILE"
        done
        rmdir "$PAYLOAD_DIR" 2>/dev/null
    fi
    [ -f "$RESPONSE_FILE" ] && rm -f "$RESPONSE_FILE"
    [ -d "$WORK_DIR" ] && rmdir "$WORK_DIR" 2>/dev/null
}

trap 'cleanup' 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

if ! mkdir "$WORK_DIR"; then
    log "ERROR: cannot create private runtime directory: $WORK_DIR"
    exit 1
fi

if ! mkdir "$PAYLOAD_DIR"; then
    log "ERROR: cannot create payload directory: $PAYLOAD_DIR"
    exit 1
fi

COLLECT_SUMMARY=$(
    "$PERL_BIN" "$COLLECTOR" \
        --host "$HOST_ID" \
        --directories "$DIRECTORIES_FILE" \
        --output-directory "$PAYLOAD_DIR" \
        --max-batch-bytes "$MAX_PAYLOAD_BYTES"
)
COLLECT_RC=$?

case "$COLLECT_RC" in
    0) ;;
    2)
        log "WARNING: collection completed with one or more skipped directories/files"
        ;;
    *)
        log "ERROR: metric collection failed"
        exit 2
        ;;
esac

set -- "$PAYLOAD_DIR"/payload.*.txt
if [ "$#" -eq 0 ] || [ ! -s "$1" ]; then
    log "ERROR: collector produced an empty payload"
    exit 2
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for PAYLOAD_FILE in "$PAYLOAD_DIR"/payload.*.txt
    do
        cat "$PAYLOAD_FILE"
    done
    log "DRY RUN: $COLLECT_SUMMARY"
    exit "$COLLECT_RC"
fi

if [ -z "${CURL_CONFIG:-}" ] || [ ! -r "$CURL_CONFIG" ]; then
    log "ERROR: curl configuration is not readable: ${CURL_CONFIG:-<unset>}"
    exit 1
fi

if [ ! -x "$CURL_BIN" ]; then
    log "ERROR: curl is not executable: $CURL_BIN"
    exit 1
fi

TOTAL_LINES_OK=0
TOTAL_LINES_INVALID=0
BATCHES_SENT=0

for PAYLOAD_FILE in "$PAYLOAD_DIR"/payload.*.txt
do
    BATCHES_SENT=$((BATCHES_SENT + 1))
    HTTP_STATUS=$(
        "$CURL_BIN" \
            --config "$CURL_CONFIG" \
            --output "$RESPONSE_FILE" \
            --write-out '%{http_code}' \
            --data-binary @"$PAYLOAD_FILE"
    )
    CURL_RC=$?

    if [ "$CURL_RC" -ne 0 ]; then
        log "ERROR: curl failed for batch $BATCHES_SENT with exit code $CURL_RC (HTTP ${HTTP_STATUS:-unknown})"
        [ -s "$RESPONSE_FILE" ] && cat "$RESPONSE_FILE" >&2
        exit 3
    fi

    case "$HTTP_STATUS" in
        2??) ;;
        *)
            log "ERROR: Dynatrace returned HTTP $HTTP_STATUS for batch $BATCHES_SENT"
            [ -s "$RESPONSE_FILE" ] && cat "$RESPONSE_FILE" >&2
            exit 3
            ;;
    esac

    API_COUNTS=$(
        "$PERL_BIN" -0777 -e '
            my $text = <>;
            my ($ok) = $text =~ /"linesOk"\s*:\s*(\d+)/;
            my ($invalid) = $text =~ /"linesInvalid"\s*:\s*(\d+)/;
            exit 2 unless defined $ok && defined $invalid;
            print "$ok $invalid";
        ' "$RESPONSE_FILE"
    )
    PARSE_RC=$?

    if [ "$PARSE_RC" -ne 0 ]; then
        log "ERROR: cannot validate Dynatrace response for batch $BATCHES_SENT"
        [ -s "$RESPONSE_FILE" ] && cat "$RESPONSE_FILE" >&2
        exit 3
    fi

    set -- $API_COUNTS
    LINES_OK=$1
    LINES_INVALID=$2
    TOTAL_LINES_OK=$((TOTAL_LINES_OK + LINES_OK))
    TOTAL_LINES_INVALID=$((TOTAL_LINES_INVALID + LINES_INVALID))

    if [ "$LINES_INVALID" -ne 0 ]; then
        log "ERROR: Dynatrace rejected $LINES_INVALID metric line(s) in batch $BATCHES_SENT; accepted $LINES_OK"
        cat "$RESPONSE_FILE" >&2
        exit 3
    fi
done

log "SUCCESS: $COLLECT_SUMMARY sent_batches=$BATCHES_SENT accepted=$TOTAL_LINES_OK invalid=$TOTAL_LINES_INVALID"

if [ "$COLLECT_RC" -eq 2 ]; then
    exit 2
fi

exit 0
