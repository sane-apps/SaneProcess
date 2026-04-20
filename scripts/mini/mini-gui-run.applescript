on run argv
  if (count of argv) < 2 then
    error "Usage: mini-gui-run.applescript <windowTitle> <shellCommand>"
  end if

  set windowTitle to item 1 of argv
  set shellCommand to item 2 of argv

  tell application "Terminal"
    launch
    set targetTab to do script shellCommand
    set targetWindowID to id of front window
    try
      set custom title of targetTab to windowTitle
    end try
    try
      set bounds of front window to {-2200, 80, -1200, 720}
    end try
    try
      set miniaturized of front window to true
    end try
  end tell

  try
    tell application "Finder" to activate
  end try

  return (targetWindowID as string)
end run
