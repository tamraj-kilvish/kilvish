import Flutter
import UIKit
import SwiftUI
import FirebaseCore
import background_downloader

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      FirebaseApp.configure()
    GeneratedPluginRegistrant.register(with: self)
      // Ensure the root view controller is properly set
          let controller = window?.rootViewController as? FlutterViewController
          if controller != nil {
            print("FlutterViewController is available")
          }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}



