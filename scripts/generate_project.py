#!/usr/bin/env python3
"""Generate the Xcode project deterministically."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, value): objects[ident(name)] = value; return ident(name)
def q(value): return json.dumps(value)
def refs(values): return '(' + ', '.join(values) + (',' if values else '') + ')'

package = add('package/SMBClient', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/kishikawakatsumi/SMBClient.git"; requirement = { kind = revision; revision = 66eafaa6d17e034e8036dee4b3ebc1b52cb53919; };')
package_product = add('packageProduct/SMBClient', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = SMBClient;')
package_build = add('build/SMBClient', f'isa = PBXBuildFile; productRef = {package_product};')
wg_package = add('package/WireGuard', 'isa = XCLocalSwiftPackageReference; relativePath = Vendor/WireGuardKit;')
wg_product = add('packageProduct/WireGuard', f'isa = XCSwiftPackageProductDependency; package = {wg_package}; productName = WireGuardKit;')
wg_builds = {name: add('build/WireGuard/' + name, f'isa = PBXBuildFile; productRef = {wg_product};') for name in ['AsterOS', 'AsterOSTunnel']}
shared_files = []
shared_builds = {name: [] for name in ['AsterOS', 'AsterOSTunnel']}
for path in sorted((root / 'SharedVPN').glob('*.swift')):
    ref = add(str(path.relative_to(root)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";')
    shared_files.append(ref)
    for name in shared_builds:
        shared_builds[name].append(add('build/shared/' + name + path.name, f'isa = PBXBuildFile; fileRef = {ref};'))
groups = [add('group/SharedVPN', f'isa = PBXGroup; children = {refs(shared_files)}; path = SharedVPN; sourceTree = "<group>";')]
for folder in ['AsterOS', 'AsterOSTests', 'AsterOSTunnel']:
    files = []
    builds = []
    for path in sorted((root / folder).glob('*.swift')):
        ref = add(str(path.relative_to(root)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";')
        files.append(ref)
        builds.append(add('build/' + str(path.relative_to(root)), f'isa = PBXBuildFile; fileRef = {ref};'))
    resources = []
    if folder == 'AsterOS':
        ref = add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
        files.append(ref)
        resources.append(add('build/assets', f'isa = PBXBuildFile; fileRef = {ref};'))
        ref = add('licenses', 'isa = PBXFileReference; lastKnownFileType = text; path = ThirdPartyNotices.txt; sourceTree = "<group>";')
        files.append(ref)
        resources.append(add('build/licenses', f'isa = PBXBuildFile; fileRef = {ref};'))
    groups.append(add('group/' + folder, f'isa = PBXGroup; children = {refs(files)}; path = {folder}; sourceTree = "<group>";'))
    add('sources/' + folder, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds + shared_builds.get(folder, []))}; runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks/' + folder, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(([package_build] if folder == "AsterOS" else []) + ([wg_builds[folder]] if folder in wg_builds else []))}; runOnlyForDeploymentPostprocessing = 0;')
    add('resources/' + folder, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(resources)}; runOnlyForDeploymentPostprocessing = 0;')

products = []
for name, extension, filetype in [('AsterOS','app','wrapper.application'), ('AsterOSTests','xctest','wrapper.cfbundle'), ('AsterOSTunnel','appex','wrapper.app-extension')]:
    products.append(add('product/' + name, f'isa = PBXFileReference; explicitFileType = {filetype}; includeInIndex = 0; path = {name}.{extension}; sourceTree = BUILT_PRODUCTS_DIR;'))
product_group = add('products', f'isa = PBXGroup; children = {refs(products)}; name = Products; sourceTree = "<group>";')
main_group = add('main', f'isa = PBXGroup; children = {refs(groups + [product_group])}; sourceTree = "<group>";')

common = {'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'TARGETED_DEVICE_FAMILY': '1,2'}
for scope in ['project', 'AsterOS', 'AsterOSTests', 'AsterOSTunnel', 'WireGuardBridge']:
    configs = []
    for mode in ['Debug', 'Release']:
        settings = dict(common)
        settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'})
        if mode == 'Debug': settings.update({'ENABLE_TESTABILITY': 'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'ONLY_ACTIVE_ARCH': 'YES'})
        if scope in ['AsterOS', 'AsterOSTests', 'AsterOSTunnel']:
            settings.update({'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.asterlinelabs.' + scope.lower(), 'GENERATE_INFOPLIST_FILE':'YES', 'CODE_SIGN_STYLE':'Automatic', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'0.1.0'})
            if scope == 'AsterOS':
                settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'INFOPLIST_KEY_CFBundleDisplayName':'AsterOS', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_NSLocalNetworkUsageDescription':'Connect to the Unraid server and apps you add on your local network.', 'INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
            elif scope == 'AsterOSTests':
                settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/AsterOS.app/AsterOS', 'BUNDLE_LOADER':'$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
        if scope in ['AsterOS', 'AsterOSTunnel']:
            settings.update({'CODE_SIGN_ENTITLEMENTS': scope + '/' + scope + '.entitlements', '"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]"':'', 'LIBRARY_SEARCH_PATHS':'$(inherited) $(CONFIGURATION_BUILD_DIR)', 'INFOPLIST_KEY_VPNKeychainGroup':'$(AppIdentifierPrefix)com.asterlinelabs.asteros.vpn'})
        if scope == 'AsterOSTunnel':
            settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.asterlinelabs.asteros.tunnel', 'APPLICATION_EXTENSION_API_ONLY':'YES', 'SKIP_INSTALL':'YES', 'GENERATE_INFOPLIST_FILE':'NO', 'INFOPLIST_FILE':'AsterOSTunnel/Info.plist', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'})
        content = ' '.join(f'{k} = {q(v)};' for k,v in sorted(settings.items()))
        configs.append(add('config/' + scope + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {content} }}; name = {mode};'))
    add('configs/' + scope, f'isa = XCConfigurationList; buildConfigurations = {refs(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

proxy = add('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("target/AsterOS")}; remoteInfo = AsterOS;')
dependency = add('dependency', f'isa = PBXTargetDependency; target = {ident("target/AsterOS")}; targetProxy = {proxy};')
bridge_phase = add('phase/bridge', 'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = ("$(CONFIGURATION_BUILD_DIR)/libwg-go.a"); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = ' + q('"$SRCROOT/scripts/build_wireguard.sh"') + ';')
add('target/WireGuardBridge', f'isa = PBXAggregateTarget; buildConfigurationList = {ident("configs/WireGuardBridge")}; buildPhases = {refs([bridge_phase])}; dependencies = (); name = WireGuardBridge; productName = WireGuardBridge;')
bridge_dep = add('dependency/bridge', f'isa = PBXTargetDependency; target = {ident("target/WireGuardBridge")};')
tunnel_dep = add('dependency/tunnel', f'isa = PBXTargetDependency; target = {ident("target/AsterOSTunnel")};')
embed_file = add('build/embedTunnel', f'isa = PBXBuildFile; fileRef = {ident("product/AsterOSTunnel")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
embed_phase = add('phase/embedTunnel', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {refs([embed_file])}; name = "Embed VPN Extension"; runOnlyForDeploymentPostprocessing = 0;')
for name, kind in [('AsterOS','application'), ('AsterOSTests','bundle.unit-test'), ('AsterOSTunnel','app-extension')]:
    add('target/' + name, f'isa = PBXNativeTarget; buildConfigurationList = {ident("configs/" + name)}; buildPhases = {refs([ident(t + "/" + name) for t in ["sources","frameworks","resources"]] + ([embed_phase] if name == "AsterOS" else []))}; buildRules = (); dependencies = {refs([dependency] if name.endswith("Tests") else ([bridge_dep, tunnel_dep] if name == "AsterOS" else [bridge_dep]))}; packageProductDependencies = {refs(([package_product] if name == "AsterOS" else []) + ([wg_product] if name in wg_builds else []))}; name = {name}; productName = {name}; productReference = {ident("product/" + name)}; productType = "com.apple.product-type.{kind}";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {ident("configs/project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; packageReferences = {refs([package, wg_package])}; targets = {refs([ident("target/AsterOS"), ident("target/AsterOSTests"), ident("target/AsterOSTunnel"), ident("target/WireGuardBridge")])};')
project = root / 'AsterOS.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{key} = {{ {value} }};' for key, value in objects.items()) + f'\n}}; rootObject = {ident("project")}; }}\n')
scheme_dir = project / 'xcshareddata' / 'xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
def reference(name, extension): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target/" + name)}" BuildableName="{name}.{extension}" BlueprintName="{name}" ReferencedContainer="container:AsterOS.xcodeproj"/>'
(scheme_dir / 'AsterOS.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference('AsterOS','app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference('AsterOSTests','xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('AsterOS','app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference('AsterOS','app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated AsterOS.xcodeproj with', len(objects), 'objects')
