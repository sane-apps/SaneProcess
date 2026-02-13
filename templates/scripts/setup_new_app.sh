#!/bin/bash
#
# SaneApps New App Setup Script
# Creates a new app with all standard templates
#
# Usage: ./setup_new_app.sh AppName com.appname.app [target_dir]
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Arguments
APP_NAME="${1:-}"
BUNDLE_ID="${2:-}"
TARGET_DIR="${3:-$(pwd)/${APP_NAME}}"

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "Usage: $0 <AppName> <bundle.id> [target_dir]"
    echo ""
    echo "Example: $0 SaneHosts com.sanehosts.app"
    exit 1
fi

APP_LOWER=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')
TEMPLATES_DIR="$(dirname "$0")/../templates"

log_info "Setting up new SaneApp: $APP_NAME"
log_info "Bundle ID: $BUNDLE_ID"
log_info "Target: $TARGET_DIR"

# Create directory structure
log_step "Creating directory structure..."
mkdir -p "$TARGET_DIR"/{.github/ISSUE_TEMPLATE,.github/workflows,docs/images,marketing/images,scripts,releases,Resources/Assets.xcassets}

# Copy templates
log_step "Copying templates..."
for file in README.md LICENSE CHANGELOG.md CONTRIBUTING.md PRIVACY.md SECURITY.md CODE_OF_CONDUCT.md; do
    if [ -f "$TEMPLATES_DIR/$file" ]; then
        cp "$TEMPLATES_DIR/$file" "$TARGET_DIR/"
    fi
done

# Copy GitHub templates
cp -r "$TEMPLATES_DIR/.github/"* "$TARGET_DIR/.github/" 2>/dev/null || true

# Copy FUNDING.yml
if [ -f "$TEMPLATES_DIR/FUNDING.yml" ]; then
    cp "$TEMPLATES_DIR/FUNDING.yml" "$TARGET_DIR/.github/"
fi

# Replace placeholders
log_step "Customizing templates..."
find "$TARGET_DIR" -type f \( -name "*.md" -o -name "*.yml" -o -name "*.yaml" -o -name "*.rb" \) -exec sed -i '' \
    -e "s/TODO:AppName/$APP_NAME/g" \
    -e "s/TODO:appname/$APP_LOWER/g" \
    -e "s/TODO:Date/$(date +%Y-%m-%d)/g" \
    {} \;

# Create project.yml
log_step "Creating project.yml..."
cat > "$TARGET_DIR/project.yml" << EOF
name: $APP_NAME
options:
  bundleIdPrefix: ${BUNDLE_ID%.*}
  deploymentTarget:
    macOS: 15.0
  xcodeVersion: 16.0

configs:
  Debug: debug
  Release: release

packages:
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: 2.0.0
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
  SaneUI:
    path: ../Projects/SaneUI

settings:
  DEAD_CODE_STRIPPING: YES
  ENABLE_HARDENED_RUNTIME: YES
  GENERATE_INFOPLIST_FILE: YES
  SWIFT_STRICT_CONCURRENCY: complete

schemes:
  $APP_NAME:
    build:
      targets:
        $APP_NAME: all
    run:
      config: Debug
    archive:
      config: Release

targets:
  $APP_NAME:
    type: application
    platform: macOS
    bundleId: $BUNDLE_ID
    deploymentTarget:
      macOS: 15.0
    sources:
      - Sources
      - Resources
    dependencies:
      - package: KeyboardShortcuts
      - package: Sparkle
      - package: SaneUI
    info:
      path: $APP_NAME/Info.plist
      properties:
        NSAppleEventsUsageDescription: "$APP_NAME needs to control other applications."
        LSApplicationCategoryType: "public.app-category.utilities"
        SUFeedURL: "https://$APP_LOWER.com/appcast.xml"
        SUEnableAutomaticChecks: true
        SUPublicEDKey: "TODO:ADD_SPARKLE_PUBLIC_KEY"
    settings:
      base:
        PRODUCT_NAME: $APP_NAME
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        DEVELOPMENT_TEAM: M78L6FXD48
        CODE_SIGN_STYLE: Manual
      configs:
        Debug:
          CODE_SIGN_IDENTITY: "Apple Development"
        Release:
          CODE_SIGN_IDENTITY: "Developer ID Application"
EOF

# Create SwiftLint config
log_step "Creating .swiftlint.yml..."
cat > "$TARGET_DIR/.swiftlint.yml" << 'EOF'
disabled_rules:
  - line_length
  - identifier_name
  - type_body_length
  - file_length

opt_in_rules:
  - empty_count
  - closure_spacing

excluded:
  - .build
  - DerivedData
  - Packages
EOF

# Create basic app structure
log_step "Creating app source files..."
mkdir -p "$TARGET_DIR/Sources"
mkdir -p "$TARGET_DIR/$APP_NAME"

# Main app file
cat > "$TARGET_DIR/Sources/${APP_NAME}App.swift" << EOF
import SwiftUI
import SaneUI

@main
struct ${APP_NAME}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Settings {
            SettingsView()
        }
    }
}
EOF

# ContentView
cat > "$TARGET_DIR/Sources/ContentView.swift" << EOF
import SwiftUI
import SaneUI

struct ContentView: View {
    var body: some View {
        ZStack {
            SaneGradientBackground()

            VStack(spacing: 20) {
                Image(systemName: "app.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.teal)

                Text("Welcome to $APP_NAME")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("TODO: Build something amazing!")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
EOF

# SettingsView
cat > "$TARGET_DIR/Sources/SettingsView.swift" << EOF
import SwiftUI
import SaneUI

struct SettingsView: View {
    var body: some View {
        ZStack {
            SaneGradientBackground()

            ScrollView {
                VStack(spacing: 24) {
                    CompactSection("General", icon: "gear", iconColor: .gray) {
                        CompactRow("Version", icon: "info.circle", iconColor: .blue) {
                            Text("1.0.0")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 400)
    }
}

#Preview {
    SettingsView()
}
EOF

# Info.plist
cat > "$TARGET_DIR/$APP_NAME/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF

# Create docs/CNAME
echo "$APP_LOWER.com" > "$TARGET_DIR/docs/CNAME"

# Create appcast.xml
cat > "$TARGET_DIR/docs/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>https://$APP_LOWER.com/appcast.xml</link>
    <description>Updates for $APP_NAME</description>
    <language>en</language>
    <!-- Add items here for each release -->
  </channel>
</rss>
EOF

# Unified SaneMaster wrapper + per-project config
log_step "Creating SaneMaster wrapper..."
cat > "$TARGET_DIR/scripts/SaneMaster.rb" << 'EOF'
#!/bin/bash
set -e
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_ROOT}"
exec "${ROOT_DIR}/infra/SaneProcess/scripts/SaneMaster.rb" "$@"
EOF
chmod +x "$TARGET_DIR/scripts/SaneMaster.rb"

# Create .saneprocess manifest (single source of truth)
cat > "$TARGET_DIR/.saneprocess" << EOF
# SaneProcess compliance manifest
name: $APP_NAME
type: macos_app
scheme: $APP_NAME
project: $APP_NAME.xcodeproj
bundle_id: $BUNDLE_ID

build:
  xcodegen: true

release:
  dist_host: dist.${APP_LOWER}.com
  site_host: ${APP_LOWER}.com
  r2_bucket: sanebar-downloads
  use_sparkle: true
  min_system_version: "15.0"
  dmg:
    file_icon: Resources/DMGIcon.icns

commands:
  verify: ./scripts/SaneMaster.rb verify
  test_mode: ./scripts/SaneMaster.rb tm
  lint: ./scripts/SaneMaster.rb lint
  clean: ./scripts/SaneMaster.rb clean
  launch: ./scripts/SaneMaster.rb launch
  logs: ./scripts/SaneMaster.rb logs

docs:
  - CLAUDE.md
  - README.md
  - DEVELOPMENT.md
  - ARCHITECTURE.md
  - SESSION_HANDOFF.md

mcps:
  - apple-docs
  - context7
  - github
  - xcode
  - macos-automator

website: true
website_domain: ${APP_LOWER}.com
EOF

# Summary
echo ""
log_info "=========================================="
log_info "Setup complete for $APP_NAME!"
log_info "=========================================="
echo ""
echo "Next steps:"
echo "  1. cd $TARGET_DIR"
echo "  2. xcodegen generate"
echo "  3. open $APP_NAME.xcodeproj"
echo "  4. Search for 'TODO:' and complete customizations"
echo "  5. Create GitHub repo: gh repo create sane-apps/$APP_NAME --public"
echo "  6. Buy domain: $APP_LOWER.com"
echo "  7. Add GitHub secrets for CI/CD"
echo ""
echo "Checklist:"
echo "  [ ] Update README.md description"
echo "  [ ] Update PRIVACY.md with permissions"
echo "  [ ] Update SECURITY.md with security model"
echo "  [ ] Add Sparkle EdDSA key to project.yml"
echo "  [ ] Create app icon in Resources/Assets.xcassets"
echo "  [ ] Build and test locally"
echo "  [ ] Create first release"
echo ""
