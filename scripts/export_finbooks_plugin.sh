#!/bin/bash
# ======================================================================
# FinBooks Plugin Exporter v1.0
# ======================================================================
# 将 FinBooks 打包为可在其他机器/用户安装的插件包
# 输出: ./dist/finbooks-plugin-v{VERSION}.zip
#
# 用法:
#   bash export_finbooks_plugin.sh
#   bash export_finbooks_plugin.sh --output /path/to/output
# ======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${1:-$PROJECT_DIR/dist}"
# Auto-read version from plugin.json (fallback 2.5.0)
_plugin_json="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.codex-plugin/plugin.json"
if [ -f "$_plugin_json" ]; then
    VERSION=$(python3 -c "import json; print(json.load(open('$_plugin_json'))['version'])" 2>/dev/null || echo "2.5.0")
else
    VERSION="2.5.0"
fi
OUTPUT_NAME="finbooks-plugin-v${VERSION}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   FinBooks Plugin Exporter v1.0             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 创建临时工作目录
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo "  Project: $PROJECT_DIR"
echo "  Output:  $DIST_DIR/${OUTPUT_NAME}.zip"
echo "  Version: $VERSION"
echo ""

# ── 1. 收集插件文件 ────────────────────────────────────────────────
PLUGIN_DIR="$TMP_DIR/finbooks-plugin"

mkdir -p "$PLUGIN_DIR/hermes"
mkdir -p "$PLUGIN_DIR/openclaw"
mkdir -p "$PLUGIN_DIR/codex"
mkdir -p "$PLUGIN_DIR/scripts"

echo "  [1/4] 收集插件文件..."

# Hermes 插件
cp "$PROJECT_DIR/.hermes-plugin/plugin.yaml" "$PLUGIN_DIR/hermes/"
cp "$PROJECT_DIR/.hermes-plugin/__init__.py" "$PLUGIN_DIR/hermes/"

# OpenClaw 插件
cp "$PROJECT_DIR/.openclaw-plugin/plugin.yaml" "$PLUGIN_DIR/openclaw/"
cp "$PROJECT_DIR/.openclaw-plugin/__init__.py" "$PLUGIN_DIR/openclaw/"

# Codex 插件
cp "$PROJECT_DIR/.codex-plugin/plugin.json" "$PLUGIN_DIR/codex/"
cp "$PROJECT_DIR/.codex-plugin/SKILL.md" "$PLUGIN_DIR/codex/"

# Bridge 脚本
cp "$PROJECT_DIR/scripts/finbooks_bridge.py" "$PLUGIN_DIR/scripts/"

# 安装脚本
cp "$PROJECT_DIR/scripts/install_finbooks_plugin.sh" "$PLUGIN_DIR/"

echo "  ✓ 文件已收集"

# ── 2. 创建一键安装脚本 ────────────────────────────────────────────
cat > "$PLUGIN_DIR/install.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
# FinBooks 插件一键安装脚本（Standalone 包 —— 真正的开箱即用）
# ================================================================
# 用法: bash install.sh
# 功能:
#   1. 自动检测本机的 Hermes / OpenClaw / Codex 智能体
#   2. 安装 FinBooks 插件到所有检测到的智能体
#   3. 创建 Bridge 开机自启服务 (launchd)
#   4. 即刻启动 Bridge 服务
#   5. 重启受影响的智能体
# ================================================================

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   FinBooks Plugin Installer (Standalone)    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  安装目录: $PLUGIN_DIR"
echo ""

# ── 1. 检测智能体 ────────────────────────────────────────────────
INSTALLED_COUNT=0

install_to_agent() {
    local agent_name="$1"
    local agent_dir="$HOME/.$agent_name"
    local plugin_src="$PLUGIN_DIR/$agent_name"
    local plugin_dest="$agent_dir/plugins/finbooks"

    if [ ! -d "$agent_dir" ]; then
        echo "  ○ $agent_name: 未检测到 (跳过)"
        return 1
    fi

    echo "  🔧 安装到 $agent_name..."
    mkdir -p "$plugin_dest"
    if [ -d "$plugin_src" ]; then
        cp -R "$plugin_src/"* "$plugin_dest/" 2>/dev/null || true
        echo "    ✅ 插件 -> $plugin_dest"
    fi

    # Hermes 额外需要 Bridge 脚本
    if [ "$agent_name" = "hermes" ] && [ -f "$PLUGIN_DIR/scripts/finbooks_bridge.py" ]; then
        local bridge_dest="$agent_dir/scripts"
        mkdir -p "$bridge_dest"
        cp "$PLUGIN_DIR/scripts/finbooks_bridge.py" "$bridge_dest/"
        chmod +x "$bridge_dest/finbooks_bridge.py"
        echo "    ✅ Bridge 脚本 -> $bridge_dest/"
    fi

    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    return 0
}

install_to_agent "codex" || true
install_to_agent "hermes" || true
install_to_agent "openclaw" || true

# ── 2. 创建 launchd 自启服务 ──────────────────────────────────────
echo ""
echo "⏰ 配置 Bridge 开机自启..."

LPLIST_DIR="$HOME/Library/LaunchAgents"
LPLIST_PATH="$LPLIST_DIR/com.finbooks.bridge.plist"
mkdir -p "$LPLIST_DIR"

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
        <string>$(find "$PLUGIN_DIR" -name finbooks_bridge.py -type f | head -1)</string>
        <string>--port</string>
        <string>9090</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$PLUGIN_DIR/scripts</string>
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
echo "  ✅ LaunchAgent: $LPLIST_PATH"

launchctl unload "$LPLIST_PATH" 2>/dev/null || true
if launchctl load "$LPLIST_PATH" 2>/dev/null; then
    echo "  ✅ Bridge 开机自启已启用"
fi

echo ""

# ── 3. 即刻启动 Bridge（如果还没运行） ──────────────────────────
echo ""
echo "🚀 启动 Bridge 服务..."
if command -v curl &>/dev/null; then
    if curl -sf http://127.0.0.1:9090/health >/dev/null 2>&1; then
        echo "  ✅ Bridge 已在运行 (localhost:9090)"
    else
        launchctl start com.finbooks.bridge 2>/dev/null || true
        echo "  ⏳ 等待 Bridge 启动..."
        for i in 1 2 3 4 5; do
            sleep 1
            if curl -sf http://127.0.0.1:9090/health >/dev/null 2>&1; then
                echo "  ✅ Bridge 已启动 (localhost:9090)"
                break
            fi
        done
    fi
fi

# ── 4. 重启智能体 ──────────────────────────────────────────────
echo ""
echo "🔄 重启智能体..."
if command -v launchctl &>/dev/null; then
    for agent in hermes openclaw codex; do
        if [ -d "$HOME/.$agent" ]; then
            launchctl kickstart -k "gui/$(id -u)/localhost.$agent" 2>/dev/null ||             launchctl stop "localhost.$agent" 2>/dev/null || true
            echo "  ✅ $agent 已重启"
        fi
    done
fi

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  ✅ FinBooks 插件安装完成！                          │"
echo "│                                                     │"
echo "│  安装到 $INSTALLED_COUNT 个智能体                     │"
echo "│  Bridge 运行于 http://127.0.0.1:9090                │"
echo "│  开机自启: 已启用                                    │"
echo "│                                                     │"
echo "│  💡 现在可以直接在智能体对话中使用财务工具了！        │"
echo "└─────────────────────────────────────────────────────┘"
INSTALL_SCRIPT

echo "  [2/4] 安装脚本已创建"

# ── 3. 创建 README ────────────────────────────────────────────────
cat > "$PLUGIN_DIR/README.md" << 'README_EOF'
# FinBooks Plugin Package v{VERSION}

AI 财务管理系统 — 支持会计凭证、三大报表、增值税申报、固定资产管理、银行对账。

## 安装方式

### 方式一：一键安装（推荐）
```bash
bash install.sh
```

### 方式二：手动安装
```bash
# 启动 Bridge 服务
python3 scripts/finbooks_bridge.py
```

## 系统要求
- Python 3.8+
- macOS / Linux
- Hermes Agent / OpenClaw Agent / Codex Desktop（任选其一）

## 功能
- 凭证管理（创建/过账/审核）
- 三大报表（资产负债表、利润表、现金流量表）
- 增值税申报表
- 固定资产管理（含折旧计提）
- 银行对账
- 异常检测
- 审计日志
- CSV 导出（税务/审计用）

## 更多
- 详细文档: https://github.com/your-repo/finbooks
README_EOF

echo "  [3/4] README 已创建"

# ── 4. 打包 ────────────────────────────────────────────────────────
mkdir -p "$DIST_DIR"
cd "$TMP_DIR"
zip -r "$DIST_DIR/${OUTPUT_NAME}.zip" "finbooks-plugin/" > /dev/null 2>&1
cd "$PROJECT_DIR"

echo "  [4/4] 打包完成"
echo ""
echo "  ✅ 插件包已创建: $DIST_DIR/${OUTPUT_NAME}.zip"
echo "     大小: $(du -h "$DIST_DIR/${OUTPUT_NAME}.zip" | cut -f1)"
echo ""
echo "  分发方式:"
echo "    • 直接复制到目标机器后解压运行 install.sh"
echo "    • 或上传到共享存储供团队下载"
echo ""
