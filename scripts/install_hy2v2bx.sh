#!/bin/bash
set -e

WORKSPACE=/root/hysteria2-v2bx
SERVICE_NAME=hysteria2-v2bx
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${WORKSPACE}/server.yaml"
CERT_DIR=/etc/hysteria2-v2bx
BINARY_NAME=hysteria
BINARY_PATH=/usr/local/bin/hysteria2-v2bx
SCRIPT_PATH="/usr/local/bin/hy2v2bx"
GITHUB_REPO="FireinRainLab/hysteria2-v2bx"
SCRIPT_VERSION="v1.1"
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/master/scripts/install_hy2v2bx.sh"
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

print_success() {
    echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $1"
}

print_warning() {
    echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}[✗]${COLOR_RESET} $1"
}

print_info() {
    echo -e "${COLOR_BLUE}[i]${COLOR_RESET} $1"
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

get_latest_version() {
    curl -m 10 -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g'
}

download_binary() {
    local version=$1
    local arch=$2
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${BINARY_NAME}-linux-${arch}"

    print_info "下载地址: $download_url"
    print_info "正在下载 hysteria2-v2bx $version ($arch)..."

    if ! wget --no-check-certificate -qO "${WORKSPACE}/${BINARY_NAME}" "$download_url"; then
        print_error "下载失败，请检查版本号或网络连接"
        exit 1
    fi

    chmod +x "${WORKSPACE}/${BINARY_NAME}"
    mv "${WORKSPACE}/${BINARY_NAME}" "$BINARY_PATH"
    print_success "下载完成"
}

create_service_file() {
    print_info "创建 systemd 服务配置..."
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=hysteria2-v2bx - 基于 v2board 的 Hysteria2 代理服务
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/root/hysteria2-v2bx
ExecStart=/usr/local/bin/hysteria2-v2bx server -c /root/hysteria2-v2bx/server.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    print_success "服务配置创建完成"
}

create_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "配置文件已存在，跳过创建"
        return 0
    fi

    print_info "创建配置文件..."
    cat > "$CONFIG_FILE" << 'EOF'
v2board:
  apiHost: <请输入自己的apiHost地址>
  apiKey: <请输入自己的apiKey>
  nodeID: <请输入自己的nodeID>
tls:
  type: tls
  cert: /etc/hysteria2-v2bx/server.crt
  key: /etc/hysteria2-v2bx/server.key
auth:
  type: v2board
trafficStats:
  listen: 127.0.0.1:7653
# 如果需要设置warp分流，需要开启outbounds配置
# 并且在acl中添加warp路由规则,请自行决定是否开启
#outbounds:
#  - name: proxy
#    type: socks5
#    socks5:
#      addr: 127.0.0.1:40000
acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
    - reject(fc00::/7)
    #- proxy(geosite:google)
    #- proxy(geoip:google)
masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF
    print_success "配置文件创建完成: $CONFIG_FILE"
    print_warning "请编辑配置文件，填写 v2board 相关信息"
}

generate_ssl_cert() {
    if [ -f "${CERT_DIR}/server.crt" ] && [ -f "${CERT_DIR}/server.key" ]; then
        print_warning "SSL 证书已存在，跳过生成"
        return 0
    fi

    print_info "生成自签名 SSL 证书..."
    mkdir -p "$CERT_DIR"

    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.crt" \
        -subj "/CN=bing.com" \
        -days 36500 2>/dev/null

    chown root:root "${CERT_DIR}/server.key" "${CERT_DIR}/server.crt"
    chmod 600 "${CERT_DIR}/server.key"
    chmod 644 "${CERT_DIR}/server.crt"
    print_success "SSL 证书生成完成"
}

install() {
    echo ""
    print_info "===== Hysteria2-v2bx 安装 ====="
    echo ""

    mkdir -p "$WORKSPACE"

    local arch
    arch=$(get_arch)
    print_info "检测到架构: $arch"

    print_info "获取最新版本..."
    local latest_version
    latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        print_error "获取版本号失败"
        exit 1
    fi
    print_info "最新版本: $latest_version"

    download_binary "$latest_version" "$arch"
    create_service_file
    create_config_file
    generate_ssl_cert
    install_script_symlink

    print_info "重新加载 systemd..."
    systemctl daemon-reload

    print_info "启动服务..."
    systemctl enable "${SERVICE_NAME}.service"
    systemctl start "${SERVICE_NAME}.service"

    echo ""
    print_success "===== 安装完成 ====="
    echo ""
    print_info "重要提示："
    echo "  1. 编辑配置文件: $CONFIG_FILE"
    echo "  2. 填写 v2board 的 apiHost、apiKey、nodeID"
    echo "  3. 重启服务: systemctl restart ${SERVICE_NAME}"
    echo "  4. 查看状态: systemctl status ${SERVICE_NAME}"
    echo "  5. 任意位置输入 hy2v2bx 进入维护脚本"
    echo ""
}

install_script_symlink() {
    print_info "安装 hy2v2bx 命令到系统..."

    local script_dir
    script_dir=$(dirname "$(readlink -f "$0")")
    local source_script="${script_dir}/install_hy2v2bx.sh"

    if [ -f "$source_script" ]; then
        cp "$source_script" "$SCRIPT_PATH"
    else
        cp "$0" "$SCRIPT_PATH"
    fi

    chmod +x "$SCRIPT_PATH"
    print_success "hy2v2bx 命令已安装到 $SCRIPT_PATH"
}

self_update() {
    echo ""
    print_info "===== 脚本自更新 ====="
    echo ""

    print_info "当前脚本版本: $SCRIPT_VERSION"
    print_info "下载最新脚本..."

    local temp_script
    temp_script=$(mktemp /tmp/hy2v2bx_script_XXXXXX.sh)

    if ! curl -fsSL -o "$temp_script" "$SCRIPT_URL"; then
        print_error "下载脚本失败"
        rm -f "$temp_script"
        return 1
    fi

    if ! bash -n "$temp_script"; then
        print_error "下载的脚本语法检查失败"
        rm -f "$temp_script"
        return 1
    fi

    print_info "备份旧版本..."
    if [ -f "$SCRIPT_PATH" ]; then
        cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak"
    fi

    if [ -f "${SCRIPT_PATH}.bak" ]; then
        local old_version
        old_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "${SCRIPT_PATH}.bak" 2>/dev/null || echo "unknown")
        print_info "旧版本: $old_version"
    fi

    cp "$temp_script" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    rm -f "$temp_script"

    local new_version
    new_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$SCRIPT_PATH" 2>/dev/null || echo "unknown")
    print_info "新版本: $new_version"

    echo ""
    print_success "===== 脚本更新完成 ====="
    print_info "$SCRIPT_VERSION -> $new_version"
    echo ""

    if [ "$new_version" != "unknown" ] && [ "$new_version" != "$SCRIPT_VERSION" ]; then
        print_info "检测到版本变化，重新启动..."
        exec "$SCRIPT_PATH" "$@"
    fi
}

uninstall() {
    echo ""
    print_warning "===== Hysteria2-v2bx 卸载 ====="
    echo ""

    read -r -p "确定要卸载 hysteria2-v2bx 吗？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        print_info "取消卸载"
        return 0
    fi

    print_info "停止服务..."
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

    print_info "删除服务配置..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    print_info "删除二进制文件..."
    rm -f "$BINARY_PATH"

    print_info "删除 hy2v2bx 命令..."
    rm -f "$SCRIPT_PATH"

    read -r -p "是否保留配置文件和证书？(Y/n): " keep_config
    if [ "$keep_config" = "n" ] || [ "$keep_config" = "N" ]; then
        print_info "删除配置文件..."
        rm -rf "$WORKSPACE"
        rm -rf "$CERT_DIR"
        print_success "配置和证书已删除"
    else
        print_info "配置文件已保留在 $WORKSPACE"
    fi

    echo ""
    print_success "===== 卸载完成 ====="
    echo ""
}

update() {
    echo ""
    print_info "===== Hysteria2-v2bx 更新 ====="
    echo ""

    if [ ! -f "$BINARY_PATH" ]; then
        print_error "未检测到已安装的 hysteria2-v2bx，请先安装"
        return 1
    fi

    local old_version
    old_version=$("$BINARY_PATH" version 2>/dev/null | grep -oP 'Version:\s*\K\S+' || echo "unknown")
    print_info "当前版本: $old_version"

    local arch
    arch=$(get_arch)

    print_info "获取最新版本..."
    local latest_version
    latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        print_error "获取版本号失败"
        return 1
    fi
    print_info "最新版本: $latest_version"

    if [ "$old_version" = "$latest_version" ]; then
        print_success "当前已是最新版本"
        return 0
    fi

    print_info "备份旧版本..."
    cp "$BINARY_PATH" "${BINARY_PATH}.bak"

    download_binary "$latest_version" "$arch"

    print_info "重启服务..."
    systemctl restart "${SERVICE_NAME}.service"

    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        print_success "服务启动正常"
        rm -f "${BINARY_PATH}.bak"
    else
        print_error "服务启动失败，正在回滚..."
        mv "${BINARY_PATH}.bak" "$BINARY_PATH"
        systemctl restart "${SERVICE_NAME}.service"
        return 1
    fi

    echo ""
    print_success "===== 更新完成 ====="
    print_info "版本: $old_version → $latest_version"
    echo ""
}

do_start() {
    echo ""
    print_info "启动 hysteria2-v2bx 服务..."
    systemctl start "${SERVICE_NAME}.service"
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        print_success "服务已启动"
    else
        print_error "服务启动失败，请查看日志"
        systemctl status "${SERVICE_NAME}.service" --no-pager
    fi
    echo ""
}

do_stop() {
    echo ""
    print_info "停止 hysteria2-v2bx 服务..."
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        systemctl stop "${SERVICE_NAME}.service"
        print_success "服务已停止"
    else
        print_warning "服务未运行"
    fi
    echo ""
}

do_restart() {
    echo ""
    print_info "重启 hysteria2-v2bx 服务..."
    systemctl restart "${SERVICE_NAME}.service"
    sleep 1
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        print_success "服务已重启"
    else
        print_error "服务重启失败，请查看日志"
        systemctl status "${SERVICE_NAME}.service" --no-pager
    fi
    echo ""
}

do_status() {
    echo ""
    print_info "===== 服务状态 ====="
    systemctl status "${SERVICE_NAME}.service" --no-pager
    echo ""
}

view_logs() {
    echo ""
    print_info "===== 查看日志 ====="
    echo "1) 查看最近 100 行"
    echo "2) 查看最近 500 行"
    echo "3) 查看最近 1000 行"
    echo "4) 实时追踪日志"
    echo "0) 返回主菜单"
    echo ""

    read -r -p "请选择 [0-4]: " choice
    case "$choice" in
        1) journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager ;;
        2) journalctl -u "${SERVICE_NAME}.service" -n 500 --no-pager ;;
        3) journalctl -u "${SERVICE_NAME}.service" -n 1000 --no-pager ;;
        4) journalctl -u "${SERVICE_NAME}.service" -f ;;
        0) return ;;
        *) print_error "无效选择" ;;
    esac
    echo ""
}

view_config() {
    echo ""
    print_info "===== 查看配置 ====="
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件: $CONFIG_FILE"
        echo ""
        cat "$CONFIG_FILE"
    else
        print_error "配置文件不存在"
    fi
    echo ""
}

edit_config() {
    echo ""
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "配置文件不存在"
        return 1
    fi

    echo "选择编辑器:"
    echo "1) nano"
    echo "2) vi"
    echo "3) vim"
    echo "0) 返回主菜单"
    echo ""

    read -r -p "请选择 [0-3]: " choice
    case "$choice" in
        1) nano "$CONFIG_FILE" ;;
        2) vi "$CONFIG_FILE" ;;
        3) vim "$CONFIG_FILE" ;;
        0) return ;;
        *) print_error "无效选择" ;;
    esac

    if [ $? -eq 0 ]; then
        print_info "配置已更新，是否重启服务？(Y/n): "
        read -r -p "" restart
        if [ "$restart" != "n" ] && [ "$restart" != "N" ]; then
            do_restart
        fi
    fi
}

show_version() {
    echo ""
    print_info "===== 版本信息 ====="
    if [ -f "$BINARY_PATH" ]; then
        "$BINARY_PATH" version 2>/dev/null
    else
        print_error "未安装 hysteria2-v2bx"
    fi
    echo ""
}

check_system() {
    echo ""
    print_info "===== 系统检查 ====="
    echo ""

    echo -n "操作系统: "
    uname -a

    echo -n "内核版本: "
    uname -r

    echo -n "系统架构: "
    uname -m

    echo -n "可用内存: "
    free -h 2>/dev/null | grep "Mem:" | awk '{print $7 "/" $2}' || echo "未知"

    echo -n "磁盘空间: "
    df -h / | tail -1 | awk '{print $4 " 可用 / " $2 " 总计"}'

    echo ""

    echo "===== Hysteria2-v2bx 组件检查 ====="
    echo ""

    if [ -f "$BINARY_PATH" ]; then
        print_success "二进制文件: $BINARY_PATH"
        "$BINARY_PATH" version 2>/dev/null | head -1
    else
        print_error "二进制文件: 未安装"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        print_success "服务配置: $SERVICE_FILE"
    else
        print_error "服务配置: 不存在"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        print_success "配置文件: $CONFIG_FILE"
    else
        print_error "配置文件: 不存在"
    fi

    if [ -f "${CERT_DIR}/server.crt" ]; then
        print_success "SSL 证书: ${CERT_DIR}/server.crt"
    else
        print_warning "SSL 证书: 不存在"
    fi

    echo ""
    echo "===== 服务运行状态 ====="
    echo ""
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        print_success "服务状态: 运行中"
    elif systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        print_warning "服务状态: 已停止（已启用自动启动）"
    else
        print_error "服务状态: 未安装"
    fi
    echo ""
}

show_menu() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║     Hysteria2-v2bx 管理脚本 $SCRIPT_VERSION          ║"
    echo "║     基于 v2board 的 Hysteria2 代理服务      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "  安装/更新:"
    echo "   1) 安装 hysteria2-v2bx"
    echo "   2) 更新 hysteria2-v2bx"
    echo "   3) 卸载 hysteria2-v2bx"
    echo "   4) 更新管理脚本自身"
    echo ""
    echo "  服务控制:"
    echo "   5) 启动服务"
    echo "   6) 停止服务"
    echo "   7) 重启服务"
    echo "   8) 查看服务状态"
    echo ""
    echo "  日志/配置:"
    echo "   9) 查看日志"
    echo "  10) 查看配置文件"
    echo "  11) 编辑配置文件"
    echo ""
    echo "  其他:"
    echo "  12) 查看版本信息"
    echo "  13) 系统检查"
    echo "   0) 退出"
    echo ""
}

main() {
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "用法: $0 [命令]"
        echo ""
        echo "命令列表:"
        echo "  install    - 安装 hysteria2-v2bx"
        echo "  update     - 更新 hysteria2-v2bx"
        echo "  uninstall  - 卸载 hysteria2-v2bx"
        echo "  selfupdate - 更新管理脚本自身"
        echo "  start      - 启动服务"
        echo "  stop       - 停止服务"
        echo "  restart    - 重启服务"
        echo "  status     - 查看服务状态"
        echo "  logs       - 查看日志"
        echo "  config     - 查看配置"
        echo "  edit       - 编辑配置"
        echo "  version    - 查看版本"
        echo "  check      - 系统检查"
        echo ""
        echo "  无参数启动则进入交互式菜单"
        echo "  安装后可在任意位置输入 hy2v2bx 启动此脚本"
        echo ""
        exit 0
    fi

    if [ $# -gt 0 ]; then
        case "$1" in
            install)    install ;;
            update)     update ;;
            uninstall)  uninstall ;;
            selfupdate) self_update "$@" ;;
            start)      do_start ;;
            stop)       do_stop ;;
            restart)    do_restart ;;
            status)     do_status ;;
            logs)       view_logs ;;
            config)     view_config ;;
            edit)       edit_config ;;
            version)    show_version ;;
            check)      check_system ;;
            *)
                print_error "未知命令: $1"
                echo "使用 '$0 --help' 查看所有命令"
                exit 1
                ;;
        esac
        exit $?
    fi

    while true; do
        show_menu
        read -r -p "请选择操作 [0-13]: " choice

        case "$choice" in
            1)  install ;;
            2)  update ;;
            3)  uninstall ;;
            4)  self_update ;;
            5)  do_start ;;
            6)  do_stop ;;
            7)  do_restart ;;
            8)  do_status ;;
            9)  view_logs ;;
            10) view_config ;;
            11) edit_config ;;
            12) show_version ;;
            13) check_system ;;
            0)
                print_info "退出管理脚本"
                exit 0
                ;;
            *)
                print_error "无效选择，请输入 0-13"
                ;;
        esac

        echo ""
        read -r -p "按回车键继续..."
    done
}

if [ "$(id -u)" -ne 0 ]; then
    print_error "此脚本需要 root 权限运行"
    exit 1
fi

if [ ! -t 0 ] && [ $# -eq 0 ]; then
    print_warning "检测到非交互式运行方式（如 pipe 模式）"
    print_info "建议使用以下方式运行："
    echo ""
    echo "  wget -qO /tmp/hy2v2bx.sh $SCRIPT_URL"
    echo "  bash /tmp/hy2v2bx.sh"
    echo ""
    print_info "或者使用命令行参数："
    echo "  bash $0 install     # 安装"
    echo "  bash $0 update      # 更新"
    echo "  bash $0 start       # 启动服务"
    echo "  bash $0 status      # 查看状态"
    echo ""
    print_info "将自动执行 install 命令..."
    echo ""
    main install
    exit $?
fi

main "$@"