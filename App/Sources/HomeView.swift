import SwiftUI
import UIKit

/// One button. Everything technical lives behind the settings button.
///
/// Motion is cheap by design: the drifting background, the orbiting dots and the
/// breathing glow are repeat-forever transforms that Core Animation runs without
/// SwiftUI redrawing, they pause with the app in the background, and none of it
/// touches the packet tunnel, which is a separate process. Reduce Motion turns
/// all of it off.
struct HomeView: View {
    @EnvironmentObject private var controller: ProxyController
    @EnvironmentObject private var vpn: VPNController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showSettings = false
    /// Bumped on each start; every ripple ring keys its one-shot animation on it.
    @State private var rippleID = 0

    /// The full build drives the packet tunnel; the Shadowrocket build has no
    /// tunnel and toggles the app's own proxy instead.
    private var usesTunnel: Bool { TunnelShared.hasTunnel }

    private var phase: AccelerationPhase {
        if usesTunnel {
            switch vpn.status {
            case .connected: return .on
            case .connecting, .reasserting, .disconnecting: return .starting
            default: return .off
            }
        }
        return controller.isRunning ? .on : .off
    }

    private var buttonSize: CGFloat { sizeClass == .regular ? 260 : 196 }

    var body: some View {
        ZStack {
            AmbientBackground(phase: phase, animated: !reduceMotion)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 24)
                AccelerateButton(phase: phase, size: buttonSize, rippleID: rippleID,
                                 animated: !reduceMotion, action: toggle)
                statusText
                    .padding(.top, sizeClass == .regular ? 48 : 40)
                Spacer(minLength: 24)
                footer
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            LightSweep(trigger: rippleID)
        }
        .tint(Palette.accent)
        .sensoryFeedback(.success, trigger: phase == .on) { _, on in on }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { controller.refreshTrust() }
        }
        .onChange(of: vpn.isOn) { _, on in
            // The tunnel carries its own proxy; the app's proxy and its silent-audio
            // keep-alive only serve the Shadowrocket build.
            if on { controller.stop() }
        }
        .task {
            // Lets a connected Mac drive the tunnel while testing on a device.
            let arguments = ProcessInfo.processInfo.arguments
            #if DEBUG
            // Replays the start animation without touching the VPN, to record it.
            if arguments.contains("-demostart") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                playStartAnimation()
                return
            }
            #endif
            if arguments.contains("-vpnoff") {
                await vpn.restart(fullTunnel: nil)
            } else if arguments.contains("-vpnon") || arguments.contains("-vpnfull") {
                await vpn.restart(fullTunnel: arguments.contains("-vpnfull"))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("哔哩加速")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("设置")
        }
        .padding(.top, 8)
    }

    private var statusText: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(sizeClass == .regular ? .largeTitle : .title2, design: .rounded).weight(.semibold))
                .contentTransition(.interpolate)
                .id(title)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                        removal: .opacity.combined(with: .offset(y: -8))))
            subtitleView
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: phase)
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let error = vpn.lastError, usesTunnel {
            Text(error)
        } else if phase == .on, usesTunnel, vpn.acceleratedRequests > 0 {
            HStack(spacing: 6) {
                Text("已加速")
                Text("\(vpn.acceleratedRequests)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(vpn.acceleratedRequests)))
                Text("段 ·")
                Text(HomeView.size(vpn.acceleratedBytes))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(vpn.acceleratedBytes)))
            }
            .animation(.snappy, value: vpn.acceleratedBytes)
        } else {
            Text(subtitle)
        }
    }

    private var title: String {
        switch phase {
        case .off: return "点击开始加速"
        case .starting: return "正在开启…"
        case .on: return "加速中"
        }
    }

    private var subtitle: String {
        switch phase {
        case .off:
            return usesTunnel ? "只接管 B 站的视频和图片" : "开启后，用小火箭把 B 站流量转过来"
        case .starting:
            return "第一次开启时，请在弹窗里允许添加 VPN 配置"
        case .on:
            return "彻底关掉 B 站再打开，播放视频即可"
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !controller.certificateTrusted {
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(Palette.accent)
                    Text("还差一步：安装并信任根证书")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func toggle() {
        if phase == .off {
            playStartAnimation()
            if usesTunnel {
                Task { await vpn.start() }
            } else {
                controller.start()
            }
        } else if usesTunnel {
            vpn.stop()
        } else {
            controller.stop()
        }
    }

    /// Three staggered ripples and one soft band of light, then stillness.
    private func playStartAnimation() {
        guard !reduceMotion else { return }
        rippleID += 1
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum AccelerationPhase: Equatable { case off, starting, on }

/// Soft, light colors with a dark counterpart.
enum Palette {
    static let accent = Color(red: 0.98, green: 0.45, blue: 0.60)
    static let accentSoft = Color(red: 1.0, green: 0.68, blue: 0.62)
    static let mint = Color(red: 0.55, green: 0.86, blue: 0.80)
    static let sky = Color(red: 0.62, green: 0.78, blue: 1.0)

    static let base = LinearGradient(
        colors: [Color(light: (0.97, 0.98, 1.0), dark: (0.06, 0.07, 0.10)),
                 Color(light: (1.0, 0.97, 0.98), dark: (0.09, 0.07, 0.10))],
        startPoint: .top, endPoint: .bottom)

    static let card = Color(light: (1, 1, 1), dark: (0.16, 0.16, 0.20))
}

extension Color {
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        self.init(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Large blurred color fields drifting slowly; cool when idle, warm while
/// accelerating. Each field is drawn once and only its position animates.
private struct AmbientBackground: View {
    let phase: AccelerationPhase
    let animated: Bool
    @State private var drift = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let warm = phase == .on
            let strength = colorScheme == .dark ? 0.28 : 0.42
            ZStack {
                Palette.base
                blob(color: warm ? Palette.accent : Palette.sky, diameter: size.width * 0.95)
                    .offset(x: drift ? -size.width * 0.28 : -size.width * 0.12,
                            y: drift ? -size.height * 0.30 : -size.height * 0.20)
                    .opacity(strength)
                blob(color: warm ? Palette.accentSoft : Palette.mint, diameter: size.width * 0.85)
                    .offset(x: drift ? size.width * 0.30 : size.width * 0.16,
                            y: drift ? size.height * 0.10 : size.height * 0.24)
                    .opacity(strength)
                blob(color: warm ? Palette.mint : Palette.accent.opacity(0.6), diameter: size.width * 0.6)
                    .offset(x: drift ? -size.width * 0.05 : size.width * 0.18,
                            y: drift ? size.height * 0.38 : size.height * 0.30)
                    .opacity(strength * 0.7)
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 1.2), value: warm)
        }
        .ignoresSafeArea()
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func blob(color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.32)
    }
}

private struct AccelerateButton: View {
    let phase: AccelerationPhase
    let size: CGFloat
    let rippleID: Int
    let animated: Bool
    let action: () -> Void

    @State private var spin = false
    @State private var breathe = false
    @State private var orbit = false

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Ripple(trigger: rippleID, delay: Double(ring) * 0.14, size: size)
                }

                // A slow breathing glow while accelerating.
                Circle()
                    .fill(Palette.accent)
                    .frame(width: size, height: size)
                    .blur(radius: size * 0.22)
                    .scaleEffect(breathe ? 1.12 : 0.96)
                    .opacity(breathe ? 0.45 : 0.28)
                    .opacity(phase == .on ? 1 : 0)

                Circle()
                    .fill(phase == .on
                          ? AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.accentSoft],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Palette.card))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(phase == .on ? 0.35 : 0.9), lineWidth: 1)
                    )
                    .shadow(color: (phase == .on ? Palette.accent : .black).opacity(phase == .on ? 0.30 : 0.07),
                            radius: phase == .on ? 30 : 20, y: 12)

                if phase == .starting {
                    Circle()
                        .trim(from: 0, to: 0.32)
                        .stroke(AngularGradient(colors: [Palette.accent.opacity(0), Palette.accent, Palette.mint],
                                                center: .center),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: size + 16, height: size + 16)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            spin = false
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
                        }
                        .transition(.opacity)
                }

                // Three dots orbiting at different speeds: the parallel downloads.
                // They always turn; only their visibility follows the phase.
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                        .offset(y: -(size / 2 - 14))
                        .rotationEffect(.degrees(Double(index) * 120 + (orbit ? 360 : 0)))
                        .animation(.linear(duration: 6 + Double(index) * 2.5).repeatForever(autoreverses: false),
                                   value: orbit)
                }
                .opacity(phase == .on ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: phase)

                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(phase == .on ? AnyShapeStyle(.white)
                                                  : AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.accentSoft],
                                                                                 startPoint: .top, endPoint: .bottom)))
                    .symbolEffect(.bounce.up, options: .speed(0.8), value: phase == .on)
                    .symbolEffect(.pulse, options: .repeating, isActive: phase == .starting)
            }
            .scaleEffect(phase == .on ? 1.0 : 0.98)
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: phase)
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.impact(weight: .medium), trigger: rippleID)
        .accessibilityLabel(phase == .on ? "关闭加速" : "开启加速")
        .onAppear {
            // Started once; they stay invisible until accelerating.
            guard animated else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
            orbit = true
        }
    }
}

/// One ring that grows and fades once each time `trigger` changes.
private struct Ripple: View {
    let trigger: Int
    let delay: Double
    let size: CGFloat
    @State private var progress: CGFloat = 1

    var body: some View {
        Circle()
            .stroke(LinearGradient(colors: [Palette.accent, Palette.mint], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2.5 - progress * 1.5)
            .frame(width: size, height: size)
            .scaleEffect(1 + progress * 1.1)
            .opacity(Double(1 - progress) * 0.7)
            .onChange(of: trigger) { _, _ in
                progress = 0
                withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 1.3).delay(delay)) { progress = 1 }
            }
            .allowsHitTesting(false)
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A soft band of light that crosses the screen once per trigger, invisible at rest.
private struct LightSweep: View {
    let trigger: Int
    @State private var progress: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            // On a light background, adding light shows nothing, so the light
            // theme uses tinted color and the dark theme adds light.
            let dark = colorScheme == .dark
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Palette.mint.opacity(dark ? 0.22 : 0.32), location: 0.3),
                .init(color: (dark ? Color.white : Palette.sky).opacity(dark ? 0.55 : 0.28), location: 0.5),
                .init(color: Palette.accent.opacity(dark ? 0.22 : 0.3), location: 0.7),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(geometry.size.width, 400) * 0.7, height: geometry.size.height * 1.8)
                .blur(radius: 28)
                .rotationEffect(.degrees(16))
                .modifier(SweepPosition(progress: progress, size: geometry.size))
                .blendMode(dark ? .plusLighter : .normal)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            progress = 0
            withAnimation(.timingCurve(0.35, 0, 0.2, 1, duration: 1.35)) { progress = 1 }
        }
    }
}

/// Recomputes position and a sine-shaped fade on every frame of the animation;
/// a plain animated opacity would only see its equal start and end values.
private struct SweepPosition: ViewModifier, Animatable {
    var progress: CGFloat
    let size: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: -size.width * 1.1 + progress * size.width * 2.5, y: -size.height * 0.4)
            .opacity(Double(sin(.pi * progress)))
    }
}
