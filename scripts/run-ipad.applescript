-- Install and run using Xcode's supported scripting interface (also works with iPadOS 16).
on run argv
    set projectPath to item 1 of argv
    set ipadIdentifier to item 2 of argv
    tell application "Xcode"
        open projectPath
        set bridgeWorkspace to workspace document "PencilBridge.xcodeproj"
        repeat 40 times
            if loaded of bridgeWorkspace then exit repeat
            delay 0.5
        end repeat
        if not loaded of bridgeWorkspace then error "Xcode workspace is still loading."
        set active scheme of bridgeWorkspace to scheme "PencilBridgeiPad" of bridgeWorkspace
        set matchedDestination to missing value
        repeat with candidate in run destinations of bridgeWorkspace
            try
                if device identifier of device of candidate is ipadIdentifier then
                    set matchedDestination to contents of candidate
                    exit repeat
                end if
            end try
        end repeat
        if matchedDestination is missing value then error "The iPad is not an eligible Xcode run destination. Check Developer Mode and unlock the iPad."
        set active run destination of bridgeWorkspace to matchedDestination
        set actionResult to run bridgeWorkspace
        return "Run started: " & (id of actionResult)
    end tell
end run
