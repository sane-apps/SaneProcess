use framework "Foundation"
use scripting additions

on run argv
    -- Auto-detect project name from git root, or pass as argument
    set appName to do shell script "basename \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\""
    if (count of argv) > 0 then
        set appName to item 1 of argv
    end if
    
    log "🛡️ Starting enhanced permission monitor for: " & appName
    
    -- Default monitoring: 5 minutes. SaneMaster passes a longer duration for
    -- unattended Mini verification so late prompts do not stall the run.
    set monitorDuration to 300
    if (count of argv) > 1 then
        try
            set requestedDuration to (item 2 of argv) as integer
            if requestedDuration > 0 then
                set monitorDuration to requestedDuration
            end if
        end try
    end if
    set checkInterval to 0.5 -- Check every 0.5 seconds for faster response
    
    repeat (monitorDuration / checkInterval) times
        tell application "System Events"
            -- 1. Check UserNotificationCenter (modern macOS permission dialogs)
            if exists process "UserNotificationCenter" then
                tell process "UserNotificationCenter"
                    repeat with w in windows
                        try
                            set winName to name of w
                            if winName contains appName or winName contains "access" or winName contains "permission" then
                                -- Look for Allow button (try multiple possible labels)
                                repeat with btnLabel in {"Allow", "OK", "Grant", "Enable"}
                                    try
                                        if exists button btnLabel of w then
                                            click button btnLabel of w
                                            log "✅ Clicked " & btnLabel & " on UserNotificationCenter"
                                            delay 0.5 -- Brief pause after click
                                        end if
                                    end try
                                end repeat
                            end if
                        end try
                    end repeat
                end tell
            end if
            
            -- 2. Check CoreServicesUIAgent (legacy TCC dialogs)
            if exists process "CoreServicesUIAgent" then
                tell process "CoreServicesUIAgent"
                    repeat with w in windows
                        try
                            set winText to ""
                            try
                                set winText to value of static text 1 of w
                            end try
                            
                            if winText contains appName or winText contains "access" or winText contains "permission" then
                                repeat with btnLabel in {"Allow", "OK", "Grant", "Enable", "Open System Preferences"}
                                    try
                                        if exists button btnLabel of w then
                                            click button btnLabel of w
                                            log "✅ Clicked " & btnLabel & " on CoreServicesUIAgent"
                                            delay 0.5
                                        end if
                                    end try
                                end repeat
                            end if
                        end try
                    end repeat
                end tell
            end if
            
            -- 3. Check the app itself (sometimes dialogs appear in-app)
            if exists process appName then
                tell process appName
                    repeat with w in windows
                        try
                            set winName to name of w
                            if winName contains "permission" or winName contains "access" or winName contains "Privacy" then
                                repeat with btnLabel in {"Allow", "OK", "Grant", "Open System Settings"}
                                    try
                                        if exists button btnLabel of w then
                                            click button btnLabel of w
                                            log "✅ Clicked " & btnLabel & " in " & appName & " window"
                                            delay 0.5
                                        end if
                                    end try
                                end repeat
                            end if
                        end try
                    end repeat
                end tell
            end if
            
            -- 4. Check for System Preferences/Settings windows that might have opened
            if exists process "System Settings" then
                tell process "System Settings"
                    -- If System Settings opened, we can't auto-grant, but we log it
                    if exists (window 1) then
                        log "⚠️ System Settings opened - manual grant may be needed"
                    end if
                end tell
            end if
            
            if exists process "System Preferences" then
                tell process "System Preferences"
                    if exists (window 1) then
                        log "⚠️ System Preferences opened - manual grant may be needed"
                    end if
                end tell
            end if
            
        end tell
        delay checkInterval
    end repeat
    
    log "🛡️ Permission monitor finished (ran for " & monitorDuration & " seconds)"
end run
