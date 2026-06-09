# port-traffic-dog

基于上游项目定制的端口流量监控脚本集合。

## 参考来源

- 上游仓库: <https://github.com/zywe03/realm-xwPF>
- 上游主脚本: <https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh>
- 上游通知模块: <https://github.com/zywe03/realm-xwPF/tree/main/notifications>

## 本仓库主要改动

1. Telegram 通知排版优化（更适合消息推送阅读）。
2. Telegram 支持官方线路与自定义线路切换。
3. 默认内置自定义线路地址示例: `https://tgapi.duyaw.com/`。
4. 通知模块同步支持“默认只补缺失”和“强制同步覆盖”两种模式；手动更新、迁移和 `--sync-notification-modules` 会使用强制同步。
5. 增加自检命令: `dog --self-check`。
6. 增加迁移脚本: `migrate-to-custom.sh`。
7. Alpine 预装脚本同步维护: `alpine-port-traffic-dog-preinstall.sh`。
8. 增加通知定时任务刷新命令: `dog --refresh-notification-cron`。
9. 卸载时会清理通知 cron 和端口自动重置 cron。
10. 流量配额支持更灵活的自动重置策略：每月、每 N 天、每 N 个月、每年、指定到期日期一次性重置。

## 下载方式说明

- 直连（海外网络优先）  
  使用 `https://raw.githubusercontent.com/...`
- 国内优先（代理加速）  
  使用 `https://v6.gh-proxy.org/https://raw.githubusercontent.com/...`

---

## 1) 安装主脚本

直连:

```bash
wget -O port-traffic-dog.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh
chmod +x port-traffic-dog.sh
./port-traffic-dog.sh
```

国内优先（gh-proxy）:

```bash
wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh
chmod +x port-traffic-dog.sh
./port-traffic-dog.sh
```

## 2) Alpine 安装

直连:

```bash
wget -O alpine-port-traffic-dog-preinstall.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/alpine-port-traffic-dog-preinstall.sh && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

国内优先（gh-proxy）:

```bash
wget -O alpine-port-traffic-dog-preinstall.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/alpine-port-traffic-dog-preinstall.sh && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

Alpine 一键试用（可替换仓库）:

直连:

```bash
REPO="duya07/port-traffic-dog"; wget -O alpine-port-traffic-dog-preinstall.sh "https://raw.githubusercontent.com/${REPO}/main/alpine-port-traffic-dog-preinstall.sh" && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh "https://raw.githubusercontent.com/${REPO}/main/port-traffic-dog.sh" && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

国内优先（gh-proxy）:

```bash
REPO="duya07/port-traffic-dog"; wget -O alpine-port-traffic-dog-preinstall.sh "https://v6.gh-proxy.org/https://raw.githubusercontent.com/${REPO}/main/alpine-port-traffic-dog-preinstall.sh" && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh "https://v6.gh-proxy.org/https://raw.githubusercontent.com/${REPO}/main/port-traffic-dog.sh" && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

Alpine 预装脚本会补齐 `bash/nftables/iproute2/jq/gawk/bc/unzip/dcron/ca-certificates/curl/tzdata` 等依赖，创建 `cron -> crond` 兼容命令，启动并注册 `crond`，并检查 `nft/tc/ss/jq/awk/bc/unzip/cron/crontab/curl/bash` 是否可用。

## 3) 旧 VPS 迁移到定制版

迁移脚本会先备份，再覆盖安装。

直连:

```bash
wget -O migrate-to-custom.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/migrate-to-custom.sh && chmod +x migrate-to-custom.sh && sudo ./migrate-to-custom.sh
```

国内优先（gh-proxy）:

```bash
wget -O migrate-to-custom.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/migrate-to-custom.sh && chmod +x migrate-to-custom.sh && sudo ./migrate-to-custom.sh
```

可选：指定仓库和分支（默认 `duya07/port-traffic-dog` + `main`）:

```bash
sudo REPO="duya07/port-traffic-dog" BRANCH="main" ./migrate-to-custom.sh
```

默认备份目录示例:

- `/etc/port-traffic-dog-migration-backup/20260530-230000/`

迁移完成后会自动强制同步通知模块、刷新 Telegram / 企业微信状态通知定时任务，并显示当前脚本版本。迁移后建议再执行一次:

```bash
sudo dog --self-check
```

## 4) 常用维护命令

```bash
sudo dog --self-check
sudo dog --sync-notification-modules
sudo dog --refresh-notification-cron
sudo dog --uninstall
```

- `--self-check`: 检查配置文件、依赖命令、通知模块和 Telegram 连通性。
- `--sync-notification-modules`: 从仓库强制覆盖同步 `telegram.sh` / `wecom.sh`。
- `--refresh-notification-cron`: 根据当前配置重建通知定时任务，并尝试启动 `cron` / `crond`。
- `--uninstall`: 卸载脚本、配置目录、nftables/tc 规则，并清理通知 cron 和端口自动重置 cron。

## 5) 流量配额自动重置

添加端口监控时，如果设置了流量配额，脚本会立即提示设置自动重置策略，不需要再到管理菜单里单独改默认日期。

支持的策略:

- 每月几号重置：兼容原脚本逻辑，默认每月 1 日。
- 每隔多少天重置：例如每 30 天重置一次。
- 每隔多少个月重置：例如每 3 个月重置一次，可指定每次按几号结算。
- 每年几月几号重置：适合年度流量包。
- 指定到期日期重置一次：到期重置后会自动关闭该端口的自动重置。

日期处理规则:

- 31 号遇到没有 31 号的月份，会按该月最后一天处理。
- 2 月 29 日遇到非闰年，会按 2 月 28 日处理。
- 自动任务每天 00:05 检查是否到期，只有到期端口才会真正重置。
- 手动“立即重置”只清零当前流量，不会自动改变下一次到期日期。

## 6) 单独下载通知脚本

### telegram.sh

直连:

```bash
wget -O telegram.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/telegram.sh
```

国内优先（gh-proxy）:

```bash
wget -O telegram.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/telegram.sh
```

### wecom.sh

直连:

```bash
wget -O wecom.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/wecom.sh
```

国内优先（gh-proxy）:

```bash
wget -O wecom.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/wecom.sh
```

## 7) 限速规则核查与清理（nft/tc）

用于检查旧 VPS 上是否还有残留规则，并做兜底清理。

### 7.1 先查（不改系统）

```bash
sudo nft list tables | grep -E 'port_traffic_monitor|table inet port_traffic_monitor' || echo "nft table not found"
sudo nft list table inet port_traffic_monitor 2>/dev/null || true

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
echo "default iface: ${IFACE}"
sudo tc qdisc show dev "${IFACE}"
sudo tc class show dev "${IFACE}"
sudo tc filter show dev "${IFACE}"

sudo crontab -l | grep -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--reset-port|--check-reset-port' || echo "no related cron"
```

### 7.2 再清（卸载后兜底）

建议先执行:

```bash
sudo dog --uninstall
```

如果仍有残留，再执行:

```bash
sudo nft delete table inet port_traffic_monitor 2>/dev/null || true

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
if sudo tc qdisc show dev "${IFACE}" | grep -q 'htb 1:'; then
  sudo tc qdisc del dev "${IFACE}" root
fi

sudo crontab -l 2>/dev/null | grep -v -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--reset-port|--check-reset-port' | sudo crontab -
```

### 7.3 复查（确认清理完成）

```bash
sudo nft list table inet port_traffic_monitor 2>/dev/null && echo "still exists" || echo "nft table removed"

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
sudo tc qdisc show dev "${IFACE}"
sudo tc class show dev "${IFACE}"
sudo tc filter show dev "${IFACE}"

sudo crontab -l | grep -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--reset-port|--check-reset-port' || echo "cron clean"
```

## 目录结构

```text
.
├── PORT_TRAFFIC_DOG_CUSTOM.md
├── alpine-port-traffic-dog-preinstall.sh
├── migrate-to-custom.sh
├── port-traffic-dog.sh
├── telegram.sh
└── wecom.sh
```

## 注意事项

- 脚本可能会修改系统配置或安装依赖，建议先在测试环境执行。
- 使用通知功能前，请先完成 Telegram / 企业微信配置。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。
- `tc qdisc del dev <iface> root` 会清理该网卡根队列，若同机有其他 QoS 业务请先确认。
