# aix_mtime_v1.sh Documentation

## Overview
The `aix_mtime` script is designed to monitor the last modified time of the files in a given directory. It provides observability for aix file system into dynatrace (pre-built extension not available).

## Configuration
To configure the script, you'll need to specify the following parameters:
- `DT_TENANT_URL` - Dynatrace tenant URL with environment ID.
- `DT_API_TOKEN` - Dynatrace PAAS token with Ingest.Metrics permission.
- `HOST_IP` - The host ip of the source.
- `DIR` - Host directory where monitoring is needed.
- `Metric Name` - Metric name to be configured in the payload (recommended format: custom.app_name...)

Ensure that the configuration values follow the required format to avoid issues during execution.

## Setup Instructions
1. Clone the repository:
   ```bash
   git clone https://github.com/Mohammed-Aftab-Siddique/dynatrace-aix-mtime-mon.git
   ```
2. Navigate to the cloned directory:
   ```bash
   cd dynatrace-aix-mtime-mon
   ```
3. Ensure that you have the necessary permissions to execute the script:
   ```bash
   chmod +x aix_mtime_v1.sh
   ```
## Metric Overview
Metric Name(s):
 ```bash
   custom.file.mtime.v1
   ```
Metric Dimensions:
 ```bash
   filename, host, mtime & dir
   ```
Metric Value:
 ```bash
   availability
   ```
## Security Considerations
- Be aware of the sensitivity of the data being processed. Avoid exposing sensitive information in the output files.
- Run the script in a secure environment to prevent unauthorized access to the files.

## Troubleshooting
- **Permission Denied**: Check that the script has appropriate execution permissions.

## Examples
To run the parser on a log file, use the following command:
```bash
./aix_mtime_v1.sh
```

This command will process the specified log file and ingest an output to dynatrace.

# Version History

## aix_mtime_v1
- Initial Release

