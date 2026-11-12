import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var cleanupTask: UIBackgroundTaskIdentifier = .invalid

  override func sceneDidEnterBackground(_ scene: UIScene) {
    // Give Dart's pause handler a short opportunity to abort multipart uploads
    // and discard partial downloads before iOS suspends the foreground engine.
    finishCleanup()
    cleanupTask = UIApplication.shared.beginBackgroundTask(withName: "Storage cleanup") { [weak self] in
      self?.finishCleanup()
    }
    super.sceneDidEnterBackground(scene)
    let task = cleanupTask
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      guard self?.cleanupTask == task else { return }
      self?.finishCleanup()
    }
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    finishCleanup()
    super.sceneWillEnterForeground(scene)
  }

  private func finishCleanup() {
    guard cleanupTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(cleanupTask)
    cleanupTask = .invalid
  }
}
