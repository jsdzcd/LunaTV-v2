#!/bin/bash
set -euo pipefail

# ==================== 配置常量（可根据项目调整）====================
PROJECT_NAME="lunatv"
PROJECT_DIR="/opt/${PROJECT_NAME}"
DOCKER_COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
# LunaTV 官方默认端口为 3000，修正原 8080 错误
APP_PORT=3000
# 替换为真实可拉取的 LunaTV 镜像（GHCR 公开镜像）
LUNATV_IMAGE="ghcr.io/szemeng76/lunatv:5.9.1"
# 系统架构检测（增强兼容性）
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/armv7/' -e 's/armv8l/arm64/')

# ==================== 颜色输出函数（提升用户体验）====================
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }
cyan() { echo -e "\033[36m$1\033[0m"; }

# ==================== 第一步：系统检测 ====================
detect_os() {
    blue "===== 检测操作系统 ====="
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION_ID=${VERSION_ID:-unknown}
    else
        red "不支持的操作系统，仅支持 Ubuntu 18.04+ 和 CentOS 7+！"
        exit 1
    fi

    # 验证系统是否兼容
    if [[ "$OS" =~ ^Ubuntu$ ]]; then
        if [[ "${VERSION_ID%%.*}" -lt 18 ]]; then
            red "Ubuntu 版本过低，需要 18.04 及以上！"
            exit 1
        fi
        PACKAGE_MANAGER="apt"
        FIREWALL="ufw"
        green "✅ 检测到 Ubuntu ${VERSION_ID}，兼容本脚本"
    elif [[ "$OS" =~ ^CentOS$ || "$OS" =~ ^Rocky$ || "$OS" =~ ^AlmaLinux$ ]]; then
        if [[ "${VERSION_ID%%.*}" -lt 7 ]]; then
            red "CentOS 版本过低，需要 7 及以上！"
            exit 1
        fi
        PACKAGE_MANAGER="yum"
        if [[ "${VERSION_ID%%.*}" -ge 8 ]]; then
            PACKAGE_MANAGER="dnf"
        fi
        FIREWALL="firewalld"
        green "✅ 检测到 ${OS} ${VERSION_ID}，兼容本脚本"
    else
        red "❌ 不支持的操作系统：${OS}，仅支持 Ubuntu 18.04+ 和 CentOS 7+！"
        exit 1
    fi
}

# ==================== 第二步：安装 Docker 和 Docker Compose ====================
install_docker() {
    blue "===== 安装/升级 Docker 和 Docker Compose ====="
    # 兼容 Docker Compose V1/V2 两种写法
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null || command -v docker-compose &> /dev/null; then
            yellow "📌 Docker 和 Docker Compose 已安装，跳过安装步骤"
            return
        fi
    fi

    # Ubuntu 安装 Docker
    if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        yellow "🔄 更新系统软件源..."
        apt update -y && apt upgrade -y
        apt install -y ca-certificates curl gnupg lsb-release --no-install-recommends

        # 添加 Docker 官方 GPG 密钥（修复权限问题）
        mkdir -p /etc/apt/trusted.gpg.d
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg

        # 添加 Docker 软件源（适配新版 Ubuntu）
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        # 安装 Docker
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --no-install-recommends

    # CentOS/Rocky/AlmaLinux 安装 Docker
    elif [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]]; then
        yellow "🔄 更新系统软件源..."
        $PACKAGE_MANAGER update -y

        # 卸载旧版本 Docker
        $PACKAGE_MANAGER remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true

        # 安装依赖
        $PACKAGE_MANAGER install -y ca-certificates curl gnupg device-mapper-persistent-data lvm2 --no-install-recommends

        # 添加 Docker 官方 GPG 密钥
        curl -fsSL https://download.docker.com/linux/centos/gpg | gpg --dearmor -o /etc/pki/rpm-gpg/RPM-GPG-KEY-DOCKER

        # 添加 Docker 软件源（适配 CentOS 8+/9+）
        echo -e "[docker-ce-stable]\nname=Docker CE Stable - \$basearch\nbaseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable\nenabled=1\ngpgcheck=1\ngpgkey=/etc/pki/rpm-gpg/RPM-GPG-KEY-DOCKER" | tee /etc/yum.repos.d/docker-ce.repo > /dev/null

        # 安装 Docker
        $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin --no-install-recommends
    fi

    # 启动 Docker 并设置开机自启（兼容系统无 systemd 情况）
    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload
        systemctl start docker
        systemctl enable docker
    else
        service docker start
        chkconfig docker on
    fi

    # 验证 Docker 安装
    if ! command -v docker &> /dev/null; then
        red "❌ Docker 安装失败，请手动排查！"
        exit 1
    fi

    # 验证 Docker Compose 安装（兼容 V1/V2）
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        yellow "⚠️ Docker Compose V2 安装失败，尝试安装 V1 版本..."
        # 安装 Compose V1 备用
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        if ! command -v docker-compose &> /dev/null; then
            red "❌ Docker Compose 安装失败，请手动排查！"
            exit 1
        fi
    fi

    # 配置普通用户免 sudo 使用 Docker（可选但友好）
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker ${SUDO_USER}
        yellow "📌 已将 ${SUDO_USER} 添加到 docker 用户组，需重新登录生效"
    fi

    green "✅ Docker 和 Docker Compose 安装成功！"
}

# ==================== 第三步：配置防火墙（开放应用端口）====================
configure_firewall() {
    blue "===== 配置防火墙（开放 ${APP_PORT} 端口）====="
    # 跳过防火墙配置（若未安装）
    if [[ "$FIREWALL" == "ufw" ]]; then
        # Ubuntu 防火墙配置
        if ! command -v ufw &> /dev/null; then
            yellow "📌 UFW 未安装，跳过防火墙配置"
            return
        fi
        ufw allow ${APP_PORT}/tcp comment "${PROJECT_NAME} application port" || true
        ufw reload || true
    elif [[ "$FIREWALL" == "firewalld" ]]; then
        # CentOS 防火墙配置
        if ! command -v firewall-cmd &> /dev/null; then
            yellow "📌 firewalld 未安装，跳过防火墙配置"
            return
        fi
        systemctl start firewalld || true
        systemctl enable firewalld || true
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp || true
        firewall-cmd --reload || true
    fi
    green "✅ 防火墙已配置，${APP_PORT} 端口已开放！"
}

# ==================== 第四步：创建项目目录并编写 Docker Compose 配置 ====================
setup_project() {
    blue "===== 配置 LunaTV 项目 ====="
    # 创建项目目录（确保权限）
    mkdir -p ${PROJECT_DIR}/{data,config}
    chmod 755 ${PROJECT_DIR} -R
    cd ${PROJECT_DIR}

    # 编写 Docker Compose 配置文件（适配真实 LunaTV 镜像）
    yellow "📝 生成 Docker Compose 配置文件..."
    cat > ${DOCKER_COMPOSE_FILE} << EOF

services:
  ${PROJECT_NAME}-core:
    image: ${LUNATV_IMAGE}
    container_name: ${PROJECT_NAME}_app
    restart: on-failure:3
    ports:
      - "${APP_PORT}:3000"  # 容器内固定 3000 端口，外部映射为 APP_PORT
    volumes:
      - ./data:/app/data  # LunaTV 数据持久化
      - ./config:/app/config  # LunaTV 配置持久化
    environment:
      - TZ=Asia/Shanghai  # 时区配置
      - USERNAME=admin    # 默认登录账号
      - PASSWORD=000000   # 默认登录密码
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://${PROJECT_NAME}-kvrocks:6666
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - ${PROJECT_NAME}-kvrocks

  ${PROJECT_NAME}-kvrocks:
    image: apache/kvrocks:latest
    container_name: ${PROJECT_NAME}_kvrocks
    restart: unless-stopped
    volumes:
      - ./kvrocks-data:/var/lib/kvrocks
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  kvrocks-data:
EOF

    # 修复 Compose 文件权限
    chmod 644 ${DOCKER_COMPOSE_FILE}
    green "✅ Docker Compose 配置文件生成成功！"
}

# ==================== 第五步：启动 LunaTV 服务 ====================
start_lunatv() {
    blue "===== 启动 LunaTV 服务 ====="
    cd ${PROJECT_DIR}

    # 兼容 Compose V1/V2 命令
    COMPOSE_CMD="docker compose"
    if ! docker compose version &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    fi

    # 拉取镜像（添加超时和重试）
    yellow "🔍 拉取 LunaTV 镜像（可能需要几分钟，取决于网络速度）..."
    if ! ${COMPOSE_CMD} pull --quiet; then
        yellow "⚠️  首次拉取失败，重试一次..."
        ${COMPOSE_CMD} pull || red "❌ 镜像拉取失败，请检查网络或镜像地址！" && exit 1
    fi

    # 启动服务
    yellow "🚀 启动 LunaTV 容器..."
    ${COMPOSE_CMD} up -d

    # 等待服务初始化
    sleep 10

    # 验证服务是否启动成功（改用 docker inspect 直接查询容器运行状态，不受 Compose 格式影响）
if docker inspect -f '{{.State.Running}}' ${PROJECT_NAME}_app 2>/dev/null | grep -q "true"; then
    green "✅ LunaTV 服务启动成功！"
    # 额外提示 KVROCKS 重启状态，方便用户知晓
    if docker inspect -f '{{.State.Running}}' ${PROJECT_NAME}_kvrocks 2>/dev/null | grep -q "false"; then
        yellow "⚠️  注意：KVROCKS 存储服务正在重启，可能影响 LunaTV 数据持久化，建议排查日志！"
    fi
else
    red "❌ LunaTV 服务启动失败，查看日志：${COMPOSE_CMD} logs -f"
    exit 1
fi
}

# ==================== 第六步：部署完成提示 ====================
deploy_complete() {
    blue "============================================="
    green "✅ LunaTV 一键部署成功！"
    echo ""
    cyan "🔗 访问地址：http://$(curl -s --max-time 5 ifconfig.me || echo '服务器IP'):${APP_PORT}"
    echo ""
    yellow "🔑 默认账号密码："
    echo "   用户名：admin"
    echo "   密码：000000"
    echo ""
    yellow "📌 常用命令："
    echo "   1. 查看服务状态：cd ${PROJECT_DIR} && ${COMPOSE_CMD:-docker compose} ps"
    echo "   2. 查看服务日志：cd ${PROJECT_DIR} && ${COMPOSE_CMD:-docker compose} logs -f"
    echo "   3. 重启服务：cd ${PROJECT_DIR} && ${COMPOSE_CMD:-docker compose} restart"
    echo "   4. 停止服务：cd ${PROJECT_DIR} && ${COMPOSE_CMD:-docker compose} down"
    echo "   5. 数据目录：${PROJECT_DIR}/data（持久化存储，请勿随意删除）"
    echo "   6. 配置目录：${PROJECT_DIR}/config（可修改项目配置）"
    echo ""
    yellow "⚠️  注意事项："
    echo "   1. 云服务器需在安全组开放 ${APP_PORT} 端口"
    echo "   2. 首次访问可能需要 1-2 分钟初始化"
    echo "   3. 建议登录后立即修改默认密码"
    blue "============================================="
}

# ==================== 主流程执行 ====================
main() {
    # 检查是否为 root 用户
    if [[ $EUID -ne 0 ]]; then
        red "⚠️  请使用 root 用户运行此脚本（或添加 sudo 前缀：sudo bash $0）"
        exit 1
    fi

    # 欢迎信息
    clear
    blue "============================================="
    blue "        LunaTV 一键部署脚本（Linux）"
    blue "        适配 Ubuntu/CentOS 系统"
    blue "============================================="
    echo ""

    # 依次执行部署步骤
    detect_os
    install_docker
    configure_firewall
    setup_project
    start_lunatv
    deploy_complete
}

# 启动主流程
main
