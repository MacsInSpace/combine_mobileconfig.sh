# mobileconfig-combiner

A bash script for macOS that intelligently combines multiple `.mobileconfig` files into a single configuration profile.

## Features

- Merges all TCC (Privacy Preferences) payloads into a single unified payload
- Combines services from multiple TCC profiles (Accessibility, Full Disk Access, Bluetooth, etc.)
- Detects and handles duplicate payloads by PayloadIdentifier
- Prefers more complex payloads when duplicates are found (e.g., chooses restricted system extensions over standard ones)
- Generates new UUIDs for the combined profile
- Compatible with bash 3.2+ (works on macOS default bash)

## Requirements

- macOS with bash 3.2 or later
- `/usr/libexec/PlistBuddy` (included with macOS)
- `plutil` (included with macOS)

## Usage

```bash
# Combine all .mobileconfig files in current directory
./combine_mobileconfig.sh

# Combine files from specific directory
./combine_mobileconfig.sh /path/to/profiles

# Specify custom output filename
./combine_mobileconfig.sh /path/to/profiles custom_output.mobileconfig
```

## Example

```bash
bash-3.2$ bash ./combine_mobileconfig.sh ./defender_profiles
Found 9 profile(s) to combine
Processing: accessibility.mobileconfig
  Created combined TCC payload
  Merged TCC service: Accessibility (1 entries)
Processing: fulldisk.mobileconfig
  Merged TCC service: SystemPolicyAllFiles (3 entries)
Processing: sysext.mobileconfig
  Added payload: com.apple.system-extension-policy
Processing: sysext_restricted.mobileconfig
  Replacing payload (new has 8 keys vs 7 keys)

Successfully created: combined_profile.mobileconfig

Summary:
  Source profiles: 9
  Total payloads: 6
  TCC services: 3
```

## How It Works

1. Scans the specified directory for all `.mobileconfig` files
2. Converts binary plists to XML format
3. Extracts payloads from each profile
4. For TCC payloads: combines all services into a single TCC payload
5. For other payloads: adds unique payloads, replacing with more complex versions when duplicates are found
6. Generates a new combined profile with fresh UUIDs

## Notes

- The script automatically skips duplicate PayloadIdentifiers
- When duplicates are found, it prefers the payload with more keys (more comprehensive configuration)
- All TCC services are merged into a single Privacy Preferences payload
- Output is always in XML plist format

## License

MIT
