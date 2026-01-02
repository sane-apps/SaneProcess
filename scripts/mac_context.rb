#!/usr/bin/env ruby
# frozen_string_literal: true

# Mac Developer Context Generator
# Injects Mac-specific knowledge into Claude's context
#
# Usage: ./scripts/mac_context.rb
#        Creates .claude/mac_context.md with 370+ lines of Mac dev patterns

require 'fileutils'

CONTEXT_FILE = '.claude/mac_context.md'

def generate_mac_context
  <<~CONTEXT
    # Mac Development Context

    > **CRITICAL**: This context is auto-generated. Claude MUST follow these patterns.

    ---

    ## Build System Rules

    ### NEVER Touch .xcodeproj Directly
    - `.xcodeproj` files are binary XML - AI edits break them
    - Use `project.yml` + `xcodegen generate` instead
    - After creating new Swift files: ALWAYS run `xcodegen generate`

    ### Build Commands
    ```bash
    # RIGHT - Use project tools
    ./Scripts/build.rb verify

    # WRONG - Raw xcodebuild (misses configuration)
    xcodebuild -scheme MyApp build
    ```

    ### DerivedData Location
    - Build products: `~/Library/Developer/Xcode/DerivedData/<Project>-*/Build/Products/Debug/`
    - Clean with: `rm -rf ~/Library/Developer/Xcode/DerivedData/<Project>-*`

    ---

    ## Info.plist Patterns

    ### Required Keys (macOS App)
    ```xml
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>

    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>

    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>

    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>

    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    ```

    ### Common Permission Keys
    | Permission | Key | When Needed |
    |------------|-----|-------------|
    | Camera | `NSCameraUsageDescription` | Recording video |
    | Microphone | `NSMicrophoneUsageDescription` | Recording audio |
    | Screen Recording | `NSScreenCaptureUsageDescription` | Screen capture |
    | Accessibility | `NSAccessibilityUsageDescription` | AX API access |
    | Location | `NSLocationUsageDescription` | Location services |
    | Photos | `NSPhotoLibraryUsageDescription` | Photo library |

    ---

    ## Entitlements

    ### Non-Sandboxed App (Development)
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.app-sandbox</key>
        <false/>
    </dict>
    </plist>
    ```

    ### Sandboxed App (App Store)
    ```xml
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    ```

    ### Hardened Runtime (Notarization)
    ```xml
    <key>com.apple.security.hardened-runtime</key>
    <true/>
    ```

    ---

    ## Common Crash Patterns

    ### Actor Isolation Crashes
    ```
    Symptom: dispatch_assert_queue_fail
    Cause: assumeIsolated in deinit
    Fix: Use nonisolated(unsafe) or remove assumeIsolated from deinit
    ```

    ### NULL Pointer (Object Deallocated)
    ```
    Symptom: SIGSEGV at address 0x0-0x1000
    Cause: Accessing deallocated object
    Fix: Add isActive guards, use TimelineView for animations
    ```

    ### Race Condition
    ```
    Symptom: objc_release crash, random SIGSEGV
    Cause: Multiple threads accessing same object
    Fix: Use actors, @MainActor, or locks
    ```

    ---

    ## Menu Bar Apps

    ### NSStatusItem Setup
    ```swift
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(named: "MenuBarIcon")
    statusItem.button?.image?.isTemplate = true  // CRITICAL for dark mode
    ```

    ### Menu Bar Icon Requirements
    - Size: 18x18 points (36x36 @2x)
    - Format: Template image (single color, alpha channel)

    ### NSMenu Target
    ```swift
    // CRITICAL: Set target or items appear disabled
    let item = NSMenuItem(title: "Action", action: #selector(doAction), keyEquivalent: "")
    item.target = self  // <-- Without this, menu item is grayed out
    menu.addItem(item)
    ```

    ---

    ## Accessibility API

    ### Checking Permission
    ```swift
    let trusted = AXIsProcessTrusted()
    ```

    ### Opening System Settings
    ```swift
    // CORRECT - Use Process with bundle ID
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", "com.apple.systempreferences",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"]
    try process.run()
    ```

    ---

    ## Swift Concurrency

    ### @MainActor Rules
    - All UI code must be @MainActor
    - Don't use assumeIsolated in deinit

    ### Task Patterns
    ```swift
    // RIGHT - Flat task structure
    Task { @MainActor in
        let result = await fetchData()
        self.data = result
    }

    // WRONG - Nested tasks cause actor-hopping issues
    Task {
        Task { @MainActor in
            // Can freeze
        }
    }
    ```

    ---

    ## XcodeGen (project.yml)

    ### Minimal Template
    ```yaml
    name: MyApp
    options:
      bundleIdPrefix: com.company
      deploymentTarget:
        macOS: "14.0"

    targets:
      MyApp:
        type: application
        platform: macOS
        sources: [MyApp]
        settings:
          INFOPLIST_FILE: MyApp/Info.plist

      MyAppTests:
        type: bundle.unit-test
        platform: macOS
        sources: [MyAppTests]
        dependencies:
          - target: MyApp
    ```

    ---

    ## Logging

    ### Viewing Logs
    ```bash
    # Stream live
    log stream --predicate 'process == "MyApp"' --style compact

    # Show recent
    log show --predicate 'process == "MyApp"' --last 5m
    ```

    ---

    *Generated by SaneProcess mac_context*
  CONTEXT
end

# Main
FileUtils.mkdir_p(File.dirname(CONTEXT_FILE))
File.write(CONTEXT_FILE, generate_mac_context)

puts '🍎 Mac Developer Context injected'
puts "   #{generate_mac_context.lines.count} lines → #{CONTEXT_FILE}"
