# port-traffic-dog

基于公开项目脚本进行适配和修改的 `port-traffic-dog` 自定义版本。

> 脚本仅用于个人使用场景，请在执行前自行审阅内容，并根据实际环境调整配置。

## 脚本说明

### 端口流量狗

#### 2.1 port-traffic-dog.sh

参考/引用：

- 上游项目说明：[realm-xwPF/port-traffic-dog-README.md](https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog-README.md)
- 上游主脚本：[realm-xwPF/port-traffic-dog.sh](https://github.com/zywe03/realm-xwPF/blob/main/port-traffic-dog.sh)
- 上游通知模块目录：[realm-xwPF/notifications](https://github.com/zywe03/realm-xwPF/tree/main/notifications)

修改说明：

1) 通知模块同步策略（重点）：

- 优先读取 `port-traffic-dog.sh` 同目录下的 `telegram.sh` / `wecom.sh`。
- 同步到运行目录 `/etc/port-traffic-dog/notifications/` 时，改为“仅补齐缺失”：
  - 本地已有文件不覆盖；
  - 远程下载模块也只补缺失、不覆盖。

2) Telegram 状态通知排版优化：

- 移除原先头部介绍文案，改为更简洁的状态卡片。
- 顶部显示：`🔗 服务器 | ⏰ 时间`
- 端口区支持编号、多行明细、配额百分比与周期显示。
- 新增文本进度条（按百分比渲染），用于快速查看配额使用情况。

3) Telegram 通信线路切换（官方/自定义）：

- 新增菜单入口：`通知管理 -> Telegram通信线路切换`。
- 支持切换：
  - 官方线路（`https://api.telegram.org`）
  - 自定义线路（可输入 API 基础地址）
- 配置项新增：
  - `.notifications.telegram.api_route`
  - `.notifications.telegram.custom_api_base`

4) 其他行为说明：

- `port-traffic-dog.sh` 不会在每次运行时自动更新自身。
- 只有手动执行“安装依赖(更新)脚本”时，才会拉取并替换主脚本。
- 针对通知模块更新已改为“只补缺失不覆盖”。

> 当前修改尚未完全测试，请在生产环境使用前先进行验证。

安装并运行：

```bash
wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh
chmod +x port-traffic-dog.sh
./port-traffic-dog.sh
```

Alpine 安装并运行：

```bash
wget -O alpine-port-traffic-dog-preinstall.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/alpine-port-traffic-dog-preinstall.sh && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/port-traffic-dog.sh && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

Alpine 一键试用（可替换仓库）：

```bash
REPO="duya07/port-traffic-dog"; wget -O alpine-port-traffic-dog-preinstall.sh "https://raw.githubusercontent.com/${REPO}/main/alpine-port-traffic-dog-preinstall.sh" && chmod +x alpine-port-traffic-dog-preinstall.sh && ./alpine-port-traffic-dog-preinstall.sh && wget -O port-traffic-dog.sh "https://raw.githubusercontent.com/${REPO}/main/port-traffic-dog.sh" && chmod +x port-traffic-dog.sh && ./port-traffic-dog.sh
```

Alpine 预装脚本已同步更新，包含：

- 依赖补齐：`curl/tzdata` 等；
- `cron` 命令兼容处理（`cron` -> `crond`）；
- `crond` 启动与开机启动注册；
- 安装后命令级自检（`nft/tc/ss/jq/awk/bc/unzip/cron/curl/bash`）。

#### 2.2 telegram.sh

修改说明：

- 支持按配置切换 Telegram 通信线路（官方 / 自定义）。
- 自定义线路支持输入 API 基础地址，并自动拼接 `sendMessage` 地址。
- 兼容自定义地址以 `/bot` 结尾的场景。
- 保持默认 `parse_mode=HTML`，并适配新的状态消息格式。

安装并运行：

```bash
wget -O telegram.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/port-traffic-dog/main/telegram.sh
chmod +x telegram.sh
./telegram.sh
```

## 目录文件

```text
.
├── PORT_TRAFFIC_DOG_CUSTOM.md
├── alpine-port-traffic-dog-preinstall.sh
├── port-traffic-dog.sh
├── telegram.sh
└── wecom.sh
```

## 注意事项

- 脚本可能会修改系统配置或安装依赖，建议先在测试环境运行。
- 如需使用通知功能，请提前准备好 Telegram 或企业微信相关配置。
- 若脚本下载失败，可检查代理地址或手动替换为可访问的 raw GitHub 地址。
