# port-traffic-dog

基于上游项目定制的端口流量监控脚本集合。

## 参考来源

- 上游仓库: <https://github.com/zywe03/realm-xwPF>
- 上游主脚本: <https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh>
- 上游通知模块: <https://github.com/zywe03/realm-xwPF/tree/main/notifications>

## 功能概览

- **端口流量统计**：nftables counter 统计端口/端口段双向流量；每分钟写自然日快照（`traffic_stats.json`）并维护 counter 灾备（`traffic_data.json`）。
- **计费口径**：双向 `入站×2 + 出站×2`；单向 `入站 + 出站`；counter 与 quota 使用同一倍率。
- **流量配额**：支持 月 / 每 N 天 / 每 N 月 / 每年 / 指定日期 清零；达量由 nftables quota 直接阻断。
- **端口限速**：统一 HTB 下每端口一个子类，nft 标记 + 单条 `protocol all` 的 `fw` 分类器（覆盖 IPv4/IPv6）；支持 `Kbps/Mbps/Gbps`，`0` 为无限制。
- **服务到期封锁**：按北京时间封锁到期端口的 TCP/UDP 入站、出站与转发，延期/取消立即解锁。
- **来源 IP 并发限制（测试中）**：独立组件 `port-ip-guard.sh`，按 conntrack 双向元组识别真正进入本机服务的来源 IP。
- **通知**：Telegram（官方线路 / HTTPS 自定义线路）、企业微信，支持状态通知与定时报告。
- **安全与可恢复**：配置文件与运行状态原子写入并加锁；读取/解析失败一律失败关闭；更新、迁移、导入失败自动回滚；不覆盖外部文件与第三方 TC。
- **与 TrafficCop Lite 共存**：共用统一 HTB（NTC 的 `1:1` 父类承担整机上限，Dog 维护端口子类）、共享 `/run/lock/traffic-tools-tc.lock`，root crontab 锁各自独立。
- **菜单**：`8` 系统自检/修复、`9` TC 冲突处理/自动恢复、`10` 来源 IP 并发限制。

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

Alpine 预装脚本会补齐 `bash/nftables/conntrack-tools/iproute2/jq/gawk/bc/unzip/dcron/ca-certificates/curl/util-linux-misc/tzdata` 等依赖，创建 `cron -> crond` 兼容命令，启动并注册 `crond`，并检查 `nft/tc/ss/jq/awk/bc/unzip/cron/crontab/curl/bash/conntrack/flock` 是否可用。

## 3) 旧 VPS 迁移到定制版

迁移脚本会先以仅 root 可读的权限备份配置、主脚本、快捷命令、root crontab 和现有 nftables 表，再完整下载并校验主脚本、两个通知模块、独立 IP Guard 组件及当前配置；全部校验通过后才覆盖安装。若 IP Guard 服务原本正在运行，迁移后会重启并核验新组件；覆盖后的刷新、修复或自检失败时会自动恢复迁移前状态。

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
sudo dog --tc-status
sudo dog --sync-notification-modules
sudo dog --refresh-notification-cron
sudo dog --refresh-port-reset-cron
sudo dog --refresh-all-cron
sudo dog --repair-traffic-rules
sudo dog --snapshot-traffic
sudo dog --restore-runtime
sudo dog --restore-nft-runtime
sudo dog --check-port-expirations
sudo dog --recover-tc --manual
sudo dog --uninstall
```

- `--self-check`: 检查配置结构与端口重叠、计数/配额/限速规则、统计与灾备文件、cron 精确频率、依赖命令、通知模块和 Telegram 连通性。
- `--tc-status`: 只读检查当前 Dog/NTC 统一 HTB 是否完整。
- `--recover-tc --manual`: 显式重建入口。它可能删除当前 root qdisc，通常应优先通过主菜单 `9` 阅读提示并确认后执行。
- `--validate-config FILE`: 只校验指定 JSON 配置，不安装依赖或修改运行状态，供升级和迁移预检使用。
- `--sync-notification-modules`: 从仓库强制覆盖同步 `telegram.sh` / `wecom.sh`。
- `--refresh-notification-cron`: 根据当前配置和监控端口重建通知定时任务，并尝试启动 `cron` / `crond`；没有监控端口时不会保留状态报告任务。
- `--refresh-port-reset-cron`: 根据当前端口重置策略重建自动重置任务，并清理旧版 `--reset-port` 和失效端口残留任务。
- `--refresh-all-cron`: 按当前端口、重置和通知配置刷新全部定时任务，同时清理旧版单端口重置及旧快照任务。
- `--repair-traffic-rules`: 按当前计费模式检查并重建 counter/quota 规则；双向目标为每个方向 8 条 counter 引用、16 条 quota 引用，单向目标为每个方向 4 条 counter 引用、8 条 quota 引用。升级时会按旧规则倍率换算已有 counter，避免已有流量丢失或再次翻倍。
- `--snapshot-traffic`: 立即写入一次自然日流量快照；正常情况下脚本会自动配置每分钟执行一次。
- `--restore-runtime`: 手动按当前配置和 `traffic_data.json` 恢复 nftables/TC 运行状态；不会作为 Dog 的普通开机 cron 自动调用。
- `--restore-nft-runtime`: 只恢复 nftables counter/quota，不修改 TC；Dog 的 `@reboot` 任务使用此入口。
- `--check-port-expirations`: 按北京时间检查全部端口的服务到期日，并只同步 Dog 自己带固定 comment 的封锁规则；正常情况下由每分钟 cron 和独立 `@reboot` 任务调用。
- `--uninstall`: 卸载脚本、配置目录、nftables/tc 规则，并清理通知 cron、自然日快照 cron、开机恢复 cron 和端口自动重置 cron。

主菜单选择 `8. 系统自检/修复`，可主动补齐依赖和通知模块、修正权限与快捷命令、按当前配置重建 cron、恢复 nftables/TC 运行状态、更新自然日快照并执行最终自检。普通打开 `dog` 时不会重复执行这些重操作；只有检测到 nftables 监控规则确实缺失时，才会按原配置自动恢复。

## 5) 流量配额自动重置

添加端口监控时，如果设置了流量配额，脚本会立即提示设置自动重置策略，不需要再到管理菜单里单独改默认日期。

支持的策略:

- 每月几号重置：兼容原脚本逻辑，默认每月 1 日。
- 每隔多少天重置：例如每 30 天重置一次。
- 每隔多少个月重置：例如每 3 个月重置一次，可指定每次按几号结算。
- 每年几月几号重置：适合年度流量包。
- 指定日期清零一次：执行后会自动关闭该端口的自动重置。

日期处理规则:

- 旧配置里的 `quota.reset_day` 会自动继承为“每月几号重置”，例如原来设置每月 2 日重置，会继续按每月 2 日执行。
- 新增或修改周期型策略时，下一次自动重置会从未来日期开始计算，避免刚添加端口就被当天任务重置。
- 第一次批量添加多个有限配额端口时，可选择为每个端口分别设置自动重置策略。
- 指定清零日期为当天时，脚本会询问是否立即重置当前流量；不立即重置则等待下一次周期检查。
- 31 号遇到没有 31 号的月份，会按该月最后一天处理。
- 2 月 29 日遇到非闰年，会按 2 月 28 日处理。
- 自动任务每 5 分钟按北京时间检查一次所有端口，只有到期端口才会真正重置，不依赖 VPS 的系统时区。
- counter 与 quota 在同一个 nftables 事务中以零值重建；事务失败时保留原到期日期并重试。事务成功后读到的非零值属于新周期刚产生的流量，不会被当成失败而重复清零。
- 已成功清零的到期日会写入重置历史；即使下一到期日期暂时保存失败，也不会在五分钟后重复清零。
- cron、手动命令和即时重置共用重置锁，避免同一端口被并发清零两次。
- 手动“立即重置”只清零当前流量，不会自动改变下一次到期日期。

### 5.1 服务到期封锁

服务到期日和上面的流量配额重置是两套独立状态。假设端口每月 1 日重置、服务到期日为 `2026-03-02`，3 月 1 日仍会正常清零，3 月 2 日北京时间 `00:00` 起才封锁端口。

- 设置入口：`流量重置管理 → 服务到期日设置`，格式固定为真实日期 `YYYY-MM-DD`；输入 `0` 取消。
- 到期当天算作已到期。封锁覆盖 TCP/UDP 的 input、output 和 forward，不删除流量、配额或重置配置。
- 延后日期或取消到期会立即删除该端口的到期封锁；删除端口、导入配置和卸载也会清理对应规则。
- 每分钟 cron 负责跨日检查；独立 `@reboot` 检查不等待网络或 TC。若规则被删除，下一次检查会按现有配置恢复。
- 到期规则使用 `ptd_expiry_<端口>` 固定 comment。自检发现缺失、重复、附加了未知条件或存在孤儿规则时会报告异常，不会把外部规则当成自身规则。

### 5.2 来源 IP 并发限制（测试中）

主菜单 `10` 会按需安装并调用独立脚本 `/etc/port-traffic-dog/port-ip-guard.sh`。它限制的是进入本机 TCP 服务端口、当前 conntrack 中允许准入的来源 IP 数，不是账号数，也不支持 UDP。该实验组件只挂载 nftables `input` hook；内核转发或 DNAT 流量不受它限制。

- NAT、CDN、反向代理或用户态四层代理后的多名用户可能共享同一个来源 IP。
- 守护进程会读取本机 IPv4/IPv6 地址，并结合 conntrack 原始/回复两个方向确认本机服务端口；本机主动连接远端同号端口不会占用准入名额。接口地址读取失败时不会按不完整快照刷新名单。
- 半开连接、conntrack 超时和地址伪造会影响统计；新来源的首个 SYN 会被丢弃，准入后依靠 TCP 重传建立连接。
- 组件使用独立 nftables 表和 systemd 服务；进程停止时会尝试 fail-open 解封。无法确认同名表归属时会拒绝覆盖或删除。
- 对当前 SSH 服务端口设置限制需要双重确认。建议先在有控制台或备用管理入口的机器测试。
- Dog 卸载时会先调用独立组件的安全卸载；若无法确认能解除其规则，Dog 会中止卸载而不是遗留封锁。

## 6) 流量统计口径

脚本仍把 nftables counter 作为当前周期流量和配额进度的权威来源；自动重置到期时清零 counter，因此每月、每 N 天、每 N 月、每年和指定到期日都可以沿用原脚本成熟的 counter 逻辑。`/etc/port-traffic-dog/traffic_stats.json` 只作为额外的自然日快照统计文件：

- 双向模式沿用上游的两组规则，计费总量为 `入站×2 + 出站×2`；单向模式保留一组入站和一组出站规则，计费总量为 `入站 + 出站`，不是旧版的“仅 out”。
- counter 与 quota 引用数量和倍率严格一致，因此界面进度达到配额时，nftables 阻断也按同一口径触发。
- 从当前单组双向规则版本升级时，已有双向 counter 和当天快照会按权重 1→2 转换；上游原生双组规则按权重 2 识别，不会重复乘 2。旧单向配置无法还原过去未记录的入站流量，升级后入站从 0 开始累计。

- `last_snapshot`: 记录每个端口上一次采样时的 nftables 入站/出站 counter。
- `daily`: 按北京时间自然日保存每日入站/出站增量。
- 主菜单端口总量、通知消息和配额进度读取当前 nftables counter；自然日快照文件只用于独立日统计，不参与主菜单总量叠加。
- 存在监控端口时，每分钟会自动执行 `dog --snapshot-traffic`；每轮只读取一次全部端口的历史状态、执行一次统计文件原子替换，并同步保存当前 counter 灾备。上一条快照在昨天 23:59、当前快照在今天 00:00 时，边界增量精确补到昨天；若错过边界，无法拆分的增量归入当前日，保证历史总量不丢失也不重复累计。
- 自然日统计依赖 cron 持续运行；若 cron 停止很久或跨日后很久才恢复，停机区间流量会统一归入恢复当天，不能精确拆回每一天，但当前周期 counter 和配额不受影响。
- `traffic_data.json` 仍用于异常退出、开机和规则恢复时保留 nftables counter，不等同于自然日统计文件；恢复失败时会保留备份供下次重试，恢复后也由分钟快照持续刷新。
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
│   ├── tc-root-qdisc.owner              # 本机脚本创建的 TC 根队列归属标记
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
- Dog 的 root crontab 锁位于 `/run/lock/port-traffic-dog-root-crontab.lock/`；TrafficCop Lite 使用自己的锁，两者互不依赖。Dog 的配置、流量快照和重置事务也各自使用 `/run/lock/port-traffic-dog-*.lock/`，因此导入、更新或卸载配置目录时不会把仍在持有的锁一并删除。
- Dog 与 TrafficCop Lite 修改同一网卡的统一 HTB 时共用 `/run/lock/traffic-tools-tc.lock`。TrafficCop Lite 的有效状态存在时，其整机速率优先，Dog 会在该父类下恢复端口限速。
- 外部程序重建 root qdisc 后，Dog 会在主页报告外部/未知 TC 冲突，普通 cron 和限速操作仍会拒绝覆盖。主菜单 `9` 可在明确确认后删除冲突并只重建 Dog/NTC；不会保留任何第三方规则。
- 可选的 `traffic-tools-tc-recovery.service` 只在开机网络就绪后执行一次，只会在 root qdisc 为空闲/默认状态时恢复已有 Dog/NTC 规则；遇到外部或未知 root qdisc 会拒绝自动删除，须从主菜单 `9` 明确确认。运行期间若再次被其他程序覆盖，也需要用户手动恢复；建议关闭其他 TC 管理服务。
