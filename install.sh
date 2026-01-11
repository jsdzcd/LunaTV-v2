#!/bin/bash
set -euo pipefail

# ==================== 配置常量（可根据项目调整）====================
PROJECT_NAME="lunatv"
PROJECT_DIR="/opt/${PROJECT_NAME}"
DOCKER_COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
# 暴露端口（可根据LunaTV项目默认端口修改，默认8080）
APP_PORT=8080
# LunaTV 镜像（优先使用官方镜像，无官方则使用自定义构建，此处假设已有公开镜像）
LUNATV_IMAGE="lunatv/lunatv:latest"
# 系统架构检测
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/armv7/')

# ==================== 颜色输出函数（提升用户体验）====================
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }

# ==================== 第一步：系统检测 ====================
detect_os() {
    blue "===== 检测操作系统 ====="
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION_ID=$VERSION_ID
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
        green "检测到 Ubuntu ${VERSION_ID}，兼容本脚本"
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
        green "检测到 ${OS} ${VERSION_ID}，兼容本脚本"
    else
        red "不支持的操作系统：${OS}，仅支持 Ubuntu 18.04+ 和 CentOS 7+！"
        exit 1
    fi
}

# ==================== 第二步：安装 Docker 和 Docker Compose ====================
install_docker() {
    blue "===== 安装/升级 Docker 和 Docker Compose ====="
    if command -v docker &> /dev/null && command -v docker compose &> /dev/null; then
        yellow "Docker 和 Docker Compose 已安装，跳过安装步骤"
        return
    fi

    # Ubuntu 安装 Docker
    if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        yellow "更新系统软件源..."
        apt update -y && apt upgrade -y
        apt install -y ca-certificates curl gnupg lsb-release

        # 添加 Docker 官方 GPG 密钥
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

        # 添加 Docker 软件源
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        # 安装 Docker
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # CentOS/Rocky/AlmaLinux 安装 Docker
    elif [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]]; then
        yellow "更新系统软件源..."
        $PACKAGE_MANAGER update -y

        # 卸载旧版本 Docker
        $PACKAGE_MANAGER remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine

        # 安装依赖
        $PACKAGE_MANAGER install -y ca-certificates curl gnupg device-mapper-persistent-data lvm2

        # 添加 Docker 官方 GPG 密钥
        curl -fsSL https://download.docker.com/linux/centos/gpg | gpg --dearmor -o /etc/pki/rpm-gpg/RPM-GPG-KEY-DOCKER

        # 添加 Docker 软件源
        echo -e "[docker-ce-stable]\nname=Docker CE Stable - \$basearch\nbaseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable\nenabled=1\ngpgcheck=1\ngpgkey=/etc/pki/rpm-gpg/RPM-GPG-KEY-DOCKER" | tee /etc/yum.repos.d/docker-ce.repo > /dev/null

        # 安装 Docker
        $PACKAGE_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi

    # 启动 Docker 并设置开机自启
    systemctl start docker
    systemctl enable docker

    # 验证 Docker 安装
    if ! command -v docker &> /dev/null; then
        red "Docker 安装失败，请手动排查！"
        exit 1
    fi

    # 验证 Docker Compose 安装
    if ! docker compose version &> /dev/null; then
        red "Docker Compose 安装失败，请手动排查！"
        exit 1
    fi

    green "Docker 和 Docker Compose 安装成功！"
}

# ==================== 第三步：配置防火墙（开放应用端口）====================
configure_firewall() {
    blue "===== 配置防火墙（开放 ${APP_PORT} 端口）====="
    if [[ "$FIREWALL" == "ufw" ]]; then
        # Ubuntu 防火墙配置
        if ! command -v ufw &> /dev/null; then
            apt install -y ufw
        fi
        ufw allow ${APP_PORT}/tcp comment "${PROJECT_NAME} application port"
        ufw reload || true
    elif [[ "$FIREWALL" == "firewalld" ]]; then
        # CentOS 防火墙配置
        systemctl start firewalld || true
        systemctl enable firewalld || true
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp
        firewall-cmd --reload
    fi
    green "防火墙已配置，${APP_PORT} 端口已开放！"
}

# ==================== 第四步：创建项目目录并编写 Docker Compose 配置 ====================
setup_project() {
    blue "===== 配置 LunaTV 项目 ====="
    # 创建项目目录
    mkdir -p ${PROJECT_DIR}
    cd ${PROJECT_DIR}

    # 编写 Docker Compose 配置文件
    yellow "生成 Docker Compose 配置文件..."
    cat > ${DOCKER_COMPOSE_FILE} << EOF
version: '3.8'

services:
  ${PROJECT_NAME}:
    image: ${LUNATV_IMAGE}
    container_name: ${PROJECT_NAME}_app
    restart: always
    ports:
      - "${APP_PORT}:${APP_PORT}"
    volumes:
      - ./data:/app/data  # 数据持久化（根据LunaTV项目目录调整）
      - ./config:/app/config  # 配置文件持久化
    environment:
      - TZ=Asia/Shanghai  # 时区配置
      - PORT=${APP_PORT}  # 应用端口
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

    green "Docker Compose 配置文件生成成功！"
}

# ==================== 第五步：启动 LunaTV 服务 ====================
start_lunatv() {
    blue "===== 启动 LunaTV 服务 ====="
    cd ${PROJECT_DIR}

    # 拉取镜像并启动服务
    yellow "拉取 LunaTV 镜像（可能需要几分钟，取决于网络速度）..."
    docker compose pull

    yellow "启动 LunaTV 容器..."
    docker compose up -d

    # 验证服务是否启动成功
    if docker ps | grep -q "${PROJECT_NAME}_app"; then
        green "LunaTV 服务启动成功！"
    else
        red "LunaTV 服务启动失败，查看日志：docker compose logs -f"
        exit 1
    fi
}

# ==================== 第六步：部署完成提示 ====================
deploy_complete() {
    blue "===== 部署完成 ====="
    green "✅ LunaTV 一键部署成功！"
    echo ""
    green "🔗 访问地址：http://$(curl -s ifconfig.me):${APP_PORT} （或 http://服务器IP:${APP_PORT}）"
    echo ""
    yellow "📌 常用命令："
    echo "   1. 查看服务状态：docker compose -f ${DOCKER_COMPOSE_FILE} ps"
    echo "   2. 查看服务日志：docker compose -f ${DOCKER_COMPOSE_FILE} logs -f"
    echo "   3. 重启服务：docker compose -f ${DOCKER_COMPOSE_FILE} restart"
    echo "   4. 停止服务：docker compose -f ${DOCKER_COMPOSE_FILE} down"
    echo "   5. 数据目录：${PROJECT_DIR}/data（持久化存储，请勿随意删除）"
    echo "   6. 配置目录：${PROJECT_DIR}/config（可修改项目配置）"
    echo ""
    yellow "⚠️  注意事项："
    echo "   1. 确保服务器安全组已开放 ${APP_PORT} 端口（云服务器需额外配置）"
    echo "   2. 首次访问可能需要初始化，等待 1-2 分钟"
    echo "   3. 如需修改端口，编辑 ${DOCKER_COMPOSE_FILE} 后重启服务"
}

# ==================== 主流程执行 ====================
main() {
    # 检查是否为 root 用户
    if [[ $EUID -ne 0 ]]; then
        red "⚠️  请使用 root 用户运行此脚本（或添加 sudo 前缀：sudo bash $0）"
        exit 1
    fi

    blue "============================================="
    blue "        LunaTV 一键部署脚本（Linux）"
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
