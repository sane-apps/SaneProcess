on restoreBundleID(bundleID)
  try
    tell application "System Events"
      repeat with candidateProcess in application processes
        try
          if bundle identifier of candidateProcess is bundleID then
            set frontmost of candidateProcess to true
            return true
          end if
        end try
      end repeat
    end tell
  end try

  try
    tell application id bundleID to activate
    return true
  end try

  return false
end restoreBundleID

on run argv
  if (count of argv) < 2 then
    error "Usage: mini-gui-run.applescript <windowTitle> <shellCommand>"
  end if

  set windowTitle to item 1 of argv
  set shellCommand to item 2 of argv
  set focusMode to "finder"
  if (count of argv) is greater than or equal to 3 then
    set focusMode to item 3 of argv
  end if

  set priorBundleID to ""
  set explicitRestoreBundleID to ""
  if focusMode is "restore-frontmost" then
    try
      tell application "System Events"
        set frontProcesses to application processes whose frontmost is true
        if (count of frontProcesses) > 0 then
          set priorBundleID to bundle identifier of item 1 of frontProcesses
        end if
      end tell
    end try
  else if focusMode starts with "restore-bundle-id:" then
    set explicitRestoreBundleID to text 19 thru -1 of focusMode
  end if

  tell application "Terminal"
    launch
    delay 0.5
    set targetTab to do script shellCommand
    delay 0.2
    try
      set custom title of targetTab to windowTitle
    end try
    set targetWindow to first window whose selected tab is targetTab
    set targetWindowID to id of targetWindow
    try
      set bounds of targetWindow to {-2200, 80, -1200, 720}
    end try
    try
      set miniaturized of targetWindow to true
    end try
  end tell

  -- Terminal can ignore or briefly reverse miniaturization while the launched
  -- command changes tab state. Hiding the host process before this launcher
  -- returns prevents the automation window from covering the target app.
  try
    tell application "System Events"
      if exists process "Terminal" then
        set visible of process "Terminal" to false
      end if
    end tell
  end try

  try
    if explicitRestoreBundleID is not "" then
      my restoreBundleID(explicitRestoreBundleID)
    else if focusMode is "restore-frontmost" and priorBundleID is not "" and priorBundleID is not "com.apple.Terminal" then
      my restoreBundleID(priorBundleID)
    else
      tell application "Finder" to activate
    end if
  end try

  return (targetWindowID as string)
end run
