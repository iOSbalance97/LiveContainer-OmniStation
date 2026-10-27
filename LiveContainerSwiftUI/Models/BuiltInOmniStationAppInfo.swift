//
//  BuiltInOmniStationAppInfo.swift
//  LiveContainer
//
//  OmniStation bundled inside LiveContainer, following the same pattern as the built-in SideStore.
//  The app lives in Frameworks/OmniStationApp.framework (added by .github/build_github.sh)
//  and its data lives in Documents/OmniStation.
//

import Foundation
import UIKit
import SwiftUI

final class BuiltInOmniStationAppInfo : LCAppInfo {
    static let shared = BuiltInOmniStationAppInfo()
    static let launchName = "builtinOmniStation"
    static let containerFolderName = "LCBuiltinOmniStation"

    // UserDefaults keys (stored in LiveContainer's own defaults)
    static let openWithControllerKey = "LCOmniStationOpenWithController"
    static let launchWithJITKey = "LCOmniStationLaunchWithJIT"
    static let skipAutoOpenKey = "LCOmniStationSkipAutoOpen"

    private override init() {
        super.init(bundlePath: Bundle.main.bundleURL.appendingPathComponent("Frameworks/OmniStationApp.framework").path)
    }

    // The bundle is part of LiveContainer's signed app, so nothing may be written into it.
    // Settings for the built-in OmniStation are kept in UserDefaults instead.
    override func save() {
    }

    override var isJITNeeded: Bool {
        get {
            // OmniStation activates its own JIT with its StikJIT extension, so LiveContainer doesn't ask for it by default
            return UserDefaults.standard.object(forKey: BuiltInOmniStationAppInfo.launchWithJITKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: BuiltInOmniStationAppInfo.launchWithJITKey)
        }
    }

    // JIT script: reuse the one configured for an OmniStation installed as a normal app in LiveContainer,
    // otherwise use LiveContainer's bundled universal script when the device needs one (TXM, iOS 26+).
    override var jitLaunchScriptJs: String! {
        get {
            if let installedScript = installedGuestJITScript() {
                return installedScript
            }
            if LCUtils.isTXMScriptRequired() {
                return LCUtils.base64EncodedUniversalJITScript()
            }
            return nil
        }
        set {
        }
    }

    override var lastLaunched: Date!{
        get {
            return nil
        }

        set {

        }
    }

    private func installedGuestJITScript() -> String? {
        guard let myBundleId = bundleIdentifier() else {
            return nil
        }
        let model = DataManager.shared.model
        for app in model.apps + model.hiddenApps {
            if app.appInfo is BuiltInOmniStationAppInfo {
                continue
            }
            guard app.appInfo.bundleIdentifier() == myBundleId else {
                continue
            }
            if let script = app.appInfo.jitLaunchScriptJs, !script.isEmpty {
                return script
            }
        }
        return nil
    }

    override func iconIsDarkIcon(_ isDarkIcon: Bool) -> UIImage! {
        if isDarkIcon {
            if let cachedIconDark {
                return cachedIconDark
            }

        } else {
            if let cachedIcon {
                return cachedIcon
            }
        }
        guard let iconCacheUrl = ensureAndGetIconCacheFolder() else {
            return nil;
        }

        let cachedIconURL : URL;
        if(isDarkIcon) {
            cachedIconURL = iconCacheUrl.appendingPathComponent("LCAppIconDark.png");
        } else {
            cachedIconURL = iconCacheUrl.appendingPathComponent("LCAppIconLight.png");
        }

        var ans: UIImage? = nil
        if(FileManager.default.fileExists(atPath: cachedIconURL.path)) {
            ans = UIImage(contentsOfFile: cachedIconURL.path)
        }

        if let ans {
            return ans
        }

        ans = UIImage.generateIcon(forBundleURL: URL(fileURLWithPath: bundlePath()), style: isDarkIcon ? .Dark : .Light, hasBorder: true)
        if let ans {
            saveCGImage(ans.cgImage, cachedIconURL)
        }

        if isDarkIcon {
            cachedIconDark = ans
        } else {
            cachedIcon = ans
        }

        return ans;
    }

    private func ensureAndGetIconCacheFolder() -> URL? {
        let directory = LCPath.docPath
            .appendingPathComponent("OmniStation/Library/Caches", isDirectory: true)
            .appendingPathComponent("BuiltInOmniStationIconCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
}

// State used to decide, once per LiveContainer launch, whether to jump straight into OmniStation
enum OmniStationAutoOpen {
    // set when LiveContainer was opened through a URL (install, launch another app...), so we stay in LiveContainer
    static var urlReceived = false
    // the decision is only taken once per process
    static var checked = false

    // Read once, at launch, before the skip flag is cleared: will LiveContainer try to open OmniStation?
    static let mayOpenAtLaunch: Bool = {
        let defaults = UserDefaults.standard
        return UserDefaults.omniStationExist()
            && DataManager.shared.model.multiLCStatus != 2
            && defaults.bool(forKey: BuiltInOmniStationAppInfo.openWithControllerKey)
            && !defaults.bool(forKey: BuiltInOmniStationAppInfo.skipAutoOpenKey)
    }()
}

// Black screen with OmniStation's icon while LiveContainer is about to open OmniStation by itself,
// so the LiveContainer app list doesn't flash in between.
final class OmniStationLaunchCover: ObservableObject {
    static let shared = OmniStationLaunchCover()

    // not with LiveContainer's JIT: its "waiting for JIT" dialog has to stay visible
    @Published private(set) var visible: Bool = OmniStationAutoOpen.mayOpenAtLaunch
        && !(UserDefaults.standard.object(forKey: BuiltInOmniStationAppInfo.launchWithJITKey) as? Bool ?? false)

    func hide() {
        if visible {
            withAnimation(.easeOut(duration: 0.2)) {
                visible = false
            }
        }
    }
}

struct OmniStationLaunchCoverView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                if let icon = BuiltInOmniStationAppInfo.shared.iconIsDarkIcon(true) {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                }
                ProgressView()
                    .tint(.white)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}
