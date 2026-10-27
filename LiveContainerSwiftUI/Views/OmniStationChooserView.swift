//
//  OmniStationChooserView.swift
//  LiveContainer
//
//  LiveContainer-OmniStation fork: when LiveContainer opens with a game controller connected, a
//  chooser with two Liquid Glass cards (LiveContainer / OmniStation) is shown instead of the app list.
//  It works with the controller (d-pad or left stick to choose, A to enter) and with touch.
//  Without a controller, LiveContainer opens as usual.
//

import SwiftUI
import UIKit
import GameController

// What covers LiveContainer's UI around the built-in OmniStation
final class OmniStationLaunchCover: ObservableObject {
    enum Phase {
        case hidden
        // LiveContainer just launched and may offer OmniStation: black until we know if there's a controller
        case detecting
        // controller connected: LiveContainer / OmniStation chooser
        case choosing
        // OmniStation is about to open: black with its icon, so the app list doesn't flash in between
        case opening
    }

    static let shared = OmniStationLaunchCover()

    @Published private(set) var phase: Phase = OmniStationAutoOpen.mayOpenAtLaunch ? .detecting : .hidden
    private var openOmniStation: (() -> Void)?

    var visible: Bool { phase != .hidden }

    static var lastChoiceIsOmniStation: Bool {
        UserDefaults.standard.object(forKey: BuiltInOmniStationAppInfo.lastChoiceKey) as? Bool ?? true
    }

    func hide() {
        openOmniStation = nil
        set(.hidden)
    }

    func showChooser(openOmniStation: @escaping () -> Void) {
        self.openOmniStation = openOmniStation
        set(.choosing)
    }

    func showOpening() {
        // with LiveContainer's JIT, its "waiting for JIT" dialog has to stay visible
        if BuiltInOmniStationAppInfo.shared.isJITNeeded {
            hide()
            return
        }
        set(.opening)
        // if OmniStation couldn't be opened, LiveContainer is still here: don't leave the cover on
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.phase == .opening {
                self?.hide()
            }
        }
    }

    func choose(omniStation: Bool) {
        guard phase == .choosing else { return }
        UserDefaults.standard.set(omniStation, forKey: BuiltInOmniStationAppInfo.lastChoiceKey)
        if omniStation, let open = openOmniStation {
            openOmniStation = nil
            open()
        } else {
            hide()
        }
    }

    private func set(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            phase = newPhase
        }
    }
}

struct OmniStationLaunchCoverView: View {
    @ObservedObject var cover: OmniStationLaunchCover

    var body: some View {
        ZStack {
            switch cover.phase {
            case .choosing:
                OmniStationChooserView(cover: cover)
            case .opening:
                Color.black
                VStack(spacing: 20) {
                    if let icon = OmniStationChooserIcons.omniStation {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    ProgressView()
                        .tint(Color.white)
                }
            default:
                Color.black
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

enum OmniStationChooserIcons {
    static let liveContainer: UIImage? = UIImage.generateIcon(forBundleURL: Bundle.main.bundleURL, style: .Original, hasBorder: false)
    static let omniStation: UIImage? = UIImage.generateIcon(forBundleURL: Bundle.main.bundleURL.appendingPathComponent("Frameworks/OmniStationApp.framework"), style: .Original, hasBorder: false)
}

struct OmniStationChooserView: View {
    @ObservedObject var cover: OmniStationLaunchCover
    @StateObject private var input = OmniStationChooserInput()

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                background
                VStack(spacing: landscape ? 28 : 40) {
                    Text("¿Dónde quieres entrar?")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white)
                    if landscape {
                        HStack(spacing: 36) { cards }
                    } else {
                        VStack(spacing: 28) { cards }
                    }
                    Text("Ⓐ Entrar · \(landscape ? "◀ ▶" : "▲ ▼") Elegir")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(24)
            }
            .onAppear {
                input.vertical = !landscape
            }
            .onChange(of: landscape) { newValue in
                input.vertical = !newValue
            }
        }
        .onAppear {
            input.selectedOmniStation = OmniStationLaunchCover.lastChoiceIsOmniStation
            input.onConfirm = { omniStation in
                cover.choose(omniStation: omniStation)
            }
            input.start()
        }
        .onDisappear {
            input.stop()
        }
    }

    @ViewBuilder
    private var cards: some View {
        OmniStationChooserCard(title: "LiveContainer", icon: OmniStationChooserIcons.liveContainer, selected: !input.selectedOmniStation) {
            input.selectedOmniStation = false
            cover.choose(omniStation: false)
        }
        OmniStationChooserCard(title: "OmniStation", icon: OmniStationChooserIcons.omniStation, selected: input.selectedOmniStation) {
            input.selectedOmniStation = true
            cover.choose(omniStation: true)
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.02, green: 0.02, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // soft lights behind the glass, so it has something to refract
            Circle()
                .fill(Color(red: 0.25, green: 0.45, blue: 1.0).opacity(0.45))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: input.selectedOmniStation ? 140 : -140, y: -60)
                .animation(.easeInOut(duration: 0.4), value: input.selectedOmniStation)
            Circle()
                .fill(Color(red: 0.75, green: 0.30, blue: 1.0).opacity(0.30))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: input.selectedOmniStation ? -120 : 120, y: 120)
                .animation(.easeInOut(duration: 0.4), value: input.selectedOmniStation)
        }
    }
}

struct OmniStationChooserCard: View {
    let title: String
    let icon: UIImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Group {
                    if let icon {
                        Image(uiImage: icon)
                            .resizable()
                    } else {
                        Color.white.opacity(0.15)
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 210, height: 220)
            .modifier(OmniStationGlassCard(selected: selected))
            .scaleEffect(selected ? 1.08 : 0.94)
            .opacity(selected ? 1 : 0.75)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        }
        .buttonStyle(.plain)
    }
}

// Liquid Glass on iOS 26 and later, frosted material before
struct OmniStationGlassCard: ViewModifier {
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(selected ? Glass.regular.tint(Color.white.opacity(0.12)).interactive() : Glass.regular.interactive(), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0.85 : 0.12), lineWidth: selected ? 3 : 1))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0.85 : 0.12), lineWidth: selected ? 3 : 1))
        }
    }
}

// Game controller input for the chooser: d-pad or left stick to move, A to enter
final class OmniStationChooserInput: ObservableObject {
    @Published var selectedOmniStation = true
    var vertical = false
    var onConfirm: ((Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var attached: [GCController] = []
    private var stickNeutral = true

    func start() {
        stop()
        for controller in GCController.controllers() {
            attach(controller)
        }
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] notification in
            if let controller = notification.object as? GCController {
                self?.attach(controller)
            }
        })
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        // leave the controllers as they were for whatever comes next (OmniStation or LiveContainer)
        for controller in attached {
            if let pad = controller.extendedGamepad {
                pad.dpad.valueChangedHandler = nil
                pad.leftThumbstick.valueChangedHandler = nil
                pad.buttonA.pressedChangedHandler = nil
            }
        }
        attached.removeAll()
    }

    deinit {
        stop()
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad, !attached.contains(where: { $0 === controller }) else { return }
        attached.append(controller)
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.move(x: x, y: y)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.move(x: x, y: y)
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.onConfirm?(self.selectedOmniStation)
            }
        }
    }

    // LiveContainer is the first card (left / top), OmniStation the second (right / bottom)
    private func move(x: Float, y: Float) {
        let value: Float = vertical ? -y : x
        DispatchQueue.main.async {
            if abs(value) < 0.5 {
                self.stickNeutral = true
                return
            }
            guard self.stickNeutral else { return }
            self.stickNeutral = false
            let omniStation = value > 0
            if self.selectedOmniStation != omniStation {
                self.selectedOmniStation = omniStation
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}
