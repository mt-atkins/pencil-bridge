#!/usr/bin/env python3
"""Generate the dependency-free Xcode project using only the Python standard library."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

root = Path(__file__).resolve().parents[1]
project = root / 'PencilBridge.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    key = ident(name)
    objects[key] = text
    return key
def quote(value):
    return json.dumps(str(value))
def settings(values):
    return '{ ' + ' '.join(f'{k} = {quote(v)};' for k, v in values.items()) + ' }'

def format_scheme(source):
    """Match Xcode's scheme formatting to avoid changes just from opening it."""
    element = ET.fromstring(source)
    element.set('version', '1.7')
    element.insert(1, ET.Element('TestAction', {
        'buildConfiguration': 'Debug',
        'selectedDebuggerIdentifier': 'Xcode.DebuggerFoundation.Debugger.LLDB',
        'selectedLauncherIdentifier': 'Xcode.DebuggerFoundation.Launcher.LLDB',
        'shouldUseLaunchSchemeArgsEnv': 'YES', 'shouldAutocreateTestPlan': 'YES',
    }))
    launch = element.find('LaunchAction')
    launch.set('debugServiceExtension', 'internal')
    # Xcode writes this property before allowLocationSimulation.
    simulation = launch.attrib.pop('allowLocationSimulation')
    launch.set('allowLocationSimulation', simulation)
    profile = element.find('ProfileAction')
    profile.attrib.update(shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='',
                          useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
    def render(node, level=0):
        indent = '   ' * level
        lines = [indent + '<' + node.tag]
        for key, value in node.attrib.items():
            lines.append(indent + '   ' + key + ' = "' + escape(value, {'"': '&quot;'}) + '"')
        lines[-1] += '>'
        for child in node:
            lines.extend(render(child, level + 1))
        lines.append(indent + '</' + node.tag + '>')
        return lines
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + '\n'.join(render(element)) + '\n'

sources = [str(p.relative_to(root)) for folder in ('Shared', 'Mac', 'iPad') for p in sorted((root / folder).glob('*.swift'))]
refs = {p: add('ref:' + p, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ' + quote(p) + '; sourceTree = "<group>"; }') for p in sources}
product_refs = []
targets = []
for platform, target, bundle, sdk, deployment in [
    ('Mac', 'PencilBridgeMac', 'dev.morgan.pencilbridge.mac', 'macosx', ('MACOSX_DEPLOYMENT_TARGET', '14.0')),
    ('iPad', 'PencilBridgeiPad', 'dev.morgan.pencilbridge.ipad', 'iphoneos', ('IPHONEOS_DEPLOYMENT_TARGET', '16.0')),
]:
    selected = [p for p in sources if p.startswith('Shared/') or p.startswith(platform + '/')]
    builds = [add('build:' + target + p, '{isa = PBXBuildFile; fileRef = ' + refs[p] + '; }') for p in selected]
    source_phase = add('sources:' + target, '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(builds) + '); runOnlyForDeploymentPostprocessing = 0; }')
    frameworks = add('frameworks:' + target, '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    resources = add('resources:' + target, '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    product = add('product:' + target, '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ' + target + '.app; sourceTree = BUILT_PRODUCTS_DIR; }')
    product_refs.append(product)
    configs = []
    for config in ['Debug', 'Release']:
        values = {
            'PRODUCT_NAME': target, 'PRODUCT_BUNDLE_IDENTIFIER': bundle, 'SDKROOT': sdk,
            'INFOPLIST_FILE': platform + '/Info.plist', 'SWIFT_VERSION': '5.0',
            'CODE_SIGN_STYLE': 'Automatic', 'ENABLE_HARDENED_RUNTIME': 'YES',
            'GENERATE_INFOPLIST_FILE': 'NO', 'MARKETING_VERSION': '0.2.0', 'CURRENT_PROJECT_VERSION': '2',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
            deployment[0]: deployment[1],
        }
        if os.environ.get('DEVELOPMENT_TEAM'):
            values['DEVELOPMENT_TEAM'] = os.environ['DEVELOPMENT_TEAM']
        if platform == 'iPad':
            values.update(TARGETED_DEVICE_FAMILY='2', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO')
        else:
            # Local Network privacy uses the main executable UUID. Avoid a reusable
            # debug launcher stub hiding changes to the app's service declarations.
            values['ENABLE_DEBUG_DYLIB'] = 'NO'
        configs.append(add(target + config, '{isa = XCBuildConfiguration; name = ' + config + '; buildSettings = ' + settings(values) + '; }'))
    config_list = add('configs:' + target, '{isa = XCConfigurationList; buildConfigurations = (' + ','.join(configs) + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
    target_id = add('target:' + target, '{isa = PBXNativeTarget; buildConfigurationList = ' + config_list + '; buildPhases = (' + ','.join([source_phase, frameworks, resources]) + '); buildRules = (); dependencies = (); name = ' + target + '; productName = ' + target + '; productReference = ' + product + '; productType = "com.apple.product-type.application"; }')
    targets.append(target_id)
    plist = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleDisplayName': 'Pencil Bridge',
        'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'Pencil Bridge', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)',
        'NSLocalNetworkUsageDescription': 'Connect your iPad and Mac to send Apple Pencil input over your local network.',
        'NSBonjourServices': ['_pencilbridge._tcp', '_pencilqr._tcp'],
    }
    if platform == 'iPad':
        plist['NSCameraUsageDescription'] = 'Scan the pairing QR code displayed by Pencil Bridge on your Mac.'
        plist.update(LSRequiresIPhoneOS=True, UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
    else:
        plist.update(LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication')
    (root / platform / 'Info.plist').write_bytes(plistlib.dumps(plist))
    schemes = project / 'xcshareddata' / 'xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{target}.app" BlueprintName="{target}" ReferencedContainer="container:PencilBridge.xcodeproj"/>'
    (schemes / f'{target}.xcscheme').write_text(format_scheme(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''))

products = add('products', '{isa = PBXGroup; children = (' + ','.join(product_refs) + '); name = Products; sourceTree = "<group>"; }')
group = add('main-group', '{isa = PBXGroup; children = (' + ','.join(list(refs.values()) + [products]) + '); sourceTree = "<group>"; }')
project_configs = [add('project:' + c, '{isa = XCBuildConfiguration; name = ' + c + '; buildSettings = { CLANG_ENABLE_MODULES = YES; }; }') for c in ['Debug', 'Release']]
project_list = add('project-configs', '{isa = XCConfigurationList; buildConfigurations = (' + ','.join(project_configs) + '); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
project_id = add('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 1640; }; buildConfigurationList = ' + project_list + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = ' + group + '; productRefGroup = ' + products + '; projectDirPath = ""; projectRoot = ""; targets = (' + ','.join(targets) + '); }')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(k + ' = ' + v + ';' for k, v in objects.items()) + '\n}; rootObject = ' + project_id + '; }\n')
print('Generated', project)
