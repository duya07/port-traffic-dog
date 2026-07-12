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
11. 流量计费规则继承上游双向权重：双向为 `入站×2 + 出站×2`；定制单向模式为双向规则减半，即 `入站 + 出站`，修正上游单向只统计 out 的缺口。
12. 当前周期流量、配额进度和限额初始化沿用 nftables counter 口径，counter 与 quota 使用完全一致的规则倍率；额外增加北京时间自然日快照统计，避免统计文件反向影响限额规则。
13. 通知和自然日快照 cron 只在存在监控端口时运行；删除最后一个端口后会自动清理任务，残留旧任务也会在下次触发时自行退出并移除。
14. 配置写入使用原子替换和短时锁，避免自动重置、通知配置和带宽 class ID 同时更新时互相覆盖。
15. 从旧快照版升级时会清理已不再支持的 `--send-snapshot`、`--create-snapshot` 和旧快照清理 cron，但保留原快照文件与配置备份。
16. 菜单更新会先校验新脚本语法并修正安装权限；更新成功后重新加载已安装版本，避免界面继续运行旧代码。
17. 普通 `dog` 使用轻量启动，不再重复重写 cron、同步通知模块、全量修复规则或写流量快照；这些维护动作集中到主菜单“系统自检/修复”。首次直接运行下载脚本时仍会自动安装主脚本并创建 `dog`，保持原安装方式兼容。
18. 更新覆盖主脚本后，由新版本进程执行 cron 刷新和流量规则迁移，避免旧进程继续调用旧函数；原配置和 `quota.reset_day` 仍可直接继承。
19. Telegram / 企业微信状态任务同时受“通道总开关”和“状态通知开关”控制；关闭通道后会移除对应 cron，残留任务触发时也不会发送。
20. 新增端口或端口段会拒绝与现有监控范围重叠，避免同一连接被多组 counter/quota 重复统计。
21. 配置文件和导出包默认限制为 root 可读写；导入配置会拒绝特殊文件，并在复制失败时恢复旧配置、规则和定时任务。
22. 带宽限制仅在 TC 分类和过滤器完整创建后写入配置；网卡已有不兼容的根队列时明确报错，不再显示伪成功。

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

迁移脚本会先备份配置、主脚本、快捷命令、root crontab 和现有 nftables 表，再完整下载并校验主脚本及两个通知模块；全部校验通过后才覆盖安装。

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

迁移完成后会刷新 Telegram / 企业微信和自然日统计定时任务、修复旧流量规则、核对迁移前后端口清单，并自动执行自检。旧版 `/etc/port-traffic-dog/data/snapshots/` 文件会保留在原配置目录和迁移备份中，但新版不再继续生成旧日/周/月快照。也可以手动复查：

```bash
sudo dog --self-check
```

## 4) 常用维护命令

```bash
sudo dog --self-check
sudo dog --sync-notification-modules
sudo dog --refresh-notification-cron
sudo dog --refresh-port-reset-cron
sudo dog --repair-traffic-rules
sudo dog --snapshot-traffic
sudo dog --uninstall
```

- `--self-check`: 检查配置文件、计数/配额规则数量、cron、依赖命令、通知模块和 Telegram 连通性。
- `--sync-notification-modules`: 从仓库强制覆盖同步 `telegram.sh` / `wecom.sh`。
- `--refresh-notification-cron`: 根据当前配置和监控端口重建通知定时任务，并尝试启动 `cron` / `crond`；没有监控端口时不会保留状态报告任务。
- `--refresh-port-reset-cron`: 根据当前端口重置策略重建自动重置任务，并清理旧版 `--reset-port` 和失效端口残留任务。
- `--repair-traffic-rules`: 按当前计费模式检查并重建 counter/quota 规则；双向目标为每个方向 8 条 counter 引用、16 条 quota 引用，单向目标为每个方向 4 条 counter 引用、8 条 quota 引用。升级时会按旧规则倍率换算已有 counter，避免已有流量丢失或再次翻倍。
- `--snapshot-traffic`: 立即写入一次自然日流量快照；正常情况下脚本会自动配置每分钟执行一次。
- `--uninstall`: 卸载脚本、配置目录、nftables/tc 规则，并清理通知 cron、自然日快照 cron 和端口自动重置 cron。

主菜单选择 `8. 系统自检/修复`，可主动补齐依赖和通知模块、修正权限与快捷命令、按当前配置重建 cron、检查修复流量/配额规则、更新自然日快照并执行最终自检。普通打开 `dog` 时不会重复执行这些重操作；只有检测到 nftables 监控规则确实缺失时，才会按原配置自动恢复。

## 5) 流量配额自动重置

添加端口监控时，如果设置了流量配额，脚本会立即提示设置自动重置策略，不需要再到管理菜单里单独改默认日期。

支持的策略:

- 每月几号重置：兼容原脚本逻辑，默认每月 1 日。
- 每隔多少天重置：例如每 30 天重置一次。
- 每隔多少个月重置：例如每 3 个月重置一次，可指定每次按几号结算。
- 每年几月几号重置：适合年度流量包。
- 指定到期日期重置一次：到期重置后会自动关闭该端口的自动重置。

日期处理规则:

- 旧配置里的 `quota.reset_day` 会自动继承为“每月几号重置”，例如原来设置每月 2 日重置，会继续按每月 2 日执行。
- 新增或修改周期型策略时，下一次自动重置会从未来日期开始计算，避免刚添加端口就被当天任务重置。
- 第一次批量添加多个有限配额端口时，可选择为每个端口分别设置自动重置策略。
- 指定到期日期为当天时，脚本会询问是否立即重置当前流量；不立即重置则等待下一次周期检查。
- 31 号遇到没有 31 号的月份，会按该月最后一天处理。
- 2 月 29 日遇到非闰年，会按 2 月 28 日处理。
- 自动任务每 5 分钟按北京时间检查一次所有端口，只有到期端口才会真正重置，不依赖 VPS 的系统时区。
- 重置会验证 counter/quota 确实清零；失败时保留原到期日期并在下一次检查时重试，不会错误推进周期。
- cron、手动命令和即时重置共用重置锁，避免同一端口被并发清零两次。
- 手动“立即重置”只清零当前流量，不会自动改变下一次到期日期。

## 6) 流量统计口径

脚本仍把 nftables counter 作为当前周期流量和配额进度的权威来源；自动重置到期时清零 counter，因此每月、每 N 天、每 N 月、每年和指定到期日都可以沿用原脚本成熟的 counter 逻辑。`/etc/port-traffic-dog/traffic_stats.json` 只作为额外的自然日快照统计文件：

- 双向模式沿用上游的两组规则，计费总量为 `入站×2 + 出站×2`；单向模式保留一组入站和一组出站规则，计费总量为 `入站 + 出站`，不是旧版的“仅 out”。
- counter 与 quota 引用数量和倍率严格一致，因此界面进度达到配额时，nftables 阻断也按同一口径触发。
- 从当前单组双向规则版本升级时，已有双向 counter 和当天快照会按权重 1→2 转换；上游原生双组规则按权重 2 识别，不会重复乘 2。旧单向配置无法还原过去未记录的入站流量，升级后入站从 0 开始累计。

- `last_snapshot`: 记录每个端口上一次采样时的 nftables 入站/出站 counter。
- `daily`: 按北京时间自然日保存每日入站/出站增量。
- 主菜单端口总量、通知消息和配额进度读取当前 nftables counter；自然日快照文件只用于独立日统计，不参与主菜单总量叠加。
- 存在监控端口时，每分钟会自动执行 `dog --snapshot-traffic`；只有上一条快照在昨天 23:59、当前快照在今天 00:00 时，才会把边界增量补到昨天，避免把午夜后多分钟的流量错记到前一天。
- 自然日统计依赖 cron 持续运行；若 cron 停止很久或跨日后很久才恢复，脚本会从恢复当天重新建立安全基线，不能把停机期间的流量精确拆回每一天。
- `traffic_data.json` 仍用于异常退出/规则恢复时保留 nftables counter，不等同于自然日统计文件；恢复时只接受当前配置中仍存在的端口，删除端口或无有效灾备数据时会清除旧条目。
- 首次生成 `traffic_stats.json` 时只建立当前 nftables counter 基线，不把升级前的历史 counter 直接计入当天，避免旧偏差继续污染新统计。
- 重置端口前会先写入快照并记录重置历史，重置后只刷新该端口快照基线，不清空当天自然日统计，避免清零 counter 后下一次采样重复计算。
- 从旧配置升级时，原来的 `quota.reset_day` 仍按“每月几号重置”继承；自然日统计文件会从升级后的第一次快照开始累计。

## 7) 单独下载通知脚本

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

## 8) 限速规则核查与清理（nft/tc）

用于检查旧 VPS 上是否还有残留规则，并做兜底清理。

### 8.1 先查（不改系统）

```bash
sudo nft list tables | grep -E 'port_traffic_monitor|table inet port_traffic_monitor' || echo "nft table not found"
sudo nft list table inet port_traffic_monitor 2>/dev/null || true

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
echo "default iface: ${IFACE}"
sudo tc qdisc show dev "${IFACE}"
sudo tc class show dev "${IFACE}"
sudo tc filter show dev "${IFACE}"

sudo crontab -l | grep -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--snapshot-traffic|--reset-port|--check-reset-port|--check-scheduled-resets' || echo "no related cron"
```

### 8.2 再清（卸载后兜底）

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

sudo crontab -l 2>/dev/null | grep -v -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--snapshot-traffic|--reset-port|--check-reset-port|--check-scheduled-resets' | sudo crontab -
```

### 8.3 复查（确认清理完成）

```bash
sudo nft list table inet port_traffic_monitor 2>/dev/null && echo "still exists" || echo "nft table removed"

IFACE="$(ip route | awk '/default/ {print $5; exit}')"
sudo tc qdisc show dev "${IFACE}"
sudo tc class show dev "${IFACE}"
sudo tc filter show dev "${IFACE}"

sudo crontab -l | grep -E 'port-traffic-dog|--send-telegram-status|--send-wecom-status|--snapshot-traffic|--reset-port|--check-reset-port|--check-scheduled-resets' || echo "cron clean"
```

## VPS 安装后的系统文件

```text
系统文件
├── /usr/local/bin/
│   ├── port-traffic-dog.sh              # 主脚本
│   └── dog                              # 快捷启动命令
│
├── /etc/port-traffic-dog/               # 配置与数据目录
│   ├── config.json                      # 主配置文件
│   ├── traffic_data.json                # nftables 计数器灾备数据
│   ├── traffic_stats.json               # 自然日快照统计
│   ├── reset_history.log                # 流量重置历史
│   ├── config.lock/                     # 配置写入锁目录，运行中临时出现
│   ├── traffic_stats.lock/              # 快照写入锁目录，运行中临时出现
│   ├── logs/
│   │   ├── traffic.log                  # 运行日志
│   │   └── notification.log             # 通知日志
│   └── notifications/
│       ├── telegram.sh                  # Telegram 通知模块
│       └── wecom.sh                     # 企业微信通知模块
│
└── /etc/port-traffic-dog-migration-backup/
    └── YYYYMMDD-HHMMSS/                 # 迁移脚本自动备份目录
        ├── port-traffic-dog-config/     # 旧配置备份
        ├── port-traffic-dog.sh.bak      # 旧主脚本备份
        ├── dog.bak                      # 旧快捷命令备份
        ├── root.crontab.bak             # 迁移前 root 定时任务
        └── nftables-table.bak           # 迁移前 nftables 表（存在时）
```

`migrate-to-custom.sh` 和 `alpine-port-traffic-dog-preinstall.sh` 是安装/迁移时临时下载执行的辅助脚本，不会默认常驻到固定系统路径；如果在 `/root` 下下载，路径通常分别是 `/root/migrate-to-custom.sh` 和 `/root/alpine-port-traffic-dog-preinstall.sh`。

## 注意事项

- 脚本可能会修改系统配置或安装依赖，建议先在测试环境执行。
- 使用通知功能前，请先完成 Telegram / 企业微信配置。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。
- `tc qdisc del dev <iface> root` 会清理该网卡根队列，若同机有其他 QoS 业务请先确认。
