# Nftables Port Forwarding Helper (nft-helper)

A lightweight, interactive shell script to manage Nftables port forwarding rules on Linux servers.

It provides a user-friendly menu to add, edit, delete, and view port forwarding rules without needing to manually mess with complex `nftables.conf` syntax. It supports both **Systemd** (Debian/Ubuntu) and **OpenRC** (Alpine Linux).

## ✨ Features

- **OS Support**: Auto-detects and supports Debian/Ubuntu and Alpine Linux.
- **Zero Dependency Config**: Automatically installs necessary dependencies (`nftables`, `curl`, `nano`, etc.).
- **Auto IP Forwarding**: Automatically enables `net.ipv4.ip_forward` to ensure traffic forwarding works.
- **Interactive Menu**: Simple numbered menu for all operations.
- **Rule Management**:
  - **Add**: Easily forward TCP/UDP traffic from a local port to a remote IP:Port.
  - **View**: See all active forwarding rules in a clean list.
  - **Quick Edit (Wizard)**: Modify existing rules step-by-step without opening a text editor.
  - **Manual Edit**: Open the config file with `nano` for advanced users.
  - **Delete**: Remove specific rules by selecting their index number.
- **Service Management**: Start, Stop, Restart, Enable/Disable auto-start.
- **Safe Reset**: One-click option to clear all rules and reset configuration to default (without uninstalling the package).
- **Self-Update**: Built-in function to update the script from GitHub.

## 🚀 Installation

Run the following command to download and start the script:

```bash
curl -fsSL https://raw.githubusercontent.com/RomanovCaesar/nft-helper/main/nft_helper.sh -o nft_helper.sh && chmod +x nft_helper.sh && ./nft_helper.sh

```

### Shortcut

After running the script once, a shortcut is automatically created. You can simply type the following command anywhere to launch the menu:

```bash
nft-helper

```

## 📋 Menu Options

When you run the script, you will see the following interface:

```text
################################################
#         Caesar 蜜汁 Nft 端口转发管理脚本       #
#          System: Debian/Ubuntu (Systemd)     #
################################################
Nftables 状态: 已安装 (v1.0.x)
服务运行 状态: 运行中
IP转发   状态: 已开启
提示: 输入 nft-helper 可快速启动本脚本
################################################
1. 安装 / 重置 Nftables 配置
2. 添加转发规则
3. 查看现有转发规则
4. 快速修改转发规则 (向导)
5. 修改配置文件 (nano)
6. 删除转发规则
------------------------------------------------
7. 设置开机自启 (enable)
8. 取消开机自启 (disable)
9. 启动服务 (start)
10. 停止服务 (stop)
11. 重启服务 (restart - 应用配置)
------------------------------------------------
12. 清空所有规则 (重置配置)
99. 更新本脚本
0. 退出脚本
################################################

```

## ⚙️ How it Works

1. **NAT Masquerade**: The script configures `nftables` to perform Destination NAT (DNAT) for incoming traffic and Masquerading (SNAT) for outgoing traffic, acting as a transparent relay.
2. **Configuration**: Rules are saved to `/etc/nftables.conf`.
3. **Persistence**: The script ensures the `nftables` service is enabled on boot so rules persist after a reboot.

## ⚠️ Requirements

- **Root Privileges**: The script must be run as root.
- **Supported OS**:
  - Debian / Ubuntu / CentOS (Systemd based)
  - Alpine Linux (OpenRC based)

## 📝 Example Usage

**Goal**: Forward traffic from your VPS port `8080` to `1.1.1.1` on port `80`.

1. Run `nft-helper`.
2. Select option **2** (Add Forwarding Rule).
3. **Listen IP**: Press Enter (defaults to `0.0.0.0`).
4. **Listen Port**: Enter `8080`.
5. **Target IP**: Enter `1.1.1.1`.
6. **Target Port**: Enter `80`.
7. Select option **11** (Restart Service) to apply changes.

## 🤝 Contributing

Issues and Pull Requests are welcome! If you find a bug or have a feature request, please open an issue.
