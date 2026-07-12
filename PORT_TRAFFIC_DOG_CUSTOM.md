# Port-Traffic-Dog 自定义改动说明

本文档用于说明本仓库相对上游 `realm-xwPF` 的关键改动与用法。

## 1. 参考与引用

- 上游仓库：<https://github.com/zywe03/realm-xwPF>
- 上游主脚本：<https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh>
- 上游通知模块：<https://github.com/zywe03/realm-xwPF/tree/main/notifications>

## 2. 核心改动

### 2.1 通知模块“只补缺失，不覆盖”

- 同步通知模块时，优先读取主脚本同目录下的 `telegram.sh` / `wecom.sh`。
- 复制到 `/etc/port-traffic-dog/notifications/` 时仅在目标文件不存在时才复制。
- 远程下载模块时也仅补缺失，不覆盖已有文件。

适用场景：保留你本地自行修改过的通知脚本，避免被后续初始化流程覆盖。

### 2.2 Telegram 状态通知版式优化

- 顶部改为：`🔗 服务器 | ⏰ 时间`
- 状态区保留：监控状态、端口数量、端口总流量
- 端口区新增：
  - 编号
  - 多行明细
  - 配额百分比
  - 计费周期
  - 文本进度条

### 2.3 Telegram 通信线路切换

新增配置与菜单：

- 菜单路径：`通知管理 -> Telegram通信线路切换`
- 线路选项：
  1. 官方（`https://api.telegram.org`）
  2. 自定义（输入 API 基础地址）

新增配置字段：

- `.notifications.telegram.api_route`
- `.notifications.telegram.custom_api_base`

说明：

- 自定义地址支持常规 `https://example.com` 形式；
- 也兼容以 `/bot` 结尾的地址拼接。

### 2.4 Alpine 预装脚本同步增强

`alpine-port-traffic-dog-preinstall.sh` 已更新：

- 依赖补齐（含 `curl`、`tzdata`）；
- `cron` 命令兼容处理（`crond` 链接到 `cron`）；
- 自动启动 `crond` 并尝试注册开机启动；
- 安装完成后执行命令级自检。

## 3. 行为差异说明

- `port-traffic-dog.sh` 本体不会在每次运行时自动更新覆盖。
- 手动执行“安装依赖(更新)脚本”时才会拉取并替换主脚本。
- 通知脚本策略已改为“只补缺失，不覆盖已有”。

### 2.6 兼容升级与运行安全

- 旧配置中的 `quota.reset_day` 会继续按每月指定日期执行，新版只补充 `reset_policy`，不会要求重新添加端口。
- 更新主脚本后由新版本进程刷新 cron 并修复流量规则，避免更新前进程继续使用旧函数。
- Telegram / 企业微信状态通知同时检查通道总开关和状态通知开关；没有监控端口或通道关闭时不会保留发送任务。
- 新增端口或端口段会拒绝与已有范围重叠，避免重复计数和重复配额阻断。
- 配置导入会校验归档内容并保留临时回滚副本；复制失败时恢复原配置、规则和 cron。

## 4. Alpine 一键试用

```bash
REPO="duya07/port-traffic-dog"; wget -O alpine-port-traffic-dog-preinstall.sh "https://raw.githubusercontent.com/${REPO}/main/alpine-port-traffic-dog-preinstall.sh" && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh "https://raw.githubusercontent.com/${REPO}/main/port-traffic-dog.sh" && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

使用时将 `REPO` 替换为你的 GitHub 仓库路径即可。
