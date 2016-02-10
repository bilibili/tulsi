// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Information about the Xcode file format that should be used to serialize PBXObjects.
// These values can be obtained by inspecting a generated .xcodeproj file (but generally newer
// Xcode versions can parse properly formatted old file versions).
let XcodeVersionInfo = (objectVersion: "46", compatibilityVersion: "Xcode 3.2")


/// Valid values for the sourceTree field on PBXReference-derived classes. These values correspond to
/// the "Location" selector in Xcode's File Inspector and indicate how the path field in the
/// PBXReference should be handled.
enum SourceTree: String {
  /// "Relative to Group" indicates that the path is relative to the group enclosing this reference.
  case Group = "<group>"

  /// "Absolute Path" indicates that the path is absolute.
  case Absolute = "<absolute>"

  /// "Relative to Build Products" indicates that the path is relative to the BUILT_PRODUCTS_DIR
  /// environment variable.
  case BuiltProductsDir = "BUILT_PRODUCTS_DIR"

  /// "Relative to SDK" indicates that the path is relative to the SDKROOT environment variable.
  case SDKRoot = "SDKROOT"

  /// "Relative to Project" indicates that the path is relative to the SOURCE_ROOT environment
  /// variable (likely the parent of the .pbxcodeproj bundle).
  case SourceRoot = "SOURCE_ROOT"

  /// "Relative to Developer Directory" indicates that the path is relative to the DEVELOPER_DIR
  /// environment variable (likely the Developer directory within the running Xcode.app bundle).
  case DeveloperDir = "DEVELOPER_DIR"
}


// Models a path within an Xcode project file.
struct SourceTreePath: Hashable {
  /// Indicates the type of "path".
  var sourceTree: SourceTree
  var path: String
  var hashValue: Int {
    return sourceTree.hashValue &+ path.hashValue
  }
}

func == (lhs: SourceTreePath, rhs: SourceTreePath) -> Bool {
  return (lhs.sourceTree == rhs.sourceTree) && (lhs.path == rhs.path)
}


/// Protocol for all serializable project objects.
protocol PBXObjectProtocol: PBXProjSerializable {
  /// Provides a string identifying this object's type.
  var isa: String { get }
  /// Used in the generation of globally unique IDs.
  var hashValue: Int { get }
  var globalID: String { get set }
}


/// Models a collection of build settings.
class XCBuildConfiguration: PBXObjectProtocol {
  var globalID: String = ""
  let name: String
  var buildSettings = [String:String]()
  var baseConfigurationReference: PBXFileReference?

  var isa: String {
    return "XCBuildConfiguration"
  }

  var hashValue: Int {
    return name.hashValue
  }

  init(name: String) {
    self.name = name
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("name", name)
    try serializer.addField("buildSettings", buildSettings)
    try serializer.addField("baseConfigurationReference", baseConfigurationReference)
  }
}


/// Internal base class for file references and groups.
class PBXReference: PBXObjectProtocol {
  var globalID: String = ""
  let name: String
  let path: String?
  let sourceTree: SourceTree

  var isa: String {
    assertionFailure("PBXReference must be subclassed")
    return ""
  }

  var hashValue: Int {
    return name.hashValue
  }

  var fileExtension: String? {
    guard let p = path else { return nil }
    return p.pbPathExtension
  }

  var uti: String? {
    guard let p = path else { return nil }
    return p.pbPathUTI
  }

  init(name: String, path: String?, sourceTree: SourceTree) {
    self.name = name;
    self.path = path
    self.sourceTree = sourceTree
  }

  convenience init(name: String, sourceTreePath: SourceTreePath) {
    self.init(name: name, path: sourceTreePath.path, sourceTree: sourceTreePath.sourceTree)
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("name", name)
    try serializer.addField("path", path)
    try serializer.addField("sourceTree", sourceTree.rawValue)
  }
}


/// PBXFileReference instances are used to track each file in the project.
class PBXFileReference: PBXReference, Hashable {
  // A PBXFileReference for an input will have lastKnownFileType set to the file's UTI. An output
  // will have explicitFileType set. The types used correspond to the "Type" field shown in Xcode's
  // File Inspector.
  var explicitFileType: String? {
    if !isInputFile {
      return fileType
    }
    return nil
  }
  var lastKnownFileType: String? {
    if isInputFile {
      return fileType
    }
    return nil
  }

  /// Override for this file reference's UTI.
  var fileTypeOverride: String?

  /// Whether or not this file reference is for a project input file.
  var isInputFile: Bool = false

  override var isa: String {
    return "PBXFileReference"
  }

  /// Returns the path to this file reference relative to the source root group.
  /// Access time is linear, depending on the number of parent groups.
  var sourceRootRelativePath: String {
    var parentHierarchy = [path!]
    var group = parent
    while (group != nil && group!.path != nil) {
      parentHierarchy.append(group!.path!)
      group = group!.parent
    }

    let fullPath = parentHierarchy.reverse().joinWithSeparator("/")
    return fullPath
  }

  private var fileType: String? {
    if fileTypeOverride != nil {
      return fileTypeOverride
    }

    return name.pbPathUTI
  }

  private weak var parent: PBXGroup?

  init(name: String, path: String?, sourceTree: SourceTree, parent: PBXGroup?) {
    self.parent = parent
    super.init(name: name, path: path, sourceTree: sourceTree)
  }

  convenience init(name: String, sourceTreePath: SourceTreePath, parent: PBXGroup?) {
    self.init(name: name, path: sourceTreePath.path, sourceTree: sourceTreePath.sourceTree, parent: parent)
  }

  override func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try super.serializeInto(serializer)

    guard let uti = fileType else { return }
    if isInputFile {
      try serializer.addField("lastKnownFileType", uti)
    } else {
      try serializer.addField("explicitFileType", uti)
      // TODO(abaire): set includeInIndex to 0 for output files?
    }
  }
}

func == (lhs: PBXFileReference, rhs: PBXFileReference) -> Bool {
  return lhs.isInputFile == rhs.isInputFile &&
      lhs.fileType == rhs.fileType &&
      lhs.sourceTree == rhs.sourceTree &&
      lhs.name == rhs.name &&
      lhs.path == rhs.path
}


/// PBXGroups are simple containers for other PBXReference instances.
class PBXGroup: PBXReference {
  /// Array of reference objects contained by this group.
  var children = [PBXReference]()

  // Indexes for typed access of children.
  var childGroupsByName = [String: PBXGroup]()
  var childVariantGroupsByName = [String: PBXVariantGroup]()
  var fileReferencesBySourceTreePath = [SourceTreePath: PBXFileReference]()

  override var isa: String {
    return "PBXGroup"
  }

  // TODO(dmaclach): Passing back file references is pretty useless for groups.
  // Probably want to change to paths or maybe just walk the fileReferencesBySourceTreePath.
  var allSources: [PBXFileReference] {
    var refs: [PBXFileReference] = []
    for reference in children {
      if let fileReference = reference as? PBXFileReference {
        refs.append(fileReference)
      } else if let groupReference = reference as? PBXGroup {
        refs.appendContentsOf(groupReference.allSources)
      }
    }
    return refs
  }

  var parent: PBXGroup? {
    return _Parent
  }
  private weak var _Parent: PBXGroup?

  init(name: String, path: String?, sourceTree: SourceTree, parent: PBXGroup?) {
    self._Parent = parent
    super.init(name: name, path: path, sourceTree: sourceTree)
  }

  convenience init(name: String, sourceTreePath: SourceTreePath, parent: PBXGroup?) {
    self.init(name: name, path: sourceTreePath.path, sourceTree: sourceTreePath.sourceTree, parent: parent)
  }

  func getOrCreateChildGroupByName(name: String, path: String?) -> PBXGroup {
    if let value = childGroupsByName[name] {
      return value
    }
    let value = PBXGroup(name: name, path: path, sourceTree: .Group, parent: self)
    childGroupsByName[name] = value
    children.append(value)
    return value
  }

  func getOrCreateChildVariantGroupByName(name: String) -> PBXVariantGroup {
    if let value = childVariantGroupsByName[name] {
      return value
    }
    let value = PBXVariantGroup(name: name, path: nil, sourceTree: .Group, parent: self)
    childVariantGroupsByName[name] = value
    children.append(value)
    return value
  }

  func getOrCreateFileReferenceBySourceTree(sourceTree: SourceTree, path: String) -> PBXFileReference {
    return getOrCreateFileReferenceBySourceTreePath(SourceTreePath(sourceTree:sourceTree, path:path))
  }

  func getOrCreateFileReferenceBySourceTreePath(sourceTreePath: SourceTreePath) -> PBXFileReference {
    if let value = fileReferencesBySourceTreePath[sourceTreePath] {
      return value
    }
    let value = PBXFileReference(name: sourceTreePath.path.pbPathLastComponent, sourceTreePath: sourceTreePath, parent:self)
    fileReferencesBySourceTreePath[sourceTreePath] = value
    children.append(value)
    return value
  }

  override func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try super.serializeInto(serializer)
    try serializer.addField("children", children.sort({$0.name < $1.name}))
  }
}


/// Models a localized resource group.
class PBXVariantGroup: PBXGroup {
  override var isa: String {
    return "PBXVariantGroup"
  }
}


/// Models the set of XCBuildConfiguration instances for a given target or project.
class XCConfigurationList: PBXObjectProtocol {
  var globalID: String = ""
  var buildConfigurations = [String: XCBuildConfiguration]()

  var isa: String {
    return "XCConfigurationList"
  }

  var hashValue: Int {
    return 0
  }

  func getOrCreateBuildConfiguration(name: String) -> XCBuildConfiguration {
    if let value = buildConfigurations[name] {
      return value
    }
    let value = XCBuildConfiguration(name: name)
    buildConfigurations[name] = value
    return value
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("buildConfigurations", buildConfigurations.values.sort({$0.name < $1.name}))
  }
}


/// Internal base class for concrete build phases (each of which capture a set of files that will be
/// used as inputs to that phase).
class PBXBuildPhase: PBXObjectProtocol  {
  var globalID: String = ""
  var files = [PBXBuildFile]()

  var isa: String {
    assertionFailure("PBXBuildPhase must be subclassed")
    return ""
  }

  var hashValue: Int {
    assertionFailure("PBXBuildPhase must be subclassed")
    return 0
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws{
    try serializer.addField("files", files)
  }
}


/// Encapsulates a source file compilation phase.
class PBXSourcesBuildPhase: PBXBuildPhase  {
  override var isa: String {
    return "PBXSourcesBuildPhase"
  }

  override var hashValue: Int {
    return 0
  }
}


/// Encapsulates a shell script execution phase.
class PBXShellScriptBuildPhase: PBXBuildPhase {
  let inputPaths: [String]
  let outputPaths: [String]
  let shellPath: String
  let shellScript: String
  var showEnvVarsInLog = false

  override var isa: String {
    return "PBXShellScriptBuildPhase"
  }

  override var hashValue: Int {
    return shellPath.hashValue &+ shellScript.hashValue
  }

  init(shellScript: String,
       shellPath: String = "/bin/sh",
       inputPaths: [String] = [String](),
       outputPaths: [String] = [String]()) {
    self.shellScript = shellScript
    self.shellPath = shellPath
    self.inputPaths = inputPaths
    self.outputPaths = outputPaths

    super.init()
  }

  override func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try super.serializeInto(serializer)
    try serializer.addField("inputPaths", inputPaths)
    try serializer.addField("outputPaths", outputPaths)
    try serializer.addField("shellPath", shellPath)
    try serializer.addField("shellScript", shellScript)
    try serializer.addField("showEnvVarsInLog", showEnvVarsInLog)
  }
}


/// File reference with associated build flags (set in Xcode via the Compile Sources phase). This
/// extra level of indirection allows any given PBXFileReference to be included in multiple targets
/// with different COMPILER_FLAGS settings for each. (e.g., a file could have a preprocessor define
/// set while compiling a test target that is not set when building the main target).
class PBXBuildFile: PBXObjectProtocol {
  var globalID: String = ""
  let fileRef: PBXFileReference
  let settings: [String: String]?

  init(fileRef: PBXFileReference, settings: [String: String]? = nil) {
    self.fileRef = fileRef
    self.settings = settings
  }

  var hashValue: Int {
    return fileRef.hashValue
  }

  var isa: String {
    return "PBXBuildFile"
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("fileRef", fileRef)
    if let concreteSettings = settings {
      try serializer.addField("settings", concreteSettings)
    }
  }
}


/// Base class for concrete build targets.
class PBXTarget: PBXObjectProtocol, Hashable {
  enum ProductType: String {
    case StaticLibrary = "com.apple.product-type.library.static"
    case DynamicLibrary = "com.apple.product-type.library.dynamic"
    case Tool = "com.apple.product-type.tool"
    case Bundle = "com.apple.product-type.bundle"
    case Framework = "com.apple.product-type.framework"
    case StaticFramework = "com.apple.product-type.framework.static"
    case Application = "com.apple.product-type.application"
    case UnitTest = "com.apple.product-type.bundle.unit-test"
    case UIUnitTest = "com.apple.product-type.bundle.ui-testing"
    case InAppPurchaseContent = "com.apple.product-type.in-app-purchase-content"
    case AppExtension = "com.apple.product-type.app-extension"
    case XPCService = "com.apple.product-type.xpc-service"
  }

  var globalID: String = ""
  let name: String
  let productName: String?
  let buildConfigurationList = XCConfigurationList()
  /// The targets on which this target depends.
  var dependencies = [PBXTargetDependency]()
  /// The build phases to be executed to generate this target.
  var buildPhases = [PBXBuildPhase]()

  var isa: String {
    assertionFailure("PBXTarget must be subclassed")
    return ""
  }

  var hashValue: Int {
    return name.hashValue
  }

  init(name: String) {
    self.name = name
    self.productName = name
  }

  /// Creates a dependency on the given target.
  /// If first is true, the dependency will be prepended instead of appended.
  func createDependencyOn(target: PBXTarget,
                          proxyType: PBXContainerItemProxy.ProxyType,
                          inProject project: PBXProject,
                          first: Bool = false) {
    if target === self {
      assert(target !== self, "Targets may not be dependent on themselves.")
      return
    }

    let dependency = project.createTargetDependency(target, proxyType: proxyType)
    if first {
      dependencies.insert(dependency, atIndex: 0)
    } else {
      dependencies.append(dependency)
    }
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("name", name)
    try serializer.addField("productName", productName)
    try serializer.addField("dependencies", dependencies)
    try serializer.addField("buildPhases", buildPhases)
    try serializer.addField("buildConfigurationList", buildConfigurationList)
  }
}

func == (lhs: PBXTarget, rhs: PBXTarget) -> Bool {
  // TODO(abaire): check that PBXProjects match- name is only unique with project scope.
  return lhs.name == rhs.name
}


/// Models a target that produces a binary.
class PBXNativeTarget: PBXTarget {
  let productType: ProductType

  /// Reference to the output of this target.
  var productReference: PBXFileReference?

  override var isa: String {
    return "PBXNativeTarget"
  }

  init(name: String, productType: ProductType) {
    self.productType = productType
    super.init(name: name)
  }

  override func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try super.serializeInto(serializer)
    try serializer.addField("productType", productType.rawValue)
    try serializer.addField("productReference", productReference)
  }
}


/// Models a target that executes an arbitray binary.
class PBXLegacyTarget: PBXTarget {
  let buildArgumentsString: String
  let buildToolPath: String
  let buildWorkingDirectory: String
  var passBuildSettingsInEnvironment: Bool = true

  override var isa: String {
    return "PBXLegacyTarget"
  }

  init(name: String, buildToolPath: String, buildArguments: String, buildWorkingDirectory: String) {
    self.buildToolPath = buildToolPath
    self.buildArgumentsString = buildArguments
    self.buildWorkingDirectory = buildWorkingDirectory
    super.init(name: name)
  }

  override func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try super.serializeInto(serializer)
    try serializer.addField("buildArgumentsString", buildArgumentsString)
    try serializer.addField("buildToolPath", buildToolPath)
    try serializer.addField("buildWorkingDirectory", buildWorkingDirectory)
    try serializer.addField("passBuildSettingsInEnvironment", passBuildSettingsInEnvironment)
  }
}


/// Models a link to a target or output file which may be in a different project.
class PBXContainerItemProxy: PBXObjectProtocol, Hashable {
  /// The type of the item being referenced.
  enum ProxyType: Int {
    /// Refers to a PBXTarget in some project file.
    case TargetReference = 1

    /// Refers to a PBXFileReference in some other project file (an output of another project's
    /// target).
    case FileReference = 2
  }

  var globalID: String = ""

  /// The project containing the referenced item.
  var containerPortal: PBXProject {
    return _ContainerPortal!
  }
  private weak var _ContainerPortal: PBXProject?

  /// The target being tracked by this proxy.
  var target: PBXObjectProtocol {
    return _Target!
  }
  private weak var _Target: PBXObjectProtocol?

  let proxyType: ProxyType

  var isa: String {
    return "PBXContainerItemProxy"
  }

  var hashValue: Int {
    return _Target!.hashValue &+ proxyType.rawValue
  }

  init(containerPortal: PBXProject, target: PBXObjectProtocol, proxyType: ProxyType) {
    self._ContainerPortal = containerPortal
    self._Target = target
    self.proxyType = proxyType
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    try serializer.addField("containerPortal", _ContainerPortal)
    try serializer.addField("remoteGlobalIDString", _Target)
    try serializer.addField("proxyType", proxyType.rawValue)
    // TODO(abaire): Consider writing out remoteInfo as well (the name of the proxied target/file).
  }
}

func == (lhs: PBXContainerItemProxy, rhs: PBXContainerItemProxy) -> Bool {
  if lhs.proxyType != rhs.proxyType { return false }

  switch lhs.proxyType {
    case .TargetReference:
      return lhs._Target as? PBXTarget == rhs._Target as? PBXTarget
    case .FileReference:
      return lhs._Target as? PBXFileReference == rhs._Target as? PBXFileReference
  }
}


/// Models a dependent relationship between a build target and some other build target.
class PBXTargetDependency: PBXObjectProtocol {
  var globalID: String = ""
  let targetProxy: PBXContainerItemProxy

  init(targetProxy: PBXContainerItemProxy) {
    self.targetProxy = targetProxy
  }

  var isa: String {
    return "PBXTargetDependency"
  }

  var hashValue: Int {
    return targetProxy.hashValue
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    // Note(abaire): Xcode also generates a "target" field.
    try serializer.addField("targetProxy", targetProxy)
  }
}


/// Models a project container.
class PBXProject: PBXObjectProtocol {
  var globalID: String = ""
  let name: String

  /// The root group for this project.
  let mainGroup: PBXGroup

  /// Map of target name to target instance.
  var targetByName = [String: PBXTarget]()

  /// List of all targets.
  var allTargets: LazyMapCollection<Dictionary<String, PBXTarget>, PBXTarget> {
    return targetByName.values
  }

  let compatibilityVersion = XcodeVersionInfo.compatibilityVersion
  let lastUpgradeCheck = "0610"  // TODO(abaire): Is this actually needed?
  /// May be set to an Xcode version string indicating the last time a Swift upgrade check was
  /// performed (e.g., 0710).
  var lastSwiftUpdateCheck: String? = nil

  /// List of (testTarget, hostTarget) pairs linking test targets to their host applications.
  var testTargetLinkages = [(PBXTarget, PBXTarget)]()

  // Maps container proxies to PBXTargetDependency instances to facilitate reuse of target
  // dependency instances.
  var targetDependencies = [PBXContainerItemProxy: PBXTargetDependency]()

  let buildConfigurationList =  XCConfigurationList()

  var isa: String {
    return "PBXProject"
  }

  var hashValue: Int {
    return name.hashValue
  }

  init(name: String, mainGroup: PBXGroup? = nil) {
    if mainGroup != nil {
      self.mainGroup = mainGroup!
    } else {
      self.mainGroup = PBXGroup(name: "mainGroup", path: nil, sourceTree: .SourceRoot, parent: nil)
    }
    self.name = name
  }

  func createNativeTarget(name: String, targetType: PBXTarget.ProductType) -> PBXTarget {
    let value = PBXNativeTarget(name: name, productType: targetType)
    targetByName[name] = value

    let productName: String
    let explicitFileType: String
    switch targetType {
      case .StaticLibrary:
        productName = "lib" + name + ".a"
        explicitFileType = "archive.ar"
      case .DynamicLibrary:
        productName = "lib" + name + ".dylib"
        explicitFileType = "compiled.mach-o.dylib"
      case .Tool:
        productName = name
        explicitFileType = "compiled.mach-o.executable"
      case .Bundle:
        productName = name + ".bundle"
        explicitFileType = "wrapper.bundle"
      case .Framework:
        productName = name + ".framework"
        explicitFileType = "wrapper.framework"
      case .StaticFramework:
        productName = name + ".framework"
        explicitFileType = "wrapper.framework.static"
      case .Application:
        productName = name + ".app"
        explicitFileType = "wrapper.application"
      case .UnitTest:
        fallthrough
      case .UIUnitTest:
        productName = name + ".xctest"
        explicitFileType = "wrapper.cfbundle"
      case .InAppPurchaseContent:
        productName = name
        explicitFileType = "folder"
      case .AppExtension:
        productName = name + ".appex"
        explicitFileType = "wrapper.app-extension"
      case .XPCService:
        productName = name + ".xpc"
        explicitFileType = "wrapper.xpc-service"
    }
    let productReference = PBXFileReference(name: productName, path: productName, sourceTree: .BuiltProductsDir, parent: nil)
    productReference.fileTypeOverride = explicitFileType
    productReference.isInputFile = false
    value.productReference = productReference

    return value
  }

  func createLegacyTarget(name: String, buildToolPath: String, buildArguments: String, buildWorkingDirectory: String) -> PBXLegacyTarget {
    let value = PBXLegacyTarget(name: name, buildToolPath: buildToolPath, buildArguments: buildArguments, buildWorkingDirectory: buildWorkingDirectory)
    targetByName[name] = value
    return value
  }

  func linkTestTarget(testTarget: PBXTarget, toHostTarget hostTarget: PBXTarget) {
    testTargetLinkages.append((testTarget, hostTarget))
    testTarget.createDependencyOn(hostTarget,
                                  proxyType:PBXContainerItemProxy.ProxyType.TargetReference,
                                  inProject: self)
  }

  func linkedTestTargetsForHost(host: PBXTarget) -> [PBXTarget] {
    let targetHostPairs = testTargetLinkages.filter() {
      (testTarget: PBXTarget, testHostTarget: PBXTarget) -> Bool in
        testHostTarget == host
    }

    return targetHostPairs.map() { $0.0 }
  }

  func createTargetDependency(target: PBXTarget, proxyType: PBXContainerItemProxy.ProxyType) -> PBXTargetDependency {
    let targetProxy = PBXContainerItemProxy(containerPortal: self, target: target, proxyType: proxyType)
    if let existingDependency = targetDependencies[targetProxy] {
      return existingDependency
    }

    let dependency = PBXTargetDependency(targetProxy: targetProxy)
    targetDependencies[targetProxy] = dependency
    return dependency
  }

  func targetByName(name: String) -> PBXTarget? {
    return targetByName[name]
  }

  /// Creates subgroups and file references for the given set of paths. Path directory components
  /// will be expanded into nested PBXGroup instances with the filename component made into a
  /// PBXFileReference.
  /// Returns a tuple containing the PBXGroup and PBXFileReference instances that were touched while
  /// processing the set of paths.
  func getOrCreateGroupsAndFileReferencesForPaths(paths: [String]) -> ([PBXGroup], [PBXFileReference]) {
    var accessedGroups = [PBXGroup]()
    var accessedFileReferences = [PBXFileReference]()

    pathsLoop: for path in paths {
      var group = mainGroup

      // Traverse the directory components of the path, converting them to Xcode
      // PBXGroups.
      let components = path.componentsSeparatedByString("/")
      for var i = 0; i < components.count - 1; ++i {
        // Check to see if this component is actually a bundle that should be treated as a file
        // reference by Xcode (e.g., .xcassets bundles) instead of as a PBXGroup.
        let currentComponent = components[i]
        // TODO(abaire): Look into proper support for localization bundles. This will naively create
        //               a bundle grouping rather than including the per-locale strings.
        if let ext = currentComponent.pbPathExtension, uti = DirExtensionToUTI[ext] {
          let ref = group.getOrCreateFileReferenceBySourceTree(.Group, path: currentComponent)
          ref.fileTypeOverride = uti
          ref.isInputFile = true

          accessedFileReferences.append(ref)

          // Contents of bundles should never be referenced directly so this path
          // entry is now fully parsed.
          continue pathsLoop
        }

        // Create a subgroup for this simple path component.
        group = group.getOrCreateChildGroupByName(currentComponent, path: currentComponent)
        accessedGroups.append(group)
      }

      let ref = group.getOrCreateFileReferenceBySourceTree(.Group, path: components.last!)
      ref.isInputFile = true
      accessedFileReferences.append(ref)
    }

    return (accessedGroups, accessedFileReferences)
  }

  func serializeInto(serializer: PBXProjFieldSerializer) throws {
    var attributes: [String: AnyObject] = ["LastUpgradeCheck": lastUpgradeCheck]
    if lastSwiftUpdateCheck != nil {
      attributes["LastSwiftUpdateCheck"] = lastSwiftUpdateCheck!
    }

    // Link test targets to their host applications.
    var testLinkages = [String: AnyObject]()
    for (testTarget, hostTarget) in testTargetLinkages {
      let testTargetID = try serializer.serializeObject(testTarget)
      let hostTargetID = try serializer.serializeObject(hostTarget)
      testLinkages[testTargetID] = ["TestTargetID": hostTargetID]
    }
    if !testLinkages.isEmpty {
      attributes["TargetAttributes"] = testLinkages
    }

    try serializer.addField("attributes", attributes)
    try serializer.addField("buildConfigurationList", buildConfigurationList)
    try serializer.addField("compatibilityVersion", compatibilityVersion)
    try serializer.addField("mainGroup", mainGroup);
    try serializer.addField("targets", targetByName.values.sort({$0.name < $1.name}));
  }
}
