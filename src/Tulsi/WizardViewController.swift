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

import Cocoa

class WizardViewController: NSViewController, NSPageControllerDelegate {
  // The storyboard identifiers for the wizard subpage view controllers.
  static let wizardPageIdentifiers = [
      "ProjectEditor",
      "BUILDTargetSelect",
      "SourceTargetSelect",
      "Options",
      "ProjectGenerationProgress"
  ]
  static let generateProgressPageIndex = wizardPageIdentifiers.count - 1
  var pageViewController: NSPageController! = nil

  @IBOutlet weak var previousButton: NSButton!
  @IBOutlet weak var nextButton: NSButton!

  override var representedObject: AnyObject? {
    didSet {
      // Update the current wizard page, if any.
      pageViewController?.selectedViewController?.representedObject = representedObject
    }
  }

  override func prepareForSegue(segue: NSStoryboardSegue, sender: AnyObject?) {
    if segue.identifier == "Embed Wizard PageController" {
      pageViewController = (segue.destinationController as! NSPageController)
      pageViewController.arrangedObjects = WizardViewController.wizardPageIdentifiers
      pageViewController.delegate = self
    }
    super.prepareForSegue(segue, sender: sender)
  }

  func setNextButtonEnabled(enabled: Bool) {
    nextButton.enabled = enabled
  }

  func updateNextButton() {
    if pageViewController.selectedIndex == 0 {
      let document = representedObject as! TulsiDocument
      nextButton.enabled = document.selectedRuleEntryCount > 0
    }
  }

  @IBAction func next(sender: NSButton? = nil) {
    if let deactivatingSubview = pageViewController.selectedViewController as? WizardSubviewProtocol
        where deactivatingSubview.shouldWizardSubviewDeactivateMovingForward?() == false {
      return
    }

    var selectedIndex = pageViewController.selectedIndex
    if selectedIndex < WizardViewController.wizardPageIdentifiers.count - 1 {
      pageViewController!.navigateForward(sender)
      previousButton.hidden = false
      selectedIndex += 1

      if selectedIndex == WizardViewController.generateProgressPageIndex - 1 {
        nextButton.title = NSLocalizedString("Wizard_Generate",
                                             comment: "Label for action button to be used to go to the final page in the project wizard.")
      } else if selectedIndex == WizardViewController.generateProgressPageIndex {
        nextButton.enabled = false
      }
    }
  }

  @IBAction func previous(sender: NSButton? = nil) {
    if let deactivatingSubview = pageViewController.selectedViewController as? WizardSubviewProtocol
        where deactivatingSubview.shouldWizardSubviewDeactivateMovingBackward?() == false {
      return
    }

    var selectedIndex = pageViewController!.selectedIndex
    if selectedIndex > 0 {
      previousButton.hidden = selectedIndex <= 1
      pageViewController!.navigateBack(sender)
      selectedIndex -= 1
      nextButton.enabled = true

      if selectedIndex < WizardViewController.generateProgressPageIndex - 1 {
        nextButton.title = NSLocalizedString("Wizard_Next",
                                             comment: "Label for action button to be used to go to the next page in the project wizard.")
      }
    }
  }

  // MARK: - NSPageControllerDelegate

  func pageController(pageController: NSPageController, identifierForObject object: AnyObject) -> String {
    return object as! String
  }

  func pageController(pageController: NSPageController, viewControllerForIdentifier identifier: String) -> NSViewController {
    let vc = storyboard!.instantiateControllerWithIdentifier(identifier) as! NSViewController

    // NSPageController doesn't appear to support Autolayout properly, so fall back to
    // autoresizingMask.
    vc.view.autoresizingMask = [.ViewWidthSizable, .ViewHeightSizable]
    return vc
  }

  func pageController(pageController: NSPageController,
                      prepareViewController viewController: NSViewController,
                      withObject object: AnyObject) {
    // By default, the viewController will have its representedObject set to the currently selected
    // member of the pageController's arrangedObjects. Wizard pages need to represent the underlying
    // TulsiDocument, so it's set here.
    viewController.representedObject = representedObject

    let newPageIndex = WizardViewController.wizardPageIdentifiers.indexOf(object as! String)
    let subview = viewController as? WizardSubviewProtocol
    subview?.presentingWizardViewController = self
    if pageController.selectedIndex < newPageIndex {
      subview?.wizardSubviewWillActivateMovingForward?()
    } else if pageController.selectedIndex > newPageIndex {
      subview?.wizardSubviewWillActivateMovingBackward?()
    }
  }

  func pageControllerDidEndLiveTransition(pageController: NSPageController) {
    if let subview = pageController.selectedViewController as? WizardSubviewProtocol {
      subview.wizardSubviewDidDeactivate?()
    }
    pageController.completeTransition()
  }
}

