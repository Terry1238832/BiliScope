import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var controller: ProxyController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    trustBanner
                    videoHintBanner
                    setupCard
                    checkCard
                    logCard
                    scopeCard
                }
                .padding(16)
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .navigationTitle("哔哩加速")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.refreshTrust() }
        }
        .tint(Color(red: 0.98, green: 0.45, blue: 0.55))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.isRunning ? "代理运行中" : "代理已停止")
                        .font(.headline)
                    Text(controller.proxyAddress)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.isRunning },
                    set: { value in value ? controller.start() : controller.stop() }
                ))
                .labelsHidden()
            }
            Picker("监听地址", selection: $controller.bindMode) {
                ForEach(ProxyController.BindMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if controller.bindMode == .wifi {
                Text(controller.wifiAddress.map { "手机 Wi-Fi 地址：\($0)" } ?? "没有检测到 Wi-Fi 地址")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if controller.tunnelCount + controller.acceleratedCount > 0 {
                Text("B 站连接 \(controller.tunnelCount) · 加速 \(controller.acceleratedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.isRunning {
                Text("还没看到 B 站流量：如果 B 站已经在播放，说明它没走系统代理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(controller.certificateTrusted ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(controller.certificateTrusted ? "根证书已信任" : "根证书未信任")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !controller.certificateTrusted {
                    Button("去安装") { controller.installCertificate() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }

            if !controller.caFingerprint.isEmpty {
                Text("根证书 SHA-256")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.caFingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Toggle("启动 App 时自动开启代理", isOn: $controller.autoStart)
                .font(.caption)

            Toggle("记录所有域名（排查用）", isOn: $controller.logAllHosts)
                .font(.caption)
            Text("开启后日志会记录所有经过代理的域名，仅用于排查，默认关闭。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder
    private var videoHintBanner: some View {
        if controller.isRunning && controller.tunnelCount > 0 && controller.acceleratedCount == 0 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("B 站 API 走了代理，视频没走")
                        .font(.subheadline.weight(.semibold))
                    Text("播放器可能用了 QUIC（UDP 443）或自建网络栈，系统 HTTP 代理抓不到这类流量。把日志里的 tunnel 行发我，可以确认它实际连了哪些域名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.3)))
        }
    }

    @ViewBuilder
    private var trustBanner: some View {
        if controller.isRunning && !controller.certificateTrusted {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("描述文件已装，但还没开「完全信任」")
                        .font(.subheadline.weight(.semibold))
                    Text("设置 → 通用 → 关于本机 → 证书信任设置 → 打开 BiliScope Root CA 的开关。\nSettings → General → About → Certificate Trust Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开证书信任设置") { controller.openCertificateTrustSettings() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.3)))
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("三步接管").font(.headline)

            step(number: 1, title: "安装根证书",
                 detail: "装完描述文件只是第一步，还要到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。")
            Button("安装根证书") { controller.installCertificate() }
                .buttonStyle(.borderedProminent)

            Divider().opacity(0.2)

            step(number: 2, title: "把 Wi-Fi 代理指向本机",
                 detail: "设置 → 无线局域网 → 当前网络 ⓘ → 配置代理 → 手动")

            VStack(alignment: .leading, spacing: 6) {
                proxyRow("服务器", controller.proxyHost, copyable: true)
                proxyRow("端口", "\(controller.proxyPort)", copyable: false)
                proxyRow("认证", "关闭", copyable: false)
            }

            Text("认证必须关闭：本代理不支持用户名密码，开了会直接连不上。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("先启动本 App 再设代理。代理开着时如果 App 被杀掉，整台手机会断网——先关掉代理，再重新打开 App。")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Button("打开系统设置") { controller.openWiFiSettings() }
                .buttonStyle(.bordered)

            Divider().opacity(0.2)

            step(number: 3, title: "打开 B 站 App",
                 detail: "回到 B 站随便播一个视频，本页日志里出现 accelerated 就说明接管成功。")
        }
        .card()
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连通性自检").font(.headline)
            Text("依次检查本机代理端口、CONNECT 握手、以及经代理访问 B 站 CDN。哪一步红的就是卡在哪。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                controller.runDiagnostics()
            } label: {
                HStack {
                    if controller.selfCheckRunning { ProgressView().controlSize(.small) }
                    Text(controller.selfCheckRunning ? "检测中…" : "运行诊断")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.selfCheckRunning)

            if !controller.selfCheckText.isEmpty {
                Text(controller.selfCheckText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("日志").font(.headline)
                Spacer()
                ShareLink(item: controller.logs.joined(separator: "\n")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                Button("清空") { controller.clearLogs() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(controller.logs.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 150)
        }
        .card()
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("接管范围").font(.headline)
            Text("只会终止以下 B 站媒体域名的 TLS：")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("*.bilivideo.com  *.bilivideo.cn  *.hdslb.com  *.bilicdn.com")
                .font(.system(size: 11, design: .monospaced))
            Text("其他任何域名（包括 B 站 API、其他 App、其他网站）只做 TCP 字节转发，不解密、不解析、不记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func proxyRow(_ title: String, _ value: String, copyable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
            if copyable {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    private func step(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }
}
