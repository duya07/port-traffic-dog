# port-traffic-dog

端口流量监控、配额、到期封锁与限速脚本（单文件 Bash，基于 nftables + tc）。

- 上游来源：<https://github.com/zywe03/realm-xwPF>（`port-traffic-dog.sh` 与 `notifications/`）
- 2.0 是一次核心重写：监控项改用稳定 ID，**已有监控项可以直接增删端口而不丢流量**；从 1.5.x 原地升级会无损迁移计数、配额与设置。
- 2.1：界面重排（主菜单两组竖排编号、监控项表格按显示宽度对齐、子菜单统一样式），可以**按监控项关闭推送**（见“6) 通知”）。
- 1.5.x 的逐条改动记录见 1.5.23（提交 `8371863`）的 README。

## 2.0 有什么不同

| | 1.5.x | 2.0 |
| --- | --- | --- |
| 监控项身份 | 端口字符串（`"8031,8032"`），改端口 = 删了重建、流量清零 | 稳定 ID `m1`、`m2`…，端口只是成员，可随时 `--add/--del/--set` |
| nft 规则 | 每端口一组规则，双向计费靠重复规则把计数翻倍 | 区间 verdict map 分派到每个监控项的链；增删端口只改 map 元素；计数器存原始字节，计费倍率在软件里乘 |
| 定时任务 | 7 条以上（快照、重置、到期、机器流量…） | 每分钟一个 `--tick`、一个 `@reboot --boot`，开了推送再各加一条 `--send-status` |
| 通知 | 外置 `telegram.sh` / `wecom.sh` 模块 | 内置；读不到计数时发明确的异常提示，**不会再推送空报告** |
| 更新 | 下载 main 分支 | 只下载 GitHub Release 资产，并按 `SHA256SUMS` 校验 |
| 运行环境 | 依赖 crontab 首行 `PATH=` | 脚本自己补齐系统 PATH（1.5.x 曾因该行丢失推送空消息） |
| 其他 | | 拆分 / 合并监控项；配置变更写审计日志；`--repair` 清理孤儿 TC 类；时区固定北京时间（不依赖 tzdata） |

要求：Bash 4+、nftables ≥ 0.9.2、jq、iproute2、cron、flock、curl。真实内核实测：Debian 12（6.1，nft 1.0.6）与 Debian 13（6.12，nft 1.1.3）；Ubuntu、Alpine 只做过静态检查。限速需要内核 `sch_htb`、`cls_fw`、`cls_flower`、`ifb`、`act_mirred`。

## 1) 安装

```bash
wget -O port-traffic-dog.sh https://github.com/duya07/port-traffic-dog/releases/latest/download/port-traffic-dog.sh
bash port-traffic-dog.sh            # 首次运行自动安装到 /usr/local/bin 并创建 dog 命令
```

国内网络可在 URL 前加 `https://v6.gh-proxy.org/`。

Alpine 先运行预装脚本补齐依赖（bash、nftables、iproute2、jq、dcron、curl、util-linux 等）并启动 `crond`：

```bash
wget -O alpine-port-traffic-dog-preinstall.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/alpine-port-traffic-dog-preinstall.sh
sh alpine-port-traffic-dog-preinstall.sh
```

## 2) 从 1.5.x 升级

**只保证从 1.5.x 无损升级**（更早版本请先升级到 1.5.23）。三种方式结果相同：

1. 菜单“更新”或 `dog --update`：1.5.x 的更新器会装上 2.0，再由 2.0 执行迁移（为此仓库保留了 `telegram.sh` / `wecom.sh`，它们只供 1.5.x 更新器完整性检查使用，2.0 不再加载）。
2. `migrate-to-custom.sh`（也适用于上游原版 1.4.x/1.5.x）：

   ```bash
   wget -O migrate-to-custom.sh https://raw.githubusercontent.com/duya07/port-traffic-dog/main/migrate-to-custom.sh
   sudo bash migrate-to-custom.sh            # --yes 跳过确认；--from-dir DIR 使用离线发布目录
   ```

   它从 Release 下载并按 `SHA256SUMS` 校验，备份到 `/etc/port-traffic-dog-migration-backup/<时间>/`，新版维护失败会整体回滚。
3. 手动覆盖脚本后运行 `dog --repair`。

迁移做了什么：

- 每个旧端口键变成一个监控项（按端口排序分配 `m1`、`m2`…），备注、计费方式、配额、重置策略、到期日、限速、通知配置原样保留。
- 计数从内核读取并换算成原始字节：旧双向计费的计数器本来就被重复规则翻倍，迁移时 ÷2，界面和推送显示的计费流量与升级前一致。读不到内核计数时用 `traffic_data.json` 灾备。
- 旧 nft 对象、旧定时任务和 `notifications/` 目录被替换；root crontab 里的其他任务和 `PATH=` 行不动。
- 迁移前状态备份在 `/etc/port-traffic-dog/backups/migrate-1.5-<时间>/`（配置、crontab、nft 表、tc 状态、灾备文件）。
- 上游 1.4.x 的端口组计数无法逐项拆分，只能使用 `traffic_data.json` 中的值；`migrate-to-custom.sh` 会先提示再继续。

回退到 1.5.x（不常用）：先用迁移备份里的 `crontab.txt` 恢复定时任务，删除 `inet port_traffic_monitor` 表，把迁移备份里的文件放回 `/etc/port-traffic-dog/`、装回 1.5.x 脚本，再运行 `port-traffic-dog.sh --restore-nft-runtime`。想保留升级后产生的流量，需先把 2.0 计数（`dog list --json`）乘以计费倍率写进 `traffic_data.json`。

## 3) 使用

`dog` 打开菜单；所有操作也有命令行入口，加 `--yes` 可跳过确认：

```text
dog list [--json]                     列出监控项
dog status                            打印状态报告（与推送内容相同，不发送）
dog add 8080                          一个端口
dog add 80,443 --remark web           一个监控项包含多个端口
dog add "80;443"                      两个监控项
dog add 8000-8010                     端口段
dog edit m1 --add 8443                增加端口（流量连续）
dog edit m1 --del 80 | --set 80,8443  删除端口 / 整组替换
dog edit m1 --quota 500GB | 0         配额（0 = 不限）
dog edit m1 --billing double|single   计费：双向 (入+出)×2，单向 入+出
dog edit m1 --limit 100Mbps | 0       带宽限制（上下行各自生效）
dog edit m1 --expiry 2027-02-10 | 0   服务到期日
dog edit m1 --reset monthly:1 | days:30[@起始日] | months:3[@起始日][:结算日] | yearly:1-1 | once:YYYY-MM-DD | none
dog split m1 8443 [--copy]            把端口拆成新监控项（--copy 复制配额/重置/到期）
dog merge m2 m1                       合并：流量相加，保留 m1 的设置
dog reset m1                          立即清零本周期流量（不改下次重置日）
dog remove m1
dog edit m1 --notify off              不出现在状态推送中（默认 on；只影响推送，统计与配额照常）
```

`edit/remove/reset` 也接受端口号代替 ID。一个端口只能属于一个监控项，重叠会被拒绝。

菜单分两组，编号竖排：左列“监控项”——1 添加、2 改端口、3 删除、4 配额与重置、5 带宽限制、6 到期日、7 计费与备注、8 立即重置、9 通知；右列“系统维护”——10 自检/修复、11 TC 冲突处理、12 IP Guard、13 依赖管理、14 导入导出、15 操作日志、16 更新、17 卸载（编号与 2.0 相同）。终端宽度不够两列时自动改为单列；监控项表格宽屏显示用量条，较窄时只显示百分比，再窄时每项占两行。

### 维护命令

| 命令 | 作用 |
| --- | --- |
| `dog --self-check` | 检查依赖、cron 最小环境能否找到 nft、cron 服务、配置、nft 规则与配置是否一致、限速对象、定时任务、灾备时效、通知配置 |
| `dog --repair` | 补依赖（不加 `--yes` 时先询问）、迁移旧配置、重建 nft 规则与限速、清理孤儿 TC 类、刷新定时任务，然后自检 |
| `dog --tc-status` / `--recover-tc --manual` | 只读查看统一 HTB 状态 / 显式重建（可能删除冲突的 root qdisc） |
| `dog --restore-runtime` | 按配置与灾备恢复 nft 与 TC |
| `dog --export [目录]` / `--import 文件` | 导出 / 导入配置包（导入失败整体回滚，拒绝含 `..` 等不安全路径的归档） |
| `dog --dependencies check\|install\|owned\|remove` | 依赖检测、安装缺失项、查看本脚本新增的包、按账本卸载 |
| `dog --logs` | 最近的操作审计日志 |
| `dog --update [--force]` | 从 Release 更新（校验 `SHA256SUMS`，失败回滚；同版本不重装、拒绝降级，`--force` 可强制） |
| `dog --uninstall [--keep-config]` | 删除规则、限速、定时任务和脚本；默认连配置一起删 |

1.5.x 的命令名（`--snapshot-traffic`、`--send-telegram-status`、`--restore-nft-runtime` 等）仍可调用，映射到 2.0 的对应功能。

## 4) 统计、配额、重置与到期

- 计数器保存原始字节；计费流量 = 原始字节 × 倍率（双向 2、单向 1）。配额在 nft 中按 `配额 ÷ 倍率` 下发，界面进度与内核阻断用同一口径。
- 每分钟 `--tick`：规则缺失时自动恢复、同步到期封锁、执行到期的重置、保存灾备 `traffic_data.json` 与自然日统计 `traffic_stats.json`（保留 `.global.data_retention_days` 天，默认 400）、采集整机流量。
- 重置策略：每月某日、每 N 天、每 N 月（可指定结算日）、每年某日、指定日期一次。31 日遇小月按月末，2 月 29 日遇平年按 28 日。同一到期日只清零一次（`reset_history.json`）。
- 服务到期：北京时间到期日 00:00 起封锁该监控项全部端口的 TCP/UDP 入站、出站与转发；不影响流量与配额；延期或取消立即解封。
- 所有日期按北京时间（固定 UTC+8），与 VPS 时区和是否安装 tzdata 无关。

## 5) 带宽限制与 TrafficCop Lite

- 出向：nft 给命中端口的包打 fw mark（`0x50000000 | minor<<12`，只占高 20 位，保留低 12 位给其他程序），`tc` fw 过滤器送进该监控项的 HTB 类（`1:4001` 起）。入向：通过 `ifb0` 重定向，每个端口 8 条 flower 过滤器。增删端口时出向随 nft map 自动生效，入向过滤器同步重建。
- 与 [TrafficCop Lite](https://github.com/duya07/trafficcop-lite)（NTC）共用统一 HTB：NTC 管 `1:1` 整机上限和 `1:30` 默认类，Dog 管端口子类；改同一张网卡的 TC 时共用 `/run/lock/traffic-tools-tc.lock`。Dog 在锁内把限速类写进 `/etc/port-traffic-dog/tc-interop.json`（`traffic-tools-dog-classes-v1`）供 NTC 核对。
- **Dog 2.0 设置限速需要 NTC 1.2.0+**；检测到旧版 NTC 会拒绝并提示先升级。
- 外部程序改了 root qdisc 时，普通操作和开机恢复都拒绝覆盖，需在菜单 11 确认后重建。**不要与上游原版 TrafficCop 的 TC 模式同时运行**：它在流量正常时每分钟删除网卡 root qdisc。
- 可选的 `traffic-tools-tc-recovery.service`（Dog/NTC 共用，默认不启用）在开机网络就绪后恢复一次。

## 6) 通知

菜单 9 配置 Telegram（官方或自定义 HTTPS 线路；HTTP 只允许本机回环）和企业微信 Webhook，可设推送间隔。状态推送内容与 `dog status` 相同；nft 表或计数器缺失时推送“流量读取失败，请运行 dog --repair”，而不是空报告。

按监控项开关推送（2.1）：菜单 9 →“选择推送的监控项”勾选（输入序号切换，可一次输入多个；`a` 全部推送、`n` 全部不推送），或 `dog edit m2 --notify off`。关闭的监控项不出现在推送里，报告头的“监控项 N 个”和周期总流量也不计入，接收方看不到它；它的计数器缺失也不会触发告警。所有监控项都关闭时不发送（不发空报告），只在 `notification.log` 记一条“状态报告未发送”。拆分出的新监控项继承原项的推送开关；合并以目标项为准。配置字段为 `.monitors.<id>.notify`（缺省为 true）；降级回 2.0.0 时该字段被忽略，即恢复全部推送。

## 7) IP Guard（在线 IP / 并发连接限制，测试中）

菜单 12 管理独立组件 `/etc/port-traffic-dog/port-ip-guard.sh`：按本机 TCP 服务端口限制在线 IP 数和并发连接数（IPv4/IPv6 合计，`0` 为不限）。新 SYN 经 NFQUEUE（默认队列 `47683`）串行准入，超限拒绝新连接、不断开已有连接；消费者不可用或队列满时放行。需要 Python 3 与 `libnetfilter-queue1`，使用独立 nft 表与 systemd 服务 `port-traffic-dog-ip-guard.service`。不统计 UDP，不保护 FORWARD/DNAT 流量。配置示例：

```json
{"schema": "port-traffic-dog-ip-guard-v1",
 "ports": {"8443": {"max_ips": 2, "max_connections": 20, "idle_timeout": 300}}}
```

## 8) 文件

```text
/usr/local/bin/port-traffic-dog.sh   主脚本
/usr/local/bin/dog                   快捷命令
/etc/port-traffic-dog/
  config.json                        配置（schema 2）
  traffic_data.json                  计数灾备
  traffic_stats.json                 自然日统计
  reset_history.json                 重置历史
  tc-interop.json                    给 NTC 的限速类清单
  tc-root-qdisc.owner                Dog 创建的 root qdisc 归属标记
  backups/                           迁移与更新前备份
  logs/traffic.log                   操作审计（1 MiB 轮转）
  logs/notification.log              推送记录
  port-ip-guard.sh                   IP Guard 组件
/var/lib/port-traffic-dog/dependencies/   本脚本新增软件包的账本
```

nft 对象都在 `inet port_traffic_monitor` 表中，名字以 `ptd_` 开头。卸载后的兜底检查：

```bash
sudo nft list table inet port_traffic_monitor 2>/dev/null && echo "nft 表仍在"
IFACE=$(ip route | awk '/default/ {print $5; exit}'); sudo tc qdisc show dev "$IFACE"; ip link show ifb0 2>/dev/null
sudo crontab -l | grep -E 'port-traffic-dog' || echo "cron 已清理"
```

## 9) 开发

源码在 `src/`（按编号拼接），`port-traffic-dog.sh` 是构建产物，**改完 `src/` 后运行 `tools/build.sh` 并提交两者**（`tools/build.sh --check` 校验一致）。

```bash
tools/build.sh
bash tests/v2/unit.sh                 # 纯函数
sudo bash tests/v2/core.sh            # unshare -n 中跑真实 nft
sudo bash tests/v2/upgrade-1.5.sh     # 私有挂载中运行真实 1.5.23 更新器与 migrate-to-custom
bash tests/logging.sh; python3 tests/dependencies.py; python3 tests/menu-layout.py; bash tests/ip-guard-regression.sh
```

真实 TC 测试（会让内核加载 ifb/sch_htb 等全局模块）只在可丢弃的测试机上跑，入口在 TrafficCop Lite 的 `tests/integration-netns.sh`（`DOG_SCRIPT=…/port-traffic-dog.sh`）。

发布：`tools/release.sh v2.1.0` 生成 `dist/port-traffic-dog.sh`、`dist/port-ip-guard.sh`、`dist/SHA256SUMS`，再 `gh release create v2.1.0 dist/*`。`--update` 与 `migrate-to-custom.sh` 只接受与 `SHA256SUMS` 一致的 Release 资产。
