#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 适用于超低内存环境（32-64MB）

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222         # 自适应端口
# 可通过环境变量覆盖下面这些值，例如: AUTH_PASSWORD=xxx SNI=example.com ./hy2.sh 443
AUTH_PASSWORD="${AUTH_PASSWORD:-ieshare2025}"   # 建议修改为复杂密码（可通过环境变量覆盖）
CERT_FILE="${CERT_FILE:-cert.pem}"
KEY_FILE="${KEY_FILE:-key.pem}"
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"
# 可选：预先指定 HYSTERIA 二进制的期望 SHA256 值以便校验（可通过环境变量 HYSTERIA_SHA256 设置）
HYSTERIA_SHA256="${HYSTERIA_SHA256:-}"
# 若设置为 1 则脚本会在当前目录生成一个 systemd unit 模板文件 `hysteria.service`（不会自动安装）
GENERATE_SYSTEMD="${GENERATE_SYSTEMD:-0}"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（Shell 版）"
echo "支持命令行端口参数，如：bash hysteria2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# 打印当前生效配置（敏感信息已部分隐藏）
echo "当前配置: HYSTERIA_VERSION=${HYSTERIA_VERSION}, PORT_VAR_DEFAULT=${DEFAULT_PORT}, SNI=${SNI}, ALPN=${ALPN}"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 简单端口校验 ----------
if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
    echo "❌ 端口不合法: $SERVER_PORT（必须是 1-65535 的整数）"
    exit 1
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 检测系统内存并调整参数 ----------
# 获取总内存（MB），只在 Linux 上可用
MEM_MB=0
if [ -r /proc/meminfo ]; then
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)
    MEM_MB=$((MEM_KB/1024))
fi
echo "🖥️  检测到系统内存: ${MEM_MB} MB"

# 根据内存调整 QUIC 和运行时限制（用于 512MB 场景的更保守设置）
if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 512 ]; then
    echo "⚙️  低内存环境（<=512MB），应用保守内存配置"
    MAX_CONCURRENT_STREAMS=2
    INITIAL_STREAM_RECEIVE_WINDOW=32768
    MAX_STREAM_RECEIVE_WINDOW=65536
    INITIAL_CONN_RECEIVE_WINDOW=65536
    MAX_CONN_RECEIVE_WINDOW=131072
    # Go 运行时内存上限建议（如果二进制使用 Go >=1.19，则会生效）
    GOMEMLIMIT_DEFAULT="256M"
else
    MAX_CONCURRENT_STREAMS=4
    INITIAL_STREAM_RECEIVE_WINDOW=65536
    MAX_STREAM_RECEIVE_WINDOW=131072
    INITIAL_CONN_RECEIVE_WINDOW=131072
    MAX_CONN_RECEIVE_WINDOW=262144
    GOMEMLIMIT_DEFAULT="512M"
fi

# 允许通过环境变量覆盖 GOMEMLIMIT
GOMEMLIMIT="${GOMEMLIMIT:-$GOMEMLIMIT_DEFAULT}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    # 使用 --fail 以便在 4xx/5xx 时返回非0，避免写入错误页面
        if ! curl -fL --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"; then
                echo "❌ 下载失败: $URL"
                [ -f "$BIN_PATH" ] && rm -f "$BIN_PATH"
                exit 1
        fi
        chmod +x "$BIN_PATH"

        # ---------- 可选 SHA256 校验 ----------
        EXPECTED_SHA=""
        # 优先使用环境变量 HYSTERIA_SHA256
        if [ -n "$HYSTERIA_SHA256" ]; then
            EXPECTED_SHA="$HYSTERIA_SHA256"
        else
            # 尝试拉取旁边的 .sha256 文件（如果 release 提供）
            if curl -sSf --connect-timeout 10 "${URL}.sha256" -o /tmp/hysteria.sha256.tmp 2>/dev/null; then
                EXPECTED_SHA=$(awk '{print $1}' /tmp/hysteria.sha256.tmp || true)
                rm -f /tmp/hysteria.sha256.tmp
            fi
        fi

        if [ -n "$EXPECTED_SHA" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                CALC_SHA=$(sha256sum "$BIN_PATH" | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                CALC_SHA=$(shasum -a 256 "$BIN_PATH" | awk '{print $1}')
            else
                echo "⚠️ 无法校验 SHA256（缺少 sha256sum 或 shasum），跳过校验。"
                CALC_SHA=""
            fi

            if [ -n "$CALC_SHA" ]; then
                if [ "$CALC_SHA" != "$EXPECTED_SHA" ]; then
                    echo "❌ 校验失败：下载的二进制 SHA256 与期望不匹配。"
                    rm -f "$BIN_PATH"
                    exit 1
                else
                    echo "✅ SHA256 校验通过"
                fi
            fi
        else
            echo "⚠️ 未提供 SHA256 值，跳过二进制完整性校验。可设置环境变量 HYSTERIA_SHA256 以启用。"
        fi

        echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    # 尝试使用 -addext 生成带 subjectAltName 的证书（部分 openssl 版本支持）
    if openssl req -help 2>&1 | grep -q addext; then
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" \
            -addext "subjectAltName = DNS:${SNI}"
    else
        # 若不支持 -addext，则降级为不包含 SAN 的生成（兼容旧版 openssl）
        echo "⚠️ 当前 openssl 不支持 -addext，生成的证书不包含 subjectAltName（某些客户端可能警告）。"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    fi
    echo "✅ 证书生成成功: $CERT_FILE / $KEY_FILE"
}

# ---------- 写配置文件 ----------
write_config() {
        # 先写入临时文件，确保原子替换
        tmpcfg=$(mktemp /tmp/hysteria_server_yaml.XXXXXX) || tmpcfg="./server.yaml.tmp"
cat > "$tmpcfg" <<EOF
listen: ":${SERVER_PORT}"
tls:
    cert: "$(pwd)/${CERT_FILE}"
    key: "$(pwd)/${KEY_FILE}"
    alpn:
        - "${ALPN}"
auth:
    type: "password"
    password: "${AUTH_PASSWORD}"
bandwidth:
    up: "200mbps"
    down: "200mbps"
quic:
    max_idle_timeout: "10s"
    max_concurrent_streams: ${MAX_CONCURRENT_STREAMS}
    initial_stream_receive_window: ${INITIAL_STREAM_RECEIVE_WINDOW}
    max_stream_receive_window: ${MAX_STREAM_RECEIVE_WINDOW}
    initial_conn_receive_window: ${INITIAL_CONN_RECEIVE_WINDOW}
    max_conn_receive_window: ${MAX_CONN_RECEIVE_WINDOW}
EOF
        mv -f "$tmpcfg" ./server.yaml
        echo "✅ 写入配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}, ALPN=${ALPN}）。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://api.ipify.org || true)
    # 若无法获取公网 IP，则返回空字符串，调用方可提示手动填写
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（极简优化版）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
        if [ -z "$IP" ]; then
            echo "   🌐 IP地址: 未检测到（请手动填写服务器公网 IP）"
        else
            echo "   🌐 IP地址: $IP"
        fi
    echo "   🔌 端口: $SERVER_PORT"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
        if [ -z "$IP" ]; then
            echo "hysteria2://${AUTH_PASSWORD}@YOUR_SERVER_IP:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Bing"
        else
            echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Bing"
        fi
    echo ""
    echo "📄 客户端配置文件:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
        # 检查依赖
        for cmd in curl openssl; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "❌ 需要命令不存在: $cmd 。请先安装后重试。"; exit 1
            fi
        done

        # 如果密码仍为默认，打印警告但不交互（保持一键无交互部署）
        if [ "${AUTH_PASSWORD}" = "ieshare2025" ]; then
            echo "⚠️ 警告: 当前使用默认密码 'ieshare2025'（强烈建议通过环境变量 AUTH_PASSWORD 提供强密码）。"
        fi

        download_binary
        ensure_cert
        write_config
        SERVER_IP=$(get_server_ip)
        print_connection_info "$SERVER_IP"
        echo "🚀 启动 Hysteria2 服务器..."
        # 在启动前设置 Go 运行时内存限制（若二进制在 Go >=1.19 上构建则生效）
        export GOMEMLIMIT="$GOMEMLIMIT"
        export GOGC="${GOGC:-100}"

        # 可选：在当前目录生成 systemd 单元模板（不会自动安装）
        if [ "${GENERATE_SYSTEMD}" = "1" ]; then
            unitfile="./hysteria.service"
            cat > "$unitfile" <<UNIT
[Unit]
Description=Hysteria2 Server (generated)
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
Environment=GOMEMLIMIT=${GOMEMLIMIT}
ExecStart=$(pwd)/${BIN_NAME} server -c $(pwd)/server.yaml
Restart=on-failure
RestartSec=5
TimeoutStartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
            # 若内存较小，建议在 unit 中加入 MemoryMax 限制以防 OOM
            if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 512 ]; then
                echo "# 建议: 将下面一行复制到 /etc/systemd/system/hysteria.service 的 [Service] 段以限制内存"
                echo "# MemoryMax=400M"
            fi
            echo "✅ 已在当前目录生成 systemd 单元模板: $unitfile"
            echo "要安装到 systemd，请运行：sudo mv $unitfile /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now hysteria.service"
        fi

        exec "$BIN_PATH" server -c server.yaml
}

main "$@"




