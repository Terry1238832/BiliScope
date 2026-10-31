# BiliScope

iOS/本地版「B 站流量接管」实验项目：只处理 B 站域名，其他流量一律不碰。

## 来源与致谢

这是 **Bilibili 线程撕裂者（BTR）** 在 iOS 端的实现思路移植：

- 上游项目：[MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)
- 作者：MrTangLuyao，MIT License
- **复用的思路**：多 Range 并发下载、多 CDN 镜像竞速、只接管 B 站媒体 CDN、
  「保留原生播放器」的产品取舍；
- **没有复用的东西**：上游是一份运行在浏览器里的 JavaScript 用户脚本，本项目没拷贝
  其中任何一行代码；iOS 侧是全新的 Swift 实现（NIO 做 MITM 入口、
  Network.framework 做上行），因为 iOS 原生 App 没有 MSE、也无法注入 JS。

网页端请直接安装上游的油猴脚本，效果更好；这个仓库只解决 iOS 上原生 B 站 App 的加速。

本项目与哔哩哔哩官方无任何关联，不绕过会员、登录、区域、清晰度或 DRM 限制。

## 它做什么

在本机跑一个 HTTP 代理，把 `*.bilivideo.com`、`*.hdslb.com` 等 B 站媒体 CDN 的
HTTPS 连接做本地终止，然后把播放器的每个 `Range` 请求拆成多个并发分片下载，
按顺序拼回给播放器。B 站 API、登录、其他网站都不解密。

- **只接管白名单**：`HostPolicy` 是硬编码的 B 站域名表，命中不了的域名只做 TCP
  盲转发：不解密、不解析、不记录，日志里连域名都不会出现。代码里没有任何
  「全量代理」开关。
- **多 Range 并发**：`RangePlanner` 按 `chunkSize` 切片，`MITMProxy` 用
  `concurrency` 个上行连接并行拉取、按序下发；分片大小按剩余长度自适应，
  小文件也能铺满所有连接。
- **多 CDN 镜像竞速**：B 站同一个签名分片在 `upos-*-mirror*.bilivideo.com`
  多个镜像上内容完全一致（已实测 sha256 相同）。代理会同时向所有镜像要
  1 MB 首片，谁先回来就用谁，并在 5 分钟内记住赢家。海外常见的 Akamai 分片
  （`upos-<region>-mirrorakam.akamaized.net`）也会一起竞速，不会因为被分到
  Akamai 就失去加速。
- **本地 CA**：首次运行生成根证书，iOS 通过 `.mobileconfig` 安装并信任。

## 当前状态

| 模块 | 状态 |
| --- | --- |
| 域名白名单 / 路由 | ✅ 单元测试覆盖 |
| 端到端集成测试（本地 TLS 源站 + curl 走代理） | ✅ 2 个用例 |
| CA / 站点证书 / mobileconfig | ✅ 单元测试覆盖 |
| NIO MITM 代理（动态 TLS） | ✅ 已跑通 |
| Range 分片并发 | ✅ 已跑通 |
| macOS CLI | ✅ |
| iOS App 壳 + 证书安装 + 后台保活 | 🚧 进行中 |

## 本机验证

```bash
swift build
.build/debug/biliscope-proxy --port 8899 --ca-dir .dev-ca --chunk-size 524288 --concurrency 8
```

另开终端，用真实 B 站分片对比：

```bash
curl -x http://127.0.0.1:8899 --cacert .dev-ca/ca-cert.pem \
     -r 0-4194303 -H 'Referer: https://www.bilibili.com/' "$SEGMENT_URL" -o proxy.m4s
```

实测（2026-10-30，墨尔本→B 站 CDN）：

```
direct: 206 4194304B 5.22s
proxy : 206 4194304B 4.00s    sha256 完全一致
```

非 B 站域名（`example.com`）走盲转发，正常 200，未被解密。

镜像竞速 + 自适应分片实测（5.4 MB 分片，客户端被指向大陆慢镜像 `upos-sz-mirrorcos`，
各跑 3 次）：

```
直连慢镜像 : 20.1s / 57.3s / 6.4s      （抖动极大，272 KB/s → 95 KB/s → 859 KB/s）
经代理     : 0.94s / 0.84s / 0.93s     （约 6 MB/s，竞速选中 upos-sz-mirroraliov）
sha256     : 完全一致
```

代理会根据剩余长度自动决定分片大小（`remaining / concurrency`，夹在 256 KB 到 2 MB
之间），小文件也能吃满多条连接，而不是只开两三条。

## iOS 路线说明

iOS 上「接管原生 App 流量」只有两种可能：

1. **Network Extension**（系统级 VPN）——需要付费开发者账号，本项目暂不使用。
2. **Wi-Fi 系统代理指向本机**（当前路线）——免费个人账号可签，代价是仅 Wi-Fi
   生效、需安装根证书、App 需后台音频保活。

## 退路：Mac 常开 + 局域网代理

如果 iPhone 上 Wi-Fi 代理填 `127.0.0.1` 不生效，或 B 站 App 根本不吃系统代理，
可以让代理跑在一台常开的 Mac 上，iPhone 通过局域网连过去：

```bash
swift build
.build/debug/biliscope-proxy --lan
```

输出会直接给出两个地址：

```
iPhone Wi-Fi 代理 -> 192.168.x.x:8888
iPhone 证书地址   -> http://192.168.x.x:8899/ca.mobileconfig
```

顺序很重要：先在 iPhone Safari 打开证书地址、安装并打开完全信任，再把 Wi-Fi 代理
改成 Mac 的 IP。LAN 模式默认只接受私有网段的客户端（`127` / `10` / `192.168` /
`172.16-31`），可用 `--allow 192.168.1.` 之类的参数收窄；不匹配的客户端会在
TCP 层直接被断开。

这两种模式共用同一套白名单和镜像竞速代码，B 站以外的域名同样不解密。

## iOS App

`App/` 里是 SwiftUI 壳。`BiliScope.xcodeproj` 已经提交，直接 `open` 即可；
只有增删源文件需要重新生成工程时，才装一下 XcodeGen：

```bash
brew install xcodegen
cd App && xcodegen generate && open BiliScope.xcodeproj
```

**没有付费开发者账号也能用**：这个 App 不需要任何 entitlement（没有 Network
Extension、没有 App Groups、没有推送），只是一个普通 App 加一条后台音频声明，
所以免费 Apple ID 的 Personal Team 就能签。限制是：7 天有效期、同时最多 3 个
自签 App、不能上架或 TestFlight。到期后连电脑重新 Run 一次即可。

真机自签（免费个人账号即可）：

1. Xcode → Settings → Accounts 登录你的 Apple ID（免费即可）；
2. Target → Signing & Capabilities → Team 选「你的名字 (Personal Team)」，
   Bundle ID 改成唯一值（例如 `com.yourname.biliscope`）；
3. 连上 iPhone，先在手机上打开 设置 → 隐私与安全性 → 开发者模式；
4. Run；
5. 首次运行后到 设置 → 通用 → VPN 与设备管理 信任开发者；
4. 打开 App（默认启动即开代理）→ 安装根证书 → 设置里打开完全信任；
   App 会检测证书是否被信任，未信任时首页会显示橙色警告；
5. 设置 → 无线局域网 → 当前网络 ⓘ → 配置代理 → 手动 → 服务器 `127.0.0.1`、
   端口 `8888`、**认证关闭**（本代理不支持用户名密码，开了会连不上）；
6. 打开 B 站 App 播放视频，回到本 App 的日志里应出现 `accelerated`。

免费账号签的 App 7 天过期，过期后重新 Run 一次即可。

如果 `127.0.0.1` 不被 iOS 接受，App 里可以把监听地址切到「Wi-Fi 地址」，再把
Wi-Fi 代理填成 `<手机 Wi-Fi IP>:8888`。这条路径只接受手机自身 IP，局域网里别的
设备连不上；模拟器受 macOS 本地网络权限限制验证不了，需要在真机上试。

真机怎么试、结果怎么读：见 [docs/device-test.md](docs/device-test.md)。

### 已验证 / 未验证

- ✅ 模拟器：代理启动、CONNECT、MITM、Range 分片、自检 206 全部通过；
- ✅ 模拟器：根证书加入信任后，B 站 CDN 图片请求返回 206；
- ✅ 模拟器：未信任时首页显示橙色警告，自检提示「根证书还没被系统信任」；
- ✅ 模拟器：证书安装页在代理关闭时也能打开，Safari 正常弹出「下载配置描述文件」；
- ✅ 模拟器：非 B 站域名（example.com）经代理返回 200，日志中不出现该域名；
- ✅ 集成测试：本地 TLS 源站 + 真实代理进程，Range 拆分后 206 字节完全一致；
- ✅ 集成测试：白名单外的 TLS 流量走盲隧道，不被解密；
- ✅ 真实 Akamai 分片：4 MB 经代理 0.37s，8 片并发，sha256 与直连一致；
- ✅ 模拟器：B 站 API 走盲隧道记 `tunnel`，媒体走 `accelerated`，首页分别计数；
- ✅ `iphoneos arm64` 编译通过（`xcodebuild -sdk iphoneos`），不依赖任何 entitlement；
- ⚠️ 真机：Wi-Fi 代理填 `127.0.0.1` 是否被 iOS 接受、B 站 App 是否吃系统代理，
  这两点只能在真机上验证，是整条路线的最大风险。

如果真机验证失败，唯一退路是付费账号 + Network Extension（系统级 VPN）。

## 目录

```
Sources/BiliScopeCore/     代理、证书、白名单、分片
Sources/biliscope-proxy/   macOS 命令行入口
Tests/BiliScopeCoreTests/  单元测试
App/                       iOS SwiftUI App（XcodeGen 工程）
```
