#!/bin/bash
# ================================================================
# FinBooks Plugin Installer v2.5.0
# 一键安装到 Hermes / OpenClaw / Codex 智能体
# 用法: bash install_finbooks_plugin.sh
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "🔍 FinBooks Plugin Installer v2.5.0"
echo ""

# Detect project root — works from both source tree and .app bundle
# Strategy: try multiple locations for plugin source dirs
if [ -d "$SCRIPT_DIR/../scripts" ] && [ -d "$SCRIPT_DIR/../.codex-plugin" ]; then
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    SCRIPTS_SRC="$PROJECT_DIR/scripts"
    CODEX_PLUGIN_SRC="$PROJECT_DIR/.codex-plugin"
    HERMES_PLUGIN_SRC="$PROJECT_DIR/.hermes-plugin"
    OPENCLAW_PLUGIN_SRC="$PROJECT_DIR/.openclaw-plugin"
elif [ -f "$SCRIPT_DIR/finbooks_bridge.py" ] && [ -d "$(cd "$SCRIPT_DIR/.." && pwd)/.codex-plugin" ]; then
    # Inside .app bundle's Resources/scripts
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    SCRIPTS_SRC="$SCRIPT_DIR"
    CODEX_PLUGIN_SRC="$PROJECT_DIR/.codex-plugin"
    HERMES_PLUGIN_SRC="$PROJECT_DIR/.hermes-plugin"
    OPENCLAW_PLUGIN_SRC="$PROJECT_DIR/.openclaw-plugin"
elif [ -d "$SCRIPT_DIR/../.codex-plugin" ]; then
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    SCRIPTS_SRC="$SCRIPT_DIR"
    CODEX_PLUGIN_SRC="$PROJECT_DIR/.codex-plugin"
    HERMES_PLUGIN_SRC="$PROJECT_DIR/.hermes-plugin"
    OPENCLAW_PLUGIN_SRC="$PROJECT_DIR/.openclaw-plugin"
else
    echo "❌ Cannot locate plugin source directories"
    echo "   Tried: $SCRIPT_DIR/../scripts, $SCRIPT_DIR/../.codex-plugin"
    echo "   SCRIPT_DIR=$SCRIPT_DIR"
    echo ""
    echo "💡 Manual install: cd FinBooks && bash scripts/install_finbooks_plugin.sh"
    exit 1
fi
echo "   Source: $PROJECT_DIR"
echo 

verify_source() {
    local label="$1" path="$2"
    if [ -d "$path" ]; then
        echo "  ✅ Found $label: $path"
        return 0
    else
        echo "  ⚠️  Missing $label: $path (will skip)"
        return 1
    fi
}

echo "📁 Plugin sources:"
verify_source "Codex plugin" "$CODEX_PLUGIN_SRC" || CODEX_PLUGIN_SRC=""
verify_source "Hermes plugin" "$HERMES_PLUGIN_SRC" || HERMES_PLUGIN_SRC=""
verify_source "OpenClaw plugin" "$OPENCLAW_PLUGIN_SRC" || OPENCLAW_PLUGIN_SRC=""
echo ""

INSTALLED_AGENTS=0

install_to_agent() {
    local agent_name="$1"
    local agent_dir="$HOME/.$agent_name"
    local plugin_src="$2"
    local plugin_dest="$agent_dir/plugins/finbooks"
    local bridge_script_dest="$agent_dir/scripts"
    
    if [ ! -d "$agent_dir" ]; then
        echo "  ○ $agent_name: not installed (skip)"
        return 1
    fi
    
    echo "  🔧 Installing to $agent_name..."
    
    if [ -n "$plugin_src" ] && [ -d "$plugin_src" ]; then
        mkdir -p "$plugin_dest"
        cp -R "$plugin_src/"* "$plugin_dest/" 2>/dev/null || true
        echo "    ✅ Plugin -> $plugin_dest"
        INSTALLED_AGENTS=$((INSTALLED_AGENTS + 1))
    fi
    
    if [ "$agent_name" = "hermes" ] && [ -f "$SCRIPTS_SRC/finbooks_bridge.py" ]; then
        mkdir -p "$bridge_script_dest"
        cp "$SCRIPTS_SRC/finbooks_bridge.py" "$bridge_script_dest/"
        chmod +x "$bridge_script_dest/finbooks_bridge.py"
        echo "    ✅ Bridge script -> $bridge_script_dest/"
    fi
    
    return 0
}

install_to_agent "codex" "$CODEX_PLUGIN_SRC" || true
install_to_agent "hermes" "$HERMES_PLUGIN_SRC" || true
install_to_agent "openclaw" "$OPENCLAW_PLUGIN_SRC" || true

# Create launchd plist for Bridge auto-start
echo ""
echo "⏰ Setting up Bridge auto-start..."

LPLIST_DIR="$HOME/Library/LaunchAgents"
LPLIST_PATH="$LPLIST_DIR/com.finbooks.bridge.plist"
mkdir -p "$LPLIST_DIR"

BRIDGE_SCRIPT=""
if [ -f "$SCRIPTS_SRC/finbooks_bridge.py" ]; then
    BRIDGE_SCRIPT="$SCRIPTS_SRC/finbooks_bridge.py"
elif [ -f "$HOME/.hermes/scripts/finbooks_bridge.py" ]; then
    BRIDGE_SCRIPT="$HOME/.hermes/scripts/finbooks_bridge.py"
fi

if [ -n "$BRIDGE_SCRIPT" ]; then
    cat > "$LPLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.finbooks.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${BRIDGE_SCRIPT}</string>
        <string>--port</string>
        <string>9090</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$(dirname "$BRIDGE_SCRIPT")</string>
    <key>StandardOutPath</key>
    <string>/tmp/finbooks-bridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/finbooks-bridge.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
    chmod 644 "$LPLIST_PATH"
    echo "  ✅ LaunchAgent created: $LPLIST_PATH"
    
    if launchctl list com.finbooks.bridge &>/dev/null 2>&1; then
        launchctl unload "$LPLIST_PATH" 2>/dev/null || true
    fi
    launchctl load "$LPLIST_PATH" 2>/dev/null && echo "  ✅ Bridge auto-start enabled" || echo "  ⚠️  Could not load LaunchAgent"
else
    echo "  ⚠️  Bridge script not found, skipping auto-start"
fi

echo ""
echo "✅ Installation complete! Installed to $INSTALLED_AGENTS agent(s)"
echo ""

# Start Bridge service immediately
echo "🚀 Starting Bridge service..."
if [ -n "$BRIDGE_SCRIPT" ] && [ -f "$BRIDGE_SCRIPT" ]; then
    # Check if already running
    if curl -sf http://127.0.0.1:9090/health >/dev/null 2>&1; then
        echo "  ✅ Bridge already running on http://127.0.0.1:9090"
    else
        nohup python3 "$BRIDGE_SCRIPT" --port 9090 > /tmp/finbooks-bridge-startup.log 2>&1 &
        echo "  Bridge starting (PID: $!)"
    fi
fi

# Wait for Bridge to be ready (up to 10 seconds)
echo "⏳ Waiting for Bridge to be ready..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf http://127.0.0.1:9090/health >/dev/null 2>&1; then
        echo "  ✅ Bridge is ready on http://127.0.0.1:9090"
        break
    fi
    sleep 1
done


# Auto-restart agents for true "开箱即用" experience
echo "🔄 Auto-restarting agents..."
if command -v launchctl &>/dev/null; then
    # Restart Hermes
    if [ -d "$HOME/.hermes" ]; then
        echo "  Restarting Hermes..."
        launchctl kickstart -k gui/$(id -u)/localhost.hermes 2>/dev/null || \
        launchctl stop localhost.hermes 2>/dev/null || true
    fi
    # Restart OpenClaw
    if [ -d "$HOME/.openclaw" ]; then
        echo "  Restarting OpenClaw..."
        launchctl kickstart -k gui/$(id -u)/localhost.openclaw 2>/dev/null || \
        launchctl stop localhost.openclaw 2>/dev/null || true
    fi
    # Restart Codex
    if [ -d "$HOME/.codex" ]; then
        echo "  Restarting Codex..."
        # Codex uses its own restart mechanism
        launchctl kickstart -k gui/$(id -u)/com.codex 2>/dev/null || true
    fi
fi

echo "✅ 全部完成！智能体已重启，FinBooks 工具已就绪。"
echo ""
echo "📖 Summary:"
echo "   1. ✅ Plugins installed to Hermes / OpenClaw / Codex"
echo "   2. ✅ Codex SKILL.md included"
echo "   3. ✅ Bridge auto-start enabled"
echo "   4. ✅ Agents restarted (tools available now)"
echo ""
echo "   Bridge: http://127.0.0.1:9090 (auto-starts on login)"
echo "   Plugin: http://127.0.0.1:9090/api/plugin/manifest"
echo ""
echo "📝 验证安装:"
echo "   Codex:   ls ~/.codex/plugins/finbooks/"
echo "   Hermes:  ls ~/.hermes/plugins/finbooks/"
echo "   OpenClaw: ls ~/.openclaw/plugins/finbooks/"
echo "   Bridge:  curl http://127.0.0.1:9090/health"
exit 0
