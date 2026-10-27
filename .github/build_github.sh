# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# temporarily move sidestore support framrwork to tmp before zip
mkdir tmp
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework ./tmp

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

mv ./tmp/SideStoreSupport.framework Payload/LiveContainer.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/LiveContainer.app/Settings.bundle/Root.plist

# download SideStore
cd tmp
wget https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa
unzip SideStore.ipa
cd ..

# SideStore
mv ./tmp/Payload/SideStore.app ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
./dylibify ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
ldid -S"" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
cp ./.github/sidelc/LCAppInfo.plist ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/

# copy intents
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/LiveContainer.app/
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/LiveContainer.app/
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/LiveContainer.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# OmniStation (optional): bundled the same way as SideStore when a source is configured
# - OMNISTATION_IPA_URL: direct download link to the .ipa, or
# - OMNISTATION_REPO (owner/repo) + optional OMNISTATION_TAG: .ipa taken from that repo's releases
#   (OMNISTATION_TOKEN is needed if that repo is private)
if [ -n "$OMNISTATION_IPA_URL" ] || [ -n "$OMNISTATION_REPO" ]; then
    rm -rf tmp_omni
    mkdir tmp_omni
    if [ -n "$OMNISTATION_IPA_URL" ]; then
        curl -fL --retry 3 -o tmp_omni/OmniStation.ipa "$OMNISTATION_IPA_URL" || { echo "OmniStation: download failed"; exit 1; }
    else
        OMNI_TAG="$OMNISTATION_TAG"
        if [ -z "$OMNI_TAG" ]; then
            # newest release (pre-releases included) that has an .ipa attached
            OMNI_TAG=$(GH_TOKEN="${OMNISTATION_TOKEN:-$GITHUB_TOKEN}" gh api "repos/$OMNISTATION_REPO/releases?per_page=30" --jq '[.[] | select(.draft == false) | select(any(.assets[]; .name | endswith(".ipa")))] | sort_by(.published_at) | reverse | .[0].tag_name // empty')
            [ -n "$OMNI_TAG" ] || { echo "OmniStation: no release with an .ipa found in $OMNISTATION_REPO"; exit 1; }
        fi
        echo "OmniStation: using release $OMNI_TAG from $OMNISTATION_REPO"
        GH_TOKEN="${OMNISTATION_TOKEN:-$GITHUB_TOKEN}" gh release download "$OMNI_TAG" --repo "$OMNISTATION_REPO" --pattern "*.ipa" --dir tmp_omni || { echo "OmniStation: release download failed"; exit 1; }
        OMNI_IPA=$(ls tmp_omni/*.ipa | head -n 1)
        [ -n "$OMNI_IPA" ] || { echo "OmniStation: no .ipa found in the release"; exit 1; }
        mv "$OMNI_IPA" tmp_omni/OmniStation.ipa
    fi
    unzip -q tmp_omni/OmniStation.ipa -d tmp_omni || { echo "OmniStation: unzip failed"; exit 1; }
    OMNI_APP=$(ls -d tmp_omni/Payload/*.app | head -n 1)
    [ -n "$OMNI_APP" ] || { echo "OmniStation: no .app inside the ipa"; exit 1; }
    OMNI_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$OMNI_APP/Info.plist")
    [ -n "$OMNI_EXEC" ] || { echo "OmniStation: CFBundleExecutable not found"; exit 1; }
    OMNI_DEST=./Payload/LiveContainer.app/Frameworks/OmniStationApp.framework

    rm -rf "$OMNI_DEST"
    mv "$OMNI_APP" "$OMNI_DEST"
    # OmniStation's app extensions (JIT helper with StikJIT, MeloNX memory helper) can't live inside a
    # framework: they go next to LiveContainer's own extensions, with bundle IDs under LiveContainer's
    # (like LiveWidgetExtension). OmniStation looks for them there when it runs built in.
    for OMNI_APPEX in "$OMNI_DEST"/PlugIns/*.appex; do
        [ -d "$OMNI_APPEX" ] || continue
        OMNI_APPEX_NAME=$(basename "$OMNI_APPEX" .appex)
        OMNI_APPEX_DEST="./Payload/LiveContainer.app/PlugIns/$OMNI_APPEX_NAME.appex"
        rm -rf "$OMNI_APPEX_DEST"
        mv "$OMNI_APPEX" "$OMNI_APPEX_DEST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.$OMNI_APPEX_NAME" "$OMNI_APPEX_DEST/Info.plist" || { echo "OmniStation: can't set the bundle ID of $OMNI_APPEX_NAME"; exit 1; }
        OMNI_APPEX_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$OMNI_APPEX_DEST/Info.plist")
        [ -n "$OMNI_APPEX_EXEC" ] && [ -f "$OMNI_APPEX_DEST/$OMNI_APPEX_EXEC" ] || { echo "OmniStation: executable of $OMNI_APPEX_NAME not found"; exit 1; }
        rm -rf "$OMNI_APPEX_DEST/_CodeSignature" "$OMNI_APPEX_DEST/embedded.mobileprovision"
        ldid -S "$OMNI_APPEX_DEST/$OMNI_APPEX_EXEC"
        echo "OmniStation: extension $OMNI_APPEX_NAME.appex -> com.kdt.livecontainer.$OMNI_APPEX_NAME"
    done
    # old signatures and anything else that can't live inside a framework; the store signs everything again on install
    rm -rf "$OMNI_DEST/PlugIns" "$OMNI_DEST/Extensions" "$OMNI_DEST/Watch" "$OMNI_DEST/_CodeSignature" "$OMNI_DEST/embedded.mobileprovision"

    ./dylibify "$OMNI_DEST/$OMNI_EXEC" "$OMNI_DEST/$OMNI_EXEC.dylib" || { echo "OmniStation: dylibify failed"; exit 1; }
    rm "$OMNI_DEST/$OMNI_EXEC"
    mv "$OMNI_DEST/$OMNI_EXEC.dylib" "$OMNI_DEST/$OMNI_EXEC"
    ldid -S"" "$OMNI_DEST/$OMNI_EXEC"
    cp ./.github/omnilc/LCAppInfo.plist "$OMNI_DEST/"
    # OmniStation is a game launcher: let iOS treat LiveContainer as a game (Game Mode, like the
    # standalone OmniStation). Only in this IPA; LiveContainer.ipa was already packaged above.
    LC_PLIST=./Payload/LiveContainer.app/Info.plist
    /usr/libexec/PlistBuddy -c "Set :LSApplicationCategoryType public.app-category.games" "$LC_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.games" "$LC_PLIST"
    /usr/libexec/PlistBuddy -c "Set :LSSupportsGameMode true" "$LC_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :LSSupportsGameMode bool true" "$LC_PLIST"
    /usr/libexec/PlistBuddy -c "Set :GCSupportsGameMode true" "$LC_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :GCSupportsGameMode bool true" "$LC_PLIST"
    echo "OmniStation bundled from $OMNI_APP (executable: $OMNI_EXEC)"
else
    echo "OmniStation: no source configured, building without it"
fi

# Sign
rm -r .zsign_cache
find payloadlc/Payload -type d -name "_CodeSignature" -exec rm -r {} +

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# package
zip -r "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"