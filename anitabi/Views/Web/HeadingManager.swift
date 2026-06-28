//
//  HeadingManager.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/06/28.
//

import Foundation
import CoreLocation
import WebKit
import UIKit
import QuartzCore

/// 端末のコンパス（磁気センサー）から方位角を取得し、WebView 内の Mapbox 地図へ橋渡しするマネージャー。
///
/// - Web → Native: `headingHandler` メッセージ（`{action:"start"|"stop"}`）で方向追従の開始/停止を受け取る
/// - Native → Web: `window.__anitabiOnHeading(deg)` を呼び、地図の bearing と方向扇形（コーン）を更新させる
///
/// 方位は WKWebView の DeviceOrientationEvent では不安定なため、ネイティブの CoreLocation から取得する。
/// 位置情報の利用許可（NSLocationWhenInUseUsageDescription）は既存の Web 定位機能と共有する。
/// ※ コンパスは実機の磁気センサーが必須。シミュレータでは方位イベントが届かないため、実機でのみ本来の挙動になる。
final class HeadingManager: NSObject, CLLocationManagerDelegate, WKScriptMessageHandler {
    // userContentController に強参照されるため、循環参照を避けて webView は weak で持つ。
    weak var webView: WKWebView?

    private let locationManager = CLLocationManager()
    // ユーザーが方向追従を望んでいるか（バックグラウンド復帰時に再開すべきかの判定に使う）。
    private var isFollowing = false
    // 過剰な evaluateJavaScript 呼び出しを抑えるためのスロットリング用タイムスタンプ。
    private var lastPush: CFTimeInterval = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.headingFilter = 1                                  // 1°変化ごとに更新
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters // trueHeading の偏角補正用。粗くてよい
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Web → Native（メッセージ受信）
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "headingHandler" else { return }
        let action = (message.body as? [String: Any])?["action"] as? String ?? (message.body as? String)
        switch action {
        case "start": start()
        case "stop": stop()
        default: break
        }
    }

    // MARK: - 制御
    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        isFollowing = true
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        // trueHeading（真北基準）を有効にするには位置情報の更新も必要。
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    func stop() {
        isFollowing = false
        locationManager.stopUpdatingHeading()
        locationManager.stopUpdatingLocation()
    }

    // MARK: - バックグラウンド時は省電力のため一時停止し、復帰時に再開
    @objc private func appDidEnterBackground() {
        guard isFollowing else { return }
        locationManager.stopUpdatingHeading()
        locationManager.stopUpdatingLocation()
    }

    @objc private func appWillEnterForeground() {
        guard isFollowing else { return }
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    // MARK: - CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard isFollowing, newHeading.headingAccuracy >= 0 else { return }
        // trueHeading は位置情報が無い間は -1。その場合は magneticHeading にフォールバックする。
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // 〜20Hz にスロットリング（JS 側でも requestAnimationFrame で平滑化する）。
        let now = CACurrentMediaTime()
        guard now - lastPush >= 0.04 else { return }
        lastPush = now
        pushHeading(heading)
    }

    // 磁気センサーの校正が必要なときはシステムの校正 UI を許可する。
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard isFollowing, status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    // MARK: - Native → Web（方位を送信）
    private func pushHeading(_ deg: CLLocationDirection) {
        let js = "window.__anitabiOnHeading && window.__anitabiOnHeading(\(deg));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
