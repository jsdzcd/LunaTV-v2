# LunaTV-v2
# LunaTV 一键部署脚本
适用于 **Ubuntu 18.04+/20.04+/22.04+** 和 **CentOS 7+/8+/9+** 的 LunaTV 一键部署脚本，基于 Docker 部署，无需手动解决依赖冲突，快速上线。

## 🌟 特性
- 跨系统兼容（Ubuntu/CentOS）
- 自动安装 Docker + Docker Compose
- 自动配置防火墙，开放应用端口
- 数据持久化，不丢失配置和数据
- 容器开机自启，服务器重启无需手动启动
- 彩色输出，新手友好，附带常用管理命令

## 🚀 快速一键部署（核心命令）
直接复制以下单行命令到服务器终端执行（需 root 权限，无需提前下载脚本）：
```bash
wget -O install.sh https://raw.githubusercontent.com/jsdzcd/LunaTV-v2/main/install.sh && chmod +x install.sh && ./install.sh
```

### 命令说明
1.  该命令会自动从 `jsdzcd` 仓库拉取最新部署脚本并执行
2.  全程无需手动干预，等待 3-10 分钟（取决于服务器网络速度）即可完成部署
3.  若提示 `curl: command not found`，先安装 curl：
    - Ubuntu/Debian：`sudo apt install curl -y`
    - CentOS/Rocky/AlmaLinux：`sudo yum install curl -y`

## 📌 常用命令
| 功能 | 命令 |
|------|------|
| 查看服务状态 | `docker compose -f /opt/lunatv/docker-compose.yml ps` |
| 查看服务日志 | `docker compose -f /opt/lunatv/docker-compose.yml logs -f` |
| 重启服务 | `docker compose -f /opt/lunatv/docker-compose.yml restart` |
| 停止服务 | `docker compose -f /opt/lunatv/docker-compose.yml down` |
| 升级服务 | `cd /opt/lunatv && docker compose pull && docker compose up -d` |

## 📂 目录结构
```
/opt/lunatv/
├── docker-compose.yml  # Docker Compose 配置文件（仓库 jsdzcd 脚本自动生成）
├── data/               # 数据持久化目录（请勿随意删除，丢失将导致数据重置）
└── config/             # 配置文件目录（可修改 LunaTV 相关配置，修改后需重启服务）
```

## ⚠️ 注意事项
1.  云服务器用户需在 **安全组** 中开放 8080 端口（默认应用端口），否则无法外部访问。
2.  脚本运行需要网络通畅，确保服务器能访问 Docker Hub 拉取镜像（国内服务器可提前配置 Docker 国内镜像源加速）。
3.  如需修改应用端口，编辑 `/opt/lunatv/docker-compose.yml` 中的端口映射（格式：`宿主端口:容器端口`），保存后执行重启服务命令即可。
4.  支持 x86_64/arm64 架构，兼容云服务器、本地虚拟机、树莓派等设备。
5.  仓库 `jsdzcd` 中仅需存放 `deploy_lunatv.sh` 脚本即可，无需额外上传其他文件，用户通过一键命令即可拉取使用。

## 🐛 问题排查
1.  服务启动失败：优先查看日志 `docker compose -f /opt/lunatv/docker-compose.yml logs -f`，根据日志报错信息排查。
2.  端口无法访问：① 检查服务器防火墙（`ufw status`/`firewall-cmd --list-ports`）；② 检查云服务器安全组配置；③ 确认容器是否正常运行（`docker ps`）。
3.  Docker 安装失败：确保服务器能访问外网，或手动配置 Docker 国内镜像源（阿里云、腾讯云、中科大等）。
4.  脚本拉取失败：检查 GitHub 仓库地址是否正确（替换命令中的「你的GitHub用户名」为实际用户名，仓库名确保为 `jsdzcd`），确保仓库已公开且 `deploy_lunatv.sh` 脚本路径正确。

## 📄 许可证
[MIT License](LICENSE)
