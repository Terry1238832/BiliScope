import SwiftUI
import UIKit
import BiliScopeCore

/// Certificates, diagnostics, logs and the Shadowrocket fallback.
struct SettingsView: View {
    @EnvironmentObject private var controller: ProxyController
    @EnvironmentObject private var vpn: VPNController
    @Environment(\.dismiss) private var dismiss

    private var usesTunnel: Bool { TunnelShared.hasTunnel }

    var body: some View {
        NavigationStack {
            Form {
                certificateSection
                if usesTunnel { tunnelSection }
                diagnosticsSection
                logSection
                shadowrocketSection
                scopeSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
    }

    private var certificateSection: some View {
        Section {
            HStack {
                Label(controller.certificateTrusted ? "根证书已信任" : "根证书未信任",
                      systemImage: controller.certificateTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(controller.certificateTrusted ? .green : .orange)
                Spacer()
            }
            Button("安装根证书") { controller.installCertificate() }
            Button("打开证书信任设置") { controller.openCertificateTrustSettings() }
            if !controller.caFingerprint.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(controller.caFingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("根证书")
        } footer: {
            Text("装完描述文件后，还要到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。证书只在这台设备上生成，不会上传。")
        }
    }

    private var tunnelSection: some View {
        Section {
            Toggle("全量排查模式", isOn: $vpn.fullTunnel)
                .disabled(vpn.isOn)
        } header: {
            Text("内置加速")
        } footer: {
            Text("只用于排查：所有流量都经过本机，会影响其他 App 的 UDP（游戏、通话）。要先关掉加速才能切换，测完记得关掉。")
        }
    }

    private var diagnosticsSection: some View {
        Section("连通性诊断") {
            Button {
                controller.runDiagnostics(port: vpn.isOn ? TunnelShared.tunnelProxyPort : nil)
            } label: {
                HStack {
                    Text(controller.selfCheckRunning ? "检测中…" : "运行诊断")
                    if controller.selfCheckRunning { Spacer(); ProgressView() }
                }
            }
            .disabled(controller.selfCheckRunning)
            if !controller.selfCheckText.isEmpty {
                Text(controller.selfCheckText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// While the tunnel runs, the acceleration happens inside it, so its log is the useful one.
    private var shownLogs: [String] {
        vpn.isOn ? vpn.tunnelLines : controller.logs
    }

    private var logSection: some View {
        Section {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(shownLogs.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 220)
            ShareLink("分享日志", item: shownLogs.joined(separator: "\n"))
            if !vpn.isOn {
                Button("清空", role: .destructive) { controller.clearLogs() }
            }
        } header: {
            Text(vpn.isOn ? "日志（内置加速）" : "日志")
        } footer: {
            Text("出现 accelerated 就说明在加速。分享前看一眼：日志不含视频签名，但可能有域名。")
        }
    }

    private var shadowrocketSection: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.isRunning },
                                 set: { $0 ? controller.start() : controller.stop() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机代理")
                    Text(controller.proxyAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Picker("监听地址", selection: $controller.bindMode) {
                ForEach(ProxyController.BindMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            LabeledContent("小火箭节点", value: "HTTP · \(controller.proxyHost) · \(controller.proxyPort)")
            Toggle("启动 App 时自动开启代理", isOn: $controller.autoStart)
            Toggle("记录所有域名（排查用）", isOn: $controller.logAllHosts)
        } header: {
            Text(usesTunnel ? "小火箭备选" : "小火箭")
        } footer: {
            Text(usesTunnel
                 ? "用内置加速就不需要这些。只有改用小火箭时，才需要打开本机代理，并在小火箭里添加上面的节点、导入教程里的配置。"
                 : "在小火箭里添加上面的节点、导入教程里的配置。本 App 被杀掉后，B 站的视频和封面会加载失败，重新打开本 App，或关掉小火箭的连接开关。")
        }
    }

    private var scopeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("解密并加速").font(.footnote.weight(.semibold))
                Text((HostPolicy.defaultMediaDomains + HostPolicy.exactMediaHosts).joined(separator: "  "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("只转发、不解密").font(.footnote.weight(.semibold))
                Text(HostPolicy.defaultRelayDomains.joined(separator: "  "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("接管范围")
        } footer: {
            Text("其他 App 和网站的流量不经过内置加速。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Link("项目主页", destination: URL(string: "https://github.com/Terry1238832/BiliScope")!)
            Link("思路来自 Bilibili 线程撕裂者", destination: URL(string: "https://github.com/MrTangLuyao/Bilibili-thread-ripper")!)
        }
    }
}
