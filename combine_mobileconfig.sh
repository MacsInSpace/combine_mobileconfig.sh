#!/bin/bash

# Script: combine_mobileconfig.sh
# Purpose: Intelligently merge multiple .mobileconfig files by combining payloads of the same type
# Usage: ./combine_mobileconfig.sh /path/to/mobileconfig/folder [output_filename]

# Check if PlistBuddy and plutil are available
if ! command -v /usr/libexec/PlistBuddy &> /dev/null; then
    echo "Error: PlistBuddy not found"
    exit 1
fi

if ! command -v plutil &> /dev/null; then
    echo "Error: plutil not found"
    exit 1
fi

# Set source directory and output file
SOURCE_DIR="${1:-.}"
OUTPUT_FILE="${2:-combined_profile.mobileconfig}"

# Validate source directory
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Directory '$SOURCE_DIR' does not exist"
    exit 1
fi

# Count mobileconfig files
PROFILE_COUNT=$(find "$SOURCE_DIR" -maxdepth 1 -name "*.mobileconfig" -type f | wc -l)

if [[ $PROFILE_COUNT -eq 0 ]]; then
    echo "Error: No .mobileconfig files found in '$SOURCE_DIR'"
    exit 1
fi

echo "Found $PROFILE_COUNT profile(s) to combine"

# Create temporary working directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

# Create base profile structure
BASE_PROFILE="$TEMP_DIR/base.plist"
cat > "$BASE_PROFILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
    </array>
    <key>PayloadDisplayName</key>
    <string>Combined Configuration Profile</string>
    <key>PayloadIdentifier</key>
    <string>com.combined.profile</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>REPLACE_UUID</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

# Generate and insert UUID
NEW_UUID=$(uuidgen)
/usr/libexec/PlistBuddy -c "Set :PayloadUUID $NEW_UUID" "$BASE_PROFILE"

# Track what we've added using simple lists
PAYLOAD_IDS_FILE="$TEMP_DIR/payload_ids.txt"
PAYLOAD_INDEX_FILE="$TEMP_DIR/payload_index.txt"
TCC_SERVICES_FILE="$TEMP_DIR/tcc_services.txt"
touch "$PAYLOAD_IDS_FILE" "$PAYLOAD_INDEX_FILE" "$TCC_SERVICES_FILE"

PAYLOAD_INDEX=0
TCC_INDEX=-1

# Get the array index for a payload ID
get_payload_index() {
    grep "^$1:" "$PAYLOAD_INDEX_FILE" 2>/dev/null | cut -d: -f2
}

# Check if TCC service already added
tcc_service_exists() {
    grep -q "^$1\$" "$TCC_SERVICES_FILE" 2>/dev/null
}

# Count keys in a payload
count_payload_keys() {
    local profile="$1"
    local index="$2"
    /usr/libexec/PlistBuddy -c "Print :PayloadContent:$index" "$profile" 2>/dev/null | grep -c " = "
}

# Create TCC payload if needed
create_tcc_payload() {
    if [[ $TCC_INDEX -eq -1 ]]; then
        /usr/libexec/PlistBuddy -c "Add :PayloadContent: dict" "$BASE_PROFILE" 2>/dev/null
        TCC_INDEX=$PAYLOAD_INDEX
        ((PAYLOAD_INDEX++))
        
        NEW_TCC_UUID=$(uuidgen)
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadType string com.apple.TCC.configuration-profile-policy" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadVersion integer 1" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadUUID string $NEW_TCC_UUID" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadEnabled bool true" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadDisplayName string 'Privacy Preferences Policy Control'" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:PayloadIdentifier string com.combined.tcc" "$BASE_PROFILE"
        /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:Services dict" "$BASE_PROFILE"
        
        echo "  Created combined TCC payload"
    fi
}

# Process each mobileconfig file
while IFS= read -r -d '' profile; do
    echo "Processing: $(basename "$profile")"
    
    # Convert to XML format if binary
    TEMP_PROFILE="$TEMP_DIR/$(basename "$profile").xml"
    plutil -convert xml1 "$profile" -o "$TEMP_PROFILE" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        echo "  Warning: Failed to convert, skipping"
        continue
    fi
    
    # Get number of payloads
    PAYLOAD_COUNT=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent" "$TEMP_PROFILE" 2>/dev/null | grep -c "Dict {")
    
    if [[ $PAYLOAD_COUNT -eq 0 ]]; then
        echo "  Warning: No payloads found, skipping"
        continue
    fi
    
    # Process each payload in this profile
    for ((i=0; i<PAYLOAD_COUNT; i++)); do
        PAYLOAD_TYPE=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:$i:PayloadType" "$TEMP_PROFILE" 2>/dev/null)
        PAYLOAD_ID=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:$i:PayloadIdentifier" "$TEMP_PROFILE" 2>/dev/null)
        
        if [[ -z "$PAYLOAD_TYPE" ]]; then
            continue
        fi
        
        # Handle TCC payloads
        if [[ "$PAYLOAD_TYPE" == "com.apple.TCC.configuration-profile-policy" ]]; then
            # Check if Services key exists
            /usr/libexec/PlistBuddy -c "Print :PayloadContent:$i:Services" "$TEMP_PROFILE" &>/dev/null
            if [[ $? -ne 0 ]]; then
                echo "  Warning: TCC payload has no Services"
                continue
            fi
            
            # Get service names (they should be followed by " = Array")
            SERVICE_LIST=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:$i:Services" "$TEMP_PROFILE" 2>/dev/null | \
                grep " = Array" | sed 's/ = Array.*$//' | sed 's/^[[:space:]]*//')
            
            if [[ -z "$SERVICE_LIST" ]]; then
                echo "  Warning: No services found in TCC payload"
                continue
            fi
            
            create_tcc_payload
            
            # Process each service type
            while IFS= read -r service_name; do
                if [[ -z "$service_name" ]]; then
                    continue
                fi
                
                # Skip if we've already added this service
                if tcc_service_exists "$service_name"; then
                    echo "  Skipping duplicate TCC service: $service_name"
                    continue
                fi
                
                # Add this service to combined TCC payload
                /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:Services:$service_name array" "$BASE_PROFILE" 2>/dev/null
                
                # Get the number of entries in this service array
                ENTRY_COUNT=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:$i:Services:$service_name" "$TEMP_PROFILE" 2>/dev/null | grep -c "Dict {")
                
                # Copy each entry
                for ((j=0; j<ENTRY_COUNT; j++)); do
                    ENTRY_XML=$(/usr/libexec/PlistBuddy -x -c "Print :PayloadContent:$i:Services:$service_name:$j" "$TEMP_PROFILE" 2>/dev/null)
                    ENTRY_FILE="$TEMP_DIR/entry_${service_name}_${j}.plist"
                    echo "$ENTRY_XML" > "$ENTRY_FILE"
                    
                    /usr/libexec/PlistBuddy -c "Add :PayloadContent:$TCC_INDEX:Services:$service_name: dict" "$BASE_PROFILE" 2>/dev/null
                    /usr/libexec/PlistBuddy -c "Merge '$ENTRY_FILE' :PayloadContent:$TCC_INDEX:Services:$service_name:$j" "$BASE_PROFILE" 2>/dev/null
                done
                
                echo "$service_name" >> "$TCC_SERVICES_FILE"
                echo "  Merged TCC service: $service_name ($ENTRY_COUNT entries)"
                
            done <<< "$SERVICE_LIST"
            
        else
            # Non-TCC payload
            
            # Check if we've already added this payload ID
            EXISTING_INDEX=$(get_payload_index "$PAYLOAD_ID")
            
            if [[ -n "$EXISTING_INDEX" ]]; then
                # Count keys in both payloads
                NEW_KEY_COUNT=$(count_payload_keys "$TEMP_PROFILE" "$i")
                EXISTING_KEY_COUNT=$(count_payload_keys "$BASE_PROFILE" "$EXISTING_INDEX")
                
                if [[ $NEW_KEY_COUNT -gt $EXISTING_KEY_COUNT ]]; then
                    echo "  Replacing payload $PAYLOAD_ID (new has $NEW_KEY_COUNT keys vs $EXISTING_KEY_COUNT keys)"
                    
                    # Delete the existing payload
                    /usr/libexec/PlistBuddy -c "Delete :PayloadContent:$EXISTING_INDEX" "$BASE_PROFILE" 2>/dev/null
                    
                    # Extract and add the new payload
                    PAYLOAD_XML=$(/usr/libexec/PlistBuddy -x -c "Print :PayloadContent:$i" "$TEMP_PROFILE" 2>/dev/null)
                    PAYLOAD_FILE="$TEMP_DIR/payload_replace_${EXISTING_INDEX}.plist"
                    echo "$PAYLOAD_XML" > "$PAYLOAD_FILE"
                    
                    # Insert at the same index
                    /usr/libexec/PlistBuddy -c "Add :PayloadContent:$EXISTING_INDEX dict" "$BASE_PROFILE" 2>/dev/null
                    /usr/libexec/PlistBuddy -c "Merge '$PAYLOAD_FILE' :PayloadContent:$EXISTING_INDEX" "$BASE_PROFILE" 2>/dev/null
                else
                    echo "  Skipping duplicate payload: $PAYLOAD_ID (existing has $EXISTING_KEY_COUNT keys vs $NEW_KEY_COUNT keys)"
                fi
                continue
            fi
            
            # Extract and add this payload
            PAYLOAD_XML=$(/usr/libexec/PlistBuddy -x -c "Print :PayloadContent:$i" "$TEMP_PROFILE" 2>/dev/null)
            PAYLOAD_FILE="$TEMP_DIR/payload_${PAYLOAD_INDEX}.plist"
            echo "$PAYLOAD_XML" > "$PAYLOAD_FILE"
            
            /usr/libexec/PlistBuddy -c "Add :PayloadContent: dict" "$BASE_PROFILE" 2>/dev/null
            /usr/libexec/PlistBuddy -c "Merge '$PAYLOAD_FILE' :PayloadContent:$PAYLOAD_INDEX" "$BASE_PROFILE" 2>/dev/null
            
            if [[ $? -eq 0 ]]; then
                echo "$PAYLOAD_ID:$PAYLOAD_INDEX" >> "$PAYLOAD_INDEX_FILE"
                ((PAYLOAD_INDEX++))
                echo "  Added payload: $PAYLOAD_TYPE"
            fi
        fi
    done
    
done < <(find "$SOURCE_DIR" -maxdepth 1 -name "*.mobileconfig" -type f -print0 | sort -z)

# Verify we added something
if [[ $PAYLOAD_INDEX -eq 0 ]]; then
    echo ""
    echo "Error: No payloads were successfully combined"
    exit 1
fi

# Convert and save
plutil -convert xml1 "$BASE_PROFILE" -o "$OUTPUT_FILE"

if [[ $? -eq 0 ]]; then
    TCC_COUNT=$(wc -l < "$TCC_SERVICES_FILE" | tr -d ' ')
    
    echo ""
    echo "Successfully created: $OUTPUT_FILE"
    echo ""
    echo "Summary:"
    echo "  Source profiles: $PROFILE_COUNT"
    echo "  Total payloads: $PAYLOAD_INDEX"
    if [[ $TCC_COUNT -gt 0 ]]; then
        echo "  TCC services: $TCC_COUNT"
    fi
else
    echo ""
    echo "Error: Failed to write output file"
    exit 1
fi
