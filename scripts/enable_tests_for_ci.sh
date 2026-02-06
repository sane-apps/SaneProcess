#!/bin/bash
# Enable test targets for CI builds
# This script temporarily re-enables tests in project.yml for CI environments
# Auto-detects project name from git root directory

set -e

PROJECT_NAME="${1:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
PROJECT_YML="project.yml"
BACKUP_YML="project.yml.ci_backup"

# Backup original project.yml
if [ ! -f "$BACKUP_YML" ]; then
    cp "$PROJECT_YML" "$BACKUP_YML"
fi

# Re-enable test targets in project.yml using Python for reliability
echo "🔧 Enabling test targets for CI ($PROJECT_NAME)..."

python3 - "$PROJECT_NAME" << 'PYTHON_SCRIPT'
import sys

project = sys.argv[1]

with open('project.yml', 'r') as f:
    lines = f.readlines()

output = []
i = 0
while i < len(lines):
    line = lines[i]

    # Re-enable in build section
    if f'# {project}Tests: [test]' in line:
        output.append(f'        {project}Tests: [test]\n')
        i += 1
        continue

    # Re-enable in test section
    if 'test:' in line and i + 1 < len(lines):
        output.append(line)
        i += 1
        # Skip comment lines and empty targets
        while i < len(lines) and ('# Temporarily' in lines[i] or
                                   '# This is a known' in lines[i] or
                                   '# Re-enable' in lines[i] or
                                   'targets: []' in lines[i] or
                                   '# targets:' in lines[i]):
            i += 1
        # Add actual targets
        output.append('      targets:\n')
        output.append(f'        - {project}Tests\n')
        output.append(f'        - {project}UITests\n')
        # Skip remaining commented target lines
        while i < len(lines) and (f'#   - {project}' in lines[i] or lines[i].strip() == ''):
            i += 1
        continue

    output.append(line)
    i += 1

with open('project.yml', 'w') as f:
    f.writelines(output)

PYTHON_SCRIPT

echo "✅ Test targets enabled. Regenerating Xcode project..."
xcodegen generate

echo "✅ Ready for CI test execution"
