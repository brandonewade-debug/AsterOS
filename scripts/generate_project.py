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

package = add('package/SMBClient', 'isa = XCLocalSwiftPackageReference; relativePath = .build/dependencies/SMBClient;')
package_product = add('packageProduct/SMBClient', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = SMBClient;')
package_build = add('build/SMBClient', f'isa = PBXBuildFile; productRef = {package_product};')
framework_ref = add('tailscaleFramework', 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = .build/frameworks/TailscaleKit.xcframework; sourceTree = SOURCE_ROOT;')
framework_build = add('build/tailscaleFramework', f'isa = PBXBuildFile; fileRef = {framework_ref};')
framework_embed = add('embed/tailscaleFramework', f'isa = PBXBuildFile; fileRef = {framework_ref}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy,); }};')
groups = []
for folder in ['AsterOS', 'AsterOSTests']:
    files = []
    builds = []
    for path in sorted((root / folder).glob('*.swift')):
        if path.name in ['VPNStore.swift', 'VPNSetupView.swift']: continue
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
    add('sources/' + folder, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks/' + folder, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(([package_build, framework_build] if folder == "AsterOS" else []))}; runOnlyForDeploymentPostprocessing = 0;')
    add('resources/' + folder, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(resources)}; runOnlyForDeploymentPostprocessing = 0;')

products = []
for name, extension, filetype in [('AsterOS','app','wrapper.application'), ('AsterOSTests','xctest','wrapper.cfbundle')]:
    products.append(add('product/' + name, f'isa = PBXFileReference; explicitFileType = {filetype}; includeInIndex = 0; path = {name}.{extension}; sourceTree = BUILT_PRODUCTS_DIR;'))
product_group = add('products', f'isa = PBXGroup; children = {refs(products)}; name = Products; sourceTree = "<group>";')
main_group = add('main', f'isa = PBXGroup; children = {refs(groups + [framework_ref, product_group])}; sourceTree = "<group>";')

common = {'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '18.1', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'TARGETED_DEVICE_FAMILY': '1,2'}
for scope in ['project', 'AsterOS', 'AsterOSTests']:
    configs = []
    for mode in ['Debug', 'Release']:
        settings = dict(common)
        settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'})
        if mode == 'Debug': settings.update({'ENABLE_TESTABILITY': 'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'ONLY_ACTIVE_ARCH': 'YES'})
        if scope in ['AsterOS', 'AsterOSTests']:
            settings.update({'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.asterlinelabs.' + scope.lower(), 'GENERATE_INFOPLIST_FILE':'YES', 'CODE_SIGN_STYLE':'Automatic', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'0.1.0'})
            if scope == 'AsterOS':
                settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'INFOPLIST_KEY_CFBundleDisplayName':'AsterOS', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES', 'INFOPLIST_KEY_NSPhotoLibraryUsageDescription':'Back up the photos and videos you allow to your chosen Unraid share. AsterOS never deletes your originals.', 'INFOPLIST_KEY_NSLocalNetworkUsageDescription':'Connect to the Unraid server and apps you add on your local network.', 'INFOPLIST_KEY_UISupportedInterfaceOrientations':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
            elif scope == 'AsterOSTests':
                settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/AsterOS.app/AsterOS', 'BUNDLE_LOADER':'$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
        content = ' '.join(f'{k} = {q(v)};' for k,v in sorted(settings.items()))
        configs.append(add('config/' + scope + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {content} }}; name = {mode};'))
    add('configs/' + scope, f'isa = XCConfigurationList; buildConfigurations = {refs(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

proxy = add('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("target/AsterOS")}; remoteInfo = AsterOS;')
dependency = add('dependency', f'isa = PBXTargetDependency; target = {ident("target/AsterOS")}; targetProxy = {proxy};')
embed_phase = add('phase/embedTailscale', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = {refs([framework_embed])}; name = "Embed TailscaleKit"; runOnlyForDeploymentPostprocessing = 0;')
for name, kind in [('AsterOS','application'), ('AsterOSTests','bundle.unit-test')]:
    add('target/' + name, f'isa = PBXNativeTarget; buildConfigurationList = {ident("configs/" + name)}; buildPhases = {refs([ident(t + "/" + name) for t in ["sources","frameworks","resources"]] + ([embed_phase] if name == "AsterOS" else []))}; buildRules = (); dependencies = {refs([dependency] if name.endswith("Tests") else [])}; packageProductDependencies = {refs(([package_product] if name == "AsterOS" else []))}; name = {name}; productName = {name}; productReference = {ident("product/" + name)}; productType = "com.apple.product-type.{kind}";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {ident("configs/project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; packageReferences = {refs([package])}; targets = {refs([ident("target/AsterOS"), ident("target/AsterOSTests")])};')
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
