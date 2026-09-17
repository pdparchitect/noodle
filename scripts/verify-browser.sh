#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Browser app bundle}"
codesign --verify --deep --strict "$app"
cmp "$project_root/Browser/Support/AppSymbol.svg" "$app/Contents/Resources/AppSymbol.svg"
entitlements="$(mktemp /tmp/noodle-browser-entitlements.XXXXXX)"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
python3 - "$app" "$entitlements" "$project_root/Browser/VERSION" <<'PY'
import pathlib, plistlib, sys, subprocess, re
app=pathlib.Path(sys.argv[1])
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
entitlements=plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
identifier=info['CFBundleIdentifier']
assert identifier in ('com.pdparchitect.noodle.browser','com.pdparchitect.noodle.browser.local')
assert info['CFBundleShortVersionString']==pathlib.Path(sys.argv[3]).read_text().strip()
assert info['CFBundleVersion']==info['CFBundleShortVersionString']
assert info['LSMinimumSystemVersion']=='26.0'
build_version=subprocess.check_output(['xcrun','vtool','-show-build',str(app/'Contents/MacOS/NoodleBrowser')],text=True)
assert re.search(r'\bminos 26\.0\b', build_version), 'Browser must match the suite deployment target'
sdk=re.search(r'\bsdk (\d+)\.', build_version)
assert sdk and int(sdk.group(1))>=26, 'Legacy SDK metadata disables the suite native sidebar and toolbar'
expected={'com.apple.security.app-sandbox':True, 'com.apple.security.network.client':True,
 'com.apple.security.files.user-selected.read-write':True,
 'com.apple.security.application-groups':[info['NoodleBrowserGroup']],
 'com.apple.security.temporary-exception.mach-lookup.global-name':[identifier+'-spks',identifier+'-spki']}
assert entitlements==expected, 'Unexpected Browser entitlements'
suffix='.local' if identifier.endswith('.local') else ''
assert info['NoodleBrowserGroup']==info['NoodleSigningTeam']+'.com.pdparchitect.noodle.browsers'+suffix
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes']==['noodlebrowser-dev' if suffix else 'noodlebrowser']
reference_type='com.pdparchitect.noodle.browser-reference'+('.dev' if suffix else '')
assert info['CFBundleDocumentTypes'][0]['LSItemContentTypes']==[reference_type]
assert info['UTExportedTypeDeclarations'][0]['UTTypeIdentifier']==reference_type
assert info['UTExportedTypeDeclarations'][0]['UTTypeTagSpecification']['public.filename-extension']==['noodlebrowser-dev' if suffix else 'noodlebrowser']
assert (app/'Contents/Resources/Browser.icns').stat().st_size>0
assert info['SUFeedURL']=='https://github.com/pdparchitect/noodle/releases/download/browser-latest/appcast.xml'
assert info['SUPublicEDKey']=='1ZT5NrPiDPaQ54iHGSI1a9JIn6kTrmjQvzZRBA9f/sk='
assert info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction']
assert info['SUEnableInstallerLauncherService'] and info['SUAllowsAutomaticUpdates']
assert not info['SUAutomaticallyUpdate'] and not info['SUSendProfileInfo']
if suffix: assert not info['NoodleUpdatesEnabled']
sparkle=app/'Contents/Frameworks/Sparkle.framework'
assert (app/'Contents/Resources/Sparkle-LICENSE.txt').is_file()
assert not (sparkle/'Versions/B/XPCServices/Downloader.xpc').exists()
for path in ['Versions/B/XPCServices/Installer.xpc','Versions/B/Autoupdate','Versions/B/Updater.app','.']:
 subprocess.run(['codesign','--verify','--strict',str(sparkle/path)],check=True)
 signature=subprocess.run(['codesign','-dv','--verbose=4',str(sparkle/path)],capture_output=True,text=True,check=True).stderr
 assert 'TeamIdentifier='+info['NoodleSigningTeam'] in signature
 assert 'runtime' in signature
rpaths=subprocess.check_output(['otool','-l',str(app/'Contents/MacOS/NoodleBrowser')],text=True)
assert '@executable_path/../Frameworks' in rpaths
assert '/artifacts/' not in rpaths and '/Toolchains/' not in rpaths

resources=app/'Contents/Resources/NoodleBrowser_NoodleBrowser.bundle'
assert any((resources/path).is_file() for path in ('Resources/Inspect.js','Contents/Resources/Resources/Inspect.js'))
signature=subprocess.run(['codesign','-dv','--verbose=4',str(app)],capture_output=True,text=True,check=True).stderr
assert 'runtime' in signature
for line in subprocess.check_output(['otool','-L',str(app/'Contents/MacOS/NoodleBrowser')],text=True).splitlines()[1:]:
 dependency=line.strip().split(' ')[0]
 assert dependency.startswith(('/System/Library/','/usr/lib/','@rpath/','@executable_path/')), dependency
print('Browser signature, sandbox, app group, channel, icon, resources, signed Sparkle installer boundary and framework links verified')
PY
