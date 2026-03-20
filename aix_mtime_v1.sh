#!/usr/bin/ksh

# Adjustable variables
DT_TENANT_URL="<Tenant URL with Environment ID"
DT_API_TOKEN="<API-Token with Ingest.Metric permission>"
METRIC_ENDPOINT="$DT_TENANT_URL/api/v2/metrics/ingest"
HOST_IP="<Host IP>"

# Path and permission
PATH=/usr/bin:/bin
export PATH
umask 077

# Creating temp files
TMP_PAYLOAD="/tmp/dt_mtime_payload.$$"
> "$TMP_PAYLOAD"

# For -> </path/to/dir1> 
DIR="</path/to/dir1>"

find "$DIR" -type f 2>/dev/null | while read -r FILE
do
  # Extracting the basename of a file
  BASE_FILE=$(basename "$FILE")

  # Fetch last modified time
  MTIME=$(ls -l $FILE | awk '{print $6, $7, $8}')

  # Create payload
  echo "custom.file.mtime.v1,filename=${BASE_FILE},host=${HOST_IP},dir=${DIR},mtime=${MTIME} 1" >> "$TMP_PAYLOAD"
done

# Note: You can add as many directory blocks as required.

# Ingest to DT
curl -kv -s -X POST "$METRIC_ENDPOINT" -H "Authorization: Api-Token $DT_API_TOKEN" -H "Content-Type: text/plain; charset=utf-8" --data-binary @"$TMP_PAYLOAD" 2>/dev/null

# Remove Temp file
rm -rf "$TMP_PAYLOAD"

exit 0
