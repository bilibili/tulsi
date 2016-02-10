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


/// Provides functionality to generate an Xcode project from a TulsiGeneratorConfig.
class XcodeProjectGenerator {
  enum Error: ErrorType {
    /// General Xcode project creation failure with associated debug info.
    case SerializationFailed(String)

    /// The given labels failed to resolve to valid targets.
    case LabelResolutionFailed(Set<String>)

    /// The given labels were specified as source targets but could not be resolved.
    case SourceTargetResolutionFailed(Set<String>)
  }

  /// Path relative to PROJECT_FILE_PATH in which Tulsi generated files (scripts, artifacts, etc...)
  /// should be placed.
  private static let TulsiArtifactDirectory = ".tulsi"
  private static let ScriptDirectorySubpath = "\(TulsiArtifactDirectory)/Scripts"
  private static let BuildScript = "bazel_build.py"
  private static let CleanScript = "bazel_clean.sh"

  private let workspaceRootURL: NSURL
  private let config: TulsiGeneratorConfig
  private let localizedMessageLogger: LocalizedMessageLogger
  private let fileManager: NSFileManager
  private let workspaceInfoExtractor: WorkspaceInfoExtractorProtocol
  private let labelResolver: LabelResolverProtocol
  private let buildScriptURL: NSURL
  private let cleanScriptURL: NSURL

  /// Dictionary of Bazel targets for which indexers should be generated and the sources to add to
  /// them.
  private var sourcePaths = [RuleEntry: [String]]()

  // Exposed for testing. Simply writes the given NSData to the given NSURL.
  var writeDataHandler: (NSURL, NSData) throws -> Void = { (outputFileURL: NSURL, data: NSData) in
    try data.writeToURL(outputFileURL, options: NSDataWritingOptions.DataWritingAtomic)
  }

  init(workspaceRootURL: NSURL,
       config: TulsiGeneratorConfig,
       localizedMessageLogger: LocalizedMessageLogger,
       fileManager: NSFileManager,
       workspaceInfoExtractor: WorkspaceInfoExtractorProtocol,
       labelResolver: LabelResolverProtocol,
       buildScriptURL: NSURL,
       cleanScriptURL: NSURL) {
    self.workspaceRootURL = workspaceRootURL
    self.config = config
    self.localizedMessageLogger = localizedMessageLogger
    self.fileManager = fileManager
    self.workspaceInfoExtractor = workspaceInfoExtractor
    self.labelResolver = labelResolver
    self.buildScriptURL = buildScriptURL
    self.cleanScriptURL = cleanScriptURL
  }

  /// Generates an Xcode project bundle in the given folder.
  /// NOTE: This may be a long running operation.
  func generateXcodeProjectInFolder(outputFolderURL: NSURL) throws -> NSURL {
    try resolveConfigReferences()
    resolveSourceFilePaths()

    var missingSourceTargetPaths = Set<String>()
    for entry in config.sourceTargets! {
      guard let _ = sourcePaths[entry] else {
        missingSourceTargetPaths.insert(entry.label.value)
        continue
      }
    }
    if !missingSourceTargetPaths.isEmpty {
      throw Error.SourceTargetResolutionFailed(missingSourceTargetPaths)
    }

    let mainGroup = BazelTargetGenerator.mainGroupForOutputFolder(outputFolderURL,
                                                                  workspaceRootURL: workspaceRootURL)
    let xcodeProject = try buildXcodeProjectWithMainGroup(mainGroup)

    let serializer = PBXProjSerializer(rootObject: xcodeProject, gidGenerator: ConcreteGIDGenerator())
    guard let serializedXcodeProject = serializer.toOpenStep() else {
      throw Error.SerializationFailed("OpenStep serialization failed")
    }

    let projectBundleName = config.projectName + ".xcodeproj"
    let projectURL = outputFolderURL.URLByAppendingPathComponent(projectBundleName)
    if !createDirectory(projectURL) {
      throw Error.SerializationFailed("Project directory creation failed")
    }
    let pbxproj = projectURL.URLByAppendingPathComponent("project.pbxproj")
    try writeDataHandler(pbxproj, serializedXcodeProject)

    try installWorkspaceSettings(projectURL)
    try installXcodeSchemesForProject(xcodeProject,
                                      projectURL: projectURL,
                                      projectBundleName: projectBundleName)
    installTulsiScripts(projectURL)

    return projectURL
  }

  // MARK: - Private methods

  /// Invokes Bazel to load any missing information in the config file.
  private func resolveConfigReferences() throws {
    var labels = [String]()
    if config.buildTargets == nil {
      labels += config.buildTargetLabels
    }
    if config.sourceTargets == nil {
      labels += config.sourceTargetLabels
    }

    if labels.isEmpty {
      return
    }

    let resolvedLabels = workspaceInfoExtractor.ruleEntriesForLabels(labels)
    var unresolvedLabels = Set<String>()

    // Converts the given array of labels to an array of RuleEntry instances, adding any labels that
    // failed to resolve to the unresolvedLabels set.
    func ruleEntriesForLabels(labels: [String]) -> [RuleEntry] {
      var ruleEntries = [RuleEntry]()
      for label in labels {
        guard let entry = resolvedLabels[label] else {
          unresolvedLabels.insert(label)
          continue
        }
        ruleEntries.append(entry)
      }
      return ruleEntries
    }

    if config.buildTargets == nil {
      config.buildTargets = ruleEntriesForLabels(config.buildTargetLabels)
    }
    if config.sourceTargets == nil {
      config.sourceTargets = ruleEntriesForLabels(config.sourceTargetLabels)
    }

    if !unresolvedLabels.isEmpty {
      throw Error.LabelResolutionFailed(unresolvedLabels)
    }
  }

  private func resolveSourceFilePaths() {
    sourcePaths = workspaceInfoExtractor.extractSourceFilePathsForSourceRules(config.sourceTargets!)
  }

  private func buildXcodeProjectWithMainGroup(mainGroup: PBXGroup) throws -> PBXProject {
    let xcodeProject = PBXProject(name: config.projectName, mainGroup: mainGroup)
    if let enabled = config.options[.SuppressSwiftUpdateCheck]?.commonValueAsBool where enabled {
      xcodeProject.lastSwiftUpdateCheck = "0710"
    }

    let buildScriptPath = "${PROJECT_FILE_PATH}/\(XcodeProjectGenerator.ScriptDirectorySubpath)/\(XcodeProjectGenerator.BuildScript)"
    let cleanScriptPath = "${PROJECT_FILE_PATH}/\(XcodeProjectGenerator.ScriptDirectorySubpath)/\(XcodeProjectGenerator.CleanScript)"

    let generator = BazelTargetGenerator(bazelURL: config.bazelURL,
                                         bazelRCURL: config.bazelRCURL,
                                         project: xcodeProject,
                                         buildScriptPath: buildScriptPath,
                                         labelResolver: labelResolver,
                                         options: config.options,
                                         localizedMessageLogger: localizedMessageLogger)

    if let additionalFilePaths = config.additionalFilePaths {
      generator.generateFileReferencesForFilePaths(additionalFilePaths)
    }

    for (ruleEntry, paths) in sourcePaths {
      generator.generateIndexerTargetForRuleEntry(ruleEntry, sourcePaths: paths)
    }

    let workingDirectory = BazelTargetGenerator.workingDirectoryForPBXGroup(mainGroup)
    generator.generateBazelCleanTarget(cleanScriptPath, workingDirectory: workingDirectory)
    generator.generateTopLevelBuildConfigurations()
    try generator.generateBuildTargetsForRuleEntries(config.buildTargets!,
                                                     sourcePaths: sourcePaths)

    return xcodeProject
  }

  private func installWorkspaceSettings(projectURL: NSURL) throws {
    // Write workspace options if they don't already exist.
    let workspaceSharedDataURL = projectURL.URLByAppendingPathComponent("project.xcworkspace/xcshareddata")
    let workspaceSettingsURL = workspaceSharedDataURL.URLByAppendingPathComponent("WorkspaceSettings.xcsettings")
    if !fileManager.fileExistsAtPath(workspaceSettingsURL.path!) &&
        createDirectory(workspaceSharedDataURL) {
      let workspaceSettings = ["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded": false]
      let data = try NSPropertyListSerialization.dataWithPropertyList(workspaceSettings,
                                                                      format: .XMLFormat_v1_0,
                                                                      options: 0)
      try writeDataHandler(workspaceSettingsURL, data)
    }
  }

  // Writes Xcode schemes for non-indexer targets if they don't already exist.
  private func installXcodeSchemesForProject(xcodeProject: PBXProject,
                                             projectURL: NSURL,
                                             projectBundleName: String) throws {
    let xcschemesURL = projectURL.URLByAppendingPathComponent("xcshareddata/xcschemes")
    if createDirectory(xcschemesURL) {
      for entry in config.buildTargets! {
        let targetName = entry.label.targetName!
        let filename = targetName + ".xcscheme"
        let url = xcschemesURL.URLByAppendingPathComponent(filename)
        if fileManager.fileExistsAtPath(url.path!) {
          continue
        }

        // If this target happens to be a test host, update the test action to allow tests to be run
        // without Xcode attempting to compile code.
        let target = xcodeProject.targetByName(targetName)!
        let testActionBuildConfig: String
        if !xcodeProject.linkedTestTargetsForHost(target).isEmpty {
          testActionBuildConfig = BazelTargetGenerator.runTestTargetBuildConfigName
        } else {
          testActionBuildConfig = "Debug"
        }
        let scheme = XcodeScheme(target: target,
                                 project: xcodeProject,
                                 projectBundleName: projectBundleName,
                                 testActionBuildConfig: testActionBuildConfig)
        let xmlDocument = scheme.toXML()

        let data = xmlDocument.XMLDataWithOptions(NSXMLNodePrettyPrint)
        try writeDataHandler(url, data)
      }
    }
  }

  private func installTulsiScripts(projectURL: NSURL) {
    // Install Tulsi scripts.
    let scriptDirectoryURL = projectURL.URLByAppendingPathComponent(XcodeProjectGenerator.ScriptDirectorySubpath,
                                                                    isDirectory: true)
    if createDirectory(scriptDirectoryURL) {
      localizedMessageLogger.infoMessage("Installing scripts")
      installFiles([(buildScriptURL, XcodeProjectGenerator.BuildScript),
                    (cleanScriptURL, XcodeProjectGenerator.CleanScript),
                   ],
                   toDirectory: scriptDirectoryURL)
    }
  }

  private func createDirectory(resourceDirectoryURL: NSURL) -> Bool {
    do {
      try fileManager.createDirectoryAtURL(resourceDirectoryURL,
                                           withIntermediateDirectories: true,
                                           attributes: nil)
    } catch let e as NSError {
      localizedMessageLogger.error("DirectoryCreationFailed",
                                   comment: "Failed to create an important directory. The resulting project will most likely be broken. A bug should be reported.",
                                   values: resourceDirectoryURL, e.localizedDescription)
      return false
    }
    return true
  }

  private func installFiles(files: [(sourceURL: NSURL, filename: String)],
                            toDirectory directory: NSURL) {
    for (sourceURL, filename) in files {
      if let targetURL = NSURL(string: filename, relativeToURL: directory) {
        do {
          if fileManager.fileExistsAtPath(targetURL.path!) {
            try fileManager.removeItemAtURL(targetURL)
          }
          try fileManager.copyItemAtURL(sourceURL, toURL: targetURL)
        } catch let e as NSError {
          localizedMessageLogger.error("CopyingResourceFailed",
                                       comment: "Failed to copy an important file resource, the resulting project will most likely be broken. A bug should be reported.",
                                       values: sourceURL, targetURL.absoluteString, e.localizedDescription)
        }
      } else {
        localizedMessageLogger.error("CopyingResourceFailed",
                                     comment: "Failed to copy an important file resource, the resulting project will most likely be broken. A bug should be reported.",
                                     values: sourceURL, filename, "Target URL is invalid")
      }
    }
  }
}
