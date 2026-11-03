#!/bin/bash
# askpass.sh — sudo password from a macOS dialog, for sudo -A (SUDO_ASKPASS)
# when there's no terminal, e.g. the SwiftBar tunnel menu.
osascript - "${1:-Password:}" <<'OSA'
on run argv
    set r to display dialog (item 1 of argv) with title "sudo" default answer "" with hidden answer ¬
        with icon caution buttons {"Cancel", "OK"} default button "OK"
    return text returned of r
end run
OSA
