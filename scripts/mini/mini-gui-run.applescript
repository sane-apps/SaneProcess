on run argv
  if (count of argv) < 4 then
    error "Usage: mini-gui-run.applescript <windowTitle> <shellCommand> <closeWindowFlag> <pollSeconds>"
  end if

  set windowTitle to item 1 of argv
  set shellCommand to item 2 of argv
  set closeWindowFlag to item 3 of argv
  set pollSeconds to item 4 of argv
  set shouldClose to (closeWindowFlag is "1" or closeWindowFlag is "true")
  set pollDelay to (pollSeconds as real)

  tell application "Terminal"
    activate
    set targetTab to do script shellCommand
    set targetWindowID to id of front window
    try
      set custom title of targetTab to windowTitle
    end try

    repeat 86400 times
      delay pollDelay
      try
        if busy of targetTab is false then exit repeat
      on error
        exit repeat
      end try
    end repeat

    if shouldClose then
      try
        repeat with w in windows
          try
            if id of w is equal to targetWindowID then
              set index of w to 1
              activate
              close front window saving no
              exit repeat
            end if
          end try
        end repeat
      end try
    end if
  end tell

  return "OK"
end run
