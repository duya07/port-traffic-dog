# port-traffic-dog

端口流量监控与限速脚本（基于 [realm-xwPF](https://github.com/zywe03/realm-xwPF) 定制）。以 root 运行，使用 nftables 计数、HTB 限速，并提供 Telegram / 企业微信通知。

> 安全提示：`v6.gh-proxy.org` 等镜像由第三方提供；脚本以 root 运行，安全性要求高时请优先使用 GitHub 直连。

## 功能

- **端口流量统计**：nftables counter 统计指定端口/端口段的双向流量，每分钟写入自然日快照（`traffic_stats.json`）并维护 counter 灾备（`traffic_data.json`）。
- **流量配额**：按 月 / 每 N 天 / 每 N 月 / 每年 / 指定日期 自动重置；达量由 nftables quota 直接阻断，counter 与 quota 使用同一倍率。
- **端口限速**：统一 HTB 下的端口子类 + nft 标记 + `fw` 分类器（单条 `protocol all` 覆盖 IPv4/IPv6），支持 `Kbps/Mbps/Gbps`，`0` 表示无限制。
- **服务到期封锁**：按北京时间封锁到期端口的 TCP/UDP 入站、出站与转发，延期/取消立即解锁。
- **来源 IP 并发限制（测试中）**：独立脚本 `port-ip-guard.sh`，按 conntrack 识别真正进入本机服务的来源 IP，可限制并发来源数。
- **通知**：Telegram（官方线路或 HTTPS 自定义线路）、企业微信，支持状态通知与定时报告。
- **配置导入/导出、脚本更新、迁移、自检与修复**：均在失败时回滚，不覆盖外部文件与第三方 TC。

## 安装

直连：

```bash
wget -O port-traffic-dog.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh
chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

国内优先（gh-proxy）：

```bash
wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh
chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

Alpine：先运行 `alpine-port-traffic-dog-preinstall.sh` 补齐 `bash/nftables/conntrack-tools/iproute2/jq/gawk/bc/unzip/dcron/curl/util-linux-misc/tzdata` 等依赖并启动 `crond`，再执行上面的主脚本。

旧版迁移：`sudo ./migrate-to-custom.sh`（备份到 `/etc/port-traffic-dog-migration-backup/时间戳/`，可选 `REPO=` / `BRANCH=`）。

## 常用命令

```bash
sudo dog --self-check          # 配置/规则/统计/cron/依赖/通知自检
sudo dog --tc-status           # 只读检查统一 HTB 是否完整
sudo dog --repair-traffic-rules
sudo dog --snapshot-traffic    # 立即写一次自然日快照
sudo dog --restore-runtime     # 按配置与灾备恢复 nftables/TC
sudo dog --restore-nft-runtime # 只恢复 nftables（@reboot 使用）
sudo dog --check-port-expirations
sudo dog --recover-tc --manual # 用户确认后重建统一 HTB
sudo dog --uninstall
```

主菜单 `8` 系统自检/修复，`9` TC 冲突处理/自动恢复，`10` 来源 IP 并发限制。

## 关键说明

- **与 TrafficCop Lite 共存**：共用统一 HTB——NTC 的 `1:1` 父类承担整机上限，Dog 在 `1:1` 下维护端口子类与过滤器；任一项目可单独安装。共享锁 `/run/lock/traffic-tools-tc.lock`，root crontab 锁各自独立；`/etc/trafficcop-lite/tc_limit_state` 是整机上限的权威来源。
- **第三方 TC**：只视为冲突源，不读取、不迁移、不保留；自动路径拒绝接管，需在菜单 `9` 确认后才删除并只重建 Dog/NTC 层级。
- **流量口径**：双向 `入站×2 + 出站×2`；单向 `入站 + 出站`。菜单总量、通知与配额进度均以 nftables counter 为准，自然日快照仅用于独立日统计。
- **失败关闭**：nft/tc/配置/状态文件读取或解析失败时保留现有限制并返回失败，不会把"读不到"当成"没有"。
- 服务到期封锁只针对本机 TCP/UDP 的 input/output/forward；来源 IP 并发限制只作用于本机 TCP 服务，不处理内核 FORWARD/DNAT。
- 需 root 权限；`tc qdisc del … root` 会清空该网卡根队列，同机有其他 QoS 时请先确认。

## 安装后的文件

```text
/usr/local/bin/port-traffic-dog.sh          主脚本
/usr/local/bin/dog                          快捷命令
/etc/port-traffic-dog/config.json           配置
/etc/port-traffic-dog/traffic_data.json     counter 灾备
/etc/port-traffic-dog/traffic_stats.json    自然日快照
/etc/port-traffic-dog/notifications/        Telegram / 企业微信模块
/etc/port-traffic-dog-migration-backup/     迁移备份
```

## 故障排查

```bash
sudo dog --self-check
sudo nft list table inet port_traffic_monitor
IFACE=$(ip route | awk '/default/ {print $5; exit}')
sudo tc qdisc show dev "$IFACE"; sudo tc class show dev "$IFACE"; sudo tc filter show dev "$IFACE"
sudo crontab -l | grep port-traffic-dog
```

## 参考

- 上游：<https://github.com/zywe03/realm-xwPF>
- 定制说明：[PORT_TRAFFIC_DOG_CUSTOM.md](PORT_TRAFFIC_DOG_CUSTOM.md)
