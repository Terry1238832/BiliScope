# BiliScope 隐私政策

生效日期：2026 年 11 月 26 日

本政策适用于 BiliScope（哔哩加速）iOS 和 iPadOS 测试版。

## 网络流量

加速通过设备上的本地代理和 Apple Network Extension 运行。开启加速时，默认路由处理与哔哩哔哩媒体有关的连接和 DNS 请求，以及播放器使用的阿里云 HTTPDNS 网段。代理在设备上解密允许名单内的媒体 HTTPS 连接，以便并发请求视频分片和选择 CDN 节点。允许名单外的 HTTPS 连接保持加密。正常的媒体请求会直接发送给源站或相应的 CDN，DNS 请求会发给相应的解析服务。这些第三方会收到提供连接所需的网络信息，例如你的 IP 地址。

App 不要求注册账号。开发者不运营 VPN 中转服务器，也不会收集、出售或向其他方披露通过加速功能处理的用户流量。App 没有广告或分析遥测。

## 根证书与诊断

根证书及其私钥在设备上生成，并在设备上提供给网络扩展使用。App 不会将私钥发送给开发者或第三方。启用加速需要你在 iOS 设置中安装并信任该证书。

App 和扩展会在设备上保留最近的诊断日志。日志可能含有时间、网络状态、域名、IP 地址和传输统计。「全量排查模式」默认关闭。开启时，更多 IPv4 流量会通过设备上的隧道，日志也可能记录其他网站的主机名。手动运行连通性诊断会连接测试 CDN 和网络探测地址。App 不会自动把日志发给开发者。你可以在系统分享界面自行选择日志的接收方。

## 关闭、移除与反馈

你可以在 App 内关闭加速，通过 iOS 设置移除 VPN 配置和根证书描述文件，并删除 App 以移除其容器内的本地数据。

你通过 TestFlight 提交的反馈、截图及随附的诊断信息由 Apple 处理，并可由开发者查看以排查问题。隐私问题可通过 TestFlight 反馈联系我们。也可以使用 [GitHub Issues](https://github.com/Terry1238832/BiliScope/issues) 提问，那里提交的内容是公开的。

---

# BiliScope Privacy Policy

Effective November 26, 2026

This policy applies to the BiliScope beta for iOS and iPadOS.

## Network traffic

BiliScope runs its proxy and Apple Network Extension on your device. When acceleration is on, the default routes cover selected Bilibili media connections and DNS requests, including Alibaba Cloud HTTPDNS address ranges used by the player. The local proxy decrypts HTTPS connections to allowlisted media hosts to make parallel media requests and select CDN endpoints. HTTPS connections outside the allowlist remain encrypted. Media requests go directly to the origin or the relevant CDN, and DNS requests go to the relevant resolver. These providers receive network information necessary to serve the requests, such as your IP address.

The app requires no account. The developer runs no VPN relay and does not collect, sell, or disclose user traffic processed by the acceleration feature. The app contains no advertising or analytics telemetry.

## Root certificate and diagnostics

Your root certificate and private key are generated on your device and made available to the network extension on the same device. The app does not send the private key to the developer or third parties. To use acceleration, you must install and trust the certificate in iOS Settings.

The app and its extension keep recent diagnostic logs on your device. Logs can include timestamps, network status, hostnames, IP addresses, and transfer statistics. The optional full-route diagnostic mode is off by default. When enabled, it routes more IPv4 traffic through the on-device tunnel and may log hostnames of other sites. Running the connectivity check manually contacts test CDN and network probe endpoints. The app does not automatically send logs to the developer. If you choose to share a log, you select the recipient using the system share sheet.

## Turning off acceleration, removing data, and sending feedback

You can turn off acceleration in BiliScope, remove the VPN configuration and the root certificate profile in iOS Settings, and delete the app to remove its local app data.

Apple processes feedback, screenshots, and accompanying diagnostics you send through TestFlight. The developer can access these submissions to investigate issues. For privacy questions, contact us through TestFlight feedback. You can also ask questions on [GitHub Issues](https://github.com/Terry1238832/BiliScope/issues), where submissions are public.
