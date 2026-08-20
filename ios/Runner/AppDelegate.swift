import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let shareChannelName = "ensemble_sync/share"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerShareChannel(with: engineBridge.pluginRegistry)
  }

  private func registerShareChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "BandlySharePlugin") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: shareChannelName,
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "shareToKakao" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard
        let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String,
        !text.isEmpty
      else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENT",
            message: "공유할 방 코드 메시지가 없습니다.",
            details: nil
          )
        )
        return
      }

      DispatchQueue.main.async {
        self?.presentShareSheet(text: text, result: result)
      }
    }
  }

  private func presentShareSheet(text: String, result: @escaping FlutterResult) {
    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "NO_VIEW_CONTROLLER",
          message: "공유 화면을 표시할 수 없습니다.",
          details: nil
        )
      )
      return
    }

    let activityController = UIActivityViewController(
      activityItems: [text],
      applicationActivities: nil
    )

    if let popover = activityController.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }

    presenter.present(activityController, animated: true)
    result(true)
  }

  private func topViewController() -> UIViewController? {
    let rootViewController = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController ?? window?.rootViewController

    return topViewController(from: rootViewController)
  }

  private func topViewController(from rootViewController: UIViewController?) -> UIViewController? {
    if let navigationController = rootViewController as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    }

    if let tabBarController = rootViewController as? UITabBarController {
      return topViewController(from: tabBarController.selectedViewController)
    }

    if let presentedViewController = rootViewController?.presentedViewController {
      return topViewController(from: presentedViewController)
    }

    return rootViewController
  }
}
