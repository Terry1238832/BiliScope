import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ProxyController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    trustBanner
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
        }
        .card()
    }

    @ViewBuilder
    private var trustBanner: some View {
        if controller.isRunning && !controller.certificateTrusted {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("根证书还没被信任")
                        .font(.subheadline.weight(.semibold))
                    Text("没信任之前 B 站会一直转圈或报网络错误：设置 → 通用 → 关于本机 → 证书信任设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                 detail: "装完到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。")
            Button("安装根证书") { controller.installCertificate() }
                .buttonStyle(.borderedProminent)

            Divider().opacity(0.2)

            step(number: 2, title: "把 Wi-Fi 代理指向本机",
                 detail: "设置 → 无线局域网 → 当前网络 ⓘ → 配置代理 → 手动\n填 \(controller.proxyAddress)")
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
            Text("用本机代理向 B 站 CDN 发一个 Range 请求，验证证书与分片链路。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                controller.runSelfCheck()
            } label: {
                HStack {
                    if controller.selfCheckRunning { ProgressView().controlSize(.small) }
                    Text(controller.selfCheckRunning ? "检测中…" : "运行自检")
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
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
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
