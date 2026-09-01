#!/usr/bin/env python3
import os, hashlib, textwrap

# simple deterministic ID generator from string
def uid(name):
    h = hashlib.sha256(name.encode()).hexdigest()[:24].upper()
    # ensure first char not 0? but okay
    return h

# Map names to IDs
ids = {}
def get(name):
    if name not in ids:
        ids[name] = uid(name)
    return ids[name]

# Define project structure
# Files
files = [
    ("AuraVizApp.swift", "AuraViz/AuraVizApp.swift"),
    ("ContentView.swift", "AuraViz/ContentView.swift"),
    ("AudioEngineManager.swift", "AuraViz/AudioEngineManager.swift"),
    ("Theme.swift", "AuraViz/Theme.swift"),
    ("CircularVisualizerView.swift", "AuraViz/Visualizers/CircularVisualizerView.swift"),
    ("WaveVisualizerView.swift", "AuraViz/Visualizers/WaveVisualizerView.swift"),
    ("Y2KBarVisualizerView.swift", "AuraViz/Visualizers/Y2KBarVisualizerView.swift"),
    ("Assets.xcassets", "AuraViz/Assets.xcassets"),
    ("AuraViz.entitlements", "AuraViz/AuraViz.entitlements"),
]

# IDs
proj_id = get("Project")
main_group_id = get("MainGroup")
products_group_id = get("Products")
auraviz_group_id = get("AuraVizGroup")
visualizers_group_id = get("VisualizersGroup")
target_id = get("TargetAuraViz")
product_ref_id = get("ProductAuraVizApp")
build_config_list_proj = get("ConfigListProj")
build_config_list_target = get("ConfigListTarget")
config_debug_proj = get("ConfigDebugProj")
config_release_proj = get("ConfigReleaseProj")
config_debug_target = get("ConfigDebugTarget")
config_release_target = get("ConfigReleaseTarget")
sources_phase = get("SourcesPhase")
frameworks_phase = get("FrameworksPhase")
resources_phase = get("ResourcesPhase")

# file refs
file_refs = {}
build_files = {}
for name, path in files:
    file_refs[name] = get(f"FileRef_{name}")
    # build files only for sources/resources
    if name.endswith(".swift") or name.endswith(".xcassets"):
        build_files[name] = get(f"BuildFile_{name}")

# Build config content
pbx = f"""// !$*UTF8*$!
{{
    archiveVersion = 1;
    classes = {{
    }};
    objectVersion = 56;
    objects = {{

/* Begin PBXBuildFile section */
"""
for name in build_files:
    bf = build_files[name]
    fr = file_refs[name]
    ext = "Sources" if name.endswith(".swift") else "Resources"
    pbx += f"\t\t{bf} /* {name} in {ext} */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};\n"
pbx += """/* End PBXBuildFile section */

/* Begin PBXFileReference section */
"""
# file refs
for name, path in files:
    fr = file_refs[name]
    # determine type
    if name.endswith(".swift"):
        typ = "sourcecode.swift"
    elif name.endswith(".xcassets"):
        typ = "folder.assetcatalog"
    elif name.endswith(".entitlements"):
        typ = "text.plist.entitlements"
    else:
        typ = "text"
    pbx += f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {typ}; path = {name}; sourceTree = "<group>"; }};\n'
# product ref
pbx += f'\t\t{product_ref_id} /* AuraViz.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AuraViz.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
pbx += """/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
"""
pbx += f"\t\t{frameworks_phase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"
pbx += """/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
"""
pbx += f"""\t\t{main_group_id} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{auraviz_group_id} /* AuraViz */,
\t\t\t\t{products_group_id} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{products_group_id} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{product_ref_id} /* AuraViz.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{auraviz_group_id} /* AuraViz */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs['AuraVizApp.swift']} /* AuraVizApp.swift */,
\t\t\t\t{file_refs['ContentView.swift']} /* ContentView.swift */,
\t\t\t\t{file_refs['AudioEngineManager.swift']} /* AudioEngineManager.swift */,
\t\t\t\t{file_refs['Theme.swift']} /* Theme.swift */,
\t\t\t\t{visualizers_group_id} /* Visualizers */,
\t\t\t\t{file_refs['Assets.xcassets']} /* Assets.xcassets */,
\t\t\t\t{file_refs['AuraViz.entitlements']} /* AuraViz.entitlements */,
\t\t\t);
\t\t\tpath = AuraViz;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{visualizers_group_id} /* Visualizers */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs['CircularVisualizerView.swift']} /* CircularVisualizerView.swift */,
\t\t\t\t{file_refs['WaveVisualizerView.swift']} /* WaveVisualizerView.swift */,
\t\t\t\t{file_refs['Y2KBarVisualizerView.swift']} /* Y2KBarVisualizerView.swift */,
\t\t\t);
\t\t\tpath = Visualizers;
\t\t\tsourceTree = "<group>";
\t\t}};
"""
pbx += """/* End PBXGroup section */

/* Begin PBXNativeTarget section */
"""
pbx += f"""\t\t{target_id} /* AuraViz */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {build_config_list_target} /* Build configuration list for PBXNativeTarget "AuraViz" */;
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase} /* Sources */,
\t\t\t\t{frameworks_phase} /* Frameworks */,
\t\t\t\t{resources_phase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = AuraViz;
\t\t\tproductName = AuraViz;
\t\t\tproductReference = {product_ref_id} /* AuraViz.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
"""
pbx += """/* End PBXNativeTarget section */

/* Begin PBXProject section */
"""
pbx += f"""\t\t{proj_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1420;
\t\t\t\tLastUpgradeCheck = 1420;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_id} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 14.2;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {build_config_list_proj} /* Build configuration list for PBXProject "AuraViz" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group_id};
\t\t\tproductRefGroup = {products_group_id} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_id} /* AuraViz */,
\t\t\t);
\t\t}};
"""
pbx += """/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
"""
pbx += f"""\t\t{resources_phase} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{build_files['Assets.xcassets']} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
"""
pbx += """/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
"""
pbx += f"""\t\t{sources_phase} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
"""
for name in ["AuraVizApp.swift","ContentView.swift","AudioEngineManager.swift","Theme.swift","CircularVisualizerView.swift","WaveVisualizerView.swift","Y2KBarVisualizerView.swift"]:
    pbx += f"\t\t\t\t{build_files[name]} /* {name} in Sources */,\n"
pbx += """\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
pbx += """/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
"""
pbx += f"""\t\t{config_debug_proj} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{config_release_proj} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{config_debug_target} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_LSUIElement = NO;
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = AuraViz;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.music";
\t\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = "AuraViz uses microphone input when Microphone mode is selected.";
\t\t\t\tINFOPLIST_KEY_NSSupportsAutomaticGraphicsSwitching = YES;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.auraviz.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = AuraViz/AuraViz.entitlements;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{config_release_target} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_LSUIElement = NO;
\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = AuraViz;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.music";
\t\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = "AuraViz uses microphone input when Microphone mode is selected.";
\t\t\t\tINFOPLIST_KEY_NSSupportsAutomaticGraphicsSwitching = YES;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.auraviz.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = AuraViz/AuraViz.entitlements;
\t\t\t\tENABLE_HARDENED_RUNTIME = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
"""
pbx += """/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
"""
pbx += f"""\t\t{build_config_list_proj} /* Build configuration list for PBXProject "AuraViz" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{config_debug_proj} /* Debug */,
\t\t\t\t{config_release_proj} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{build_config_list_target} /* Build configuration list for PBXNativeTarget "AuraViz" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{config_debug_target} /* Debug */,
\t\t\t\t{config_release_target} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
"""
pbx += """/* End XCConfigurationList section */
\t};
\trootObject = """
pbx += f"{proj_id} /* Project object */;\n}}\n"

out_path = "/Users/wlinwork/projects/AuraViz/AuraViz.xcodeproj/project.pbxproj"
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    f.write(pbx)
print(f"Wrote {out_path}")
# also dump ids for debug
for k,v in ids.items():
    print(k, v)
