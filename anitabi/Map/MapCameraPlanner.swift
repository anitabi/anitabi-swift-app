//
//  MapCameraPlanner.swift
//  anitabi
//
//  カメラの算数を 1 箇所に集める。ズーム値は Web 版（Mapbox GL）の定義
//  `z = log2(360 × 表示幅pt / (256 × span.longitudeDelta))` に合わせる —— 揭示阶梯も密度テーブルも
//  Web の z 前提なので、この式から外れると標注の出方が丸ごとズレる。
//

import CoreLocation
import MapKit
import UIKit

enum MapCameraPlanner {

    /// 通常の作品選択で画角を保つ最小ズーム。初期値は視口作品 chips の近接レベル（z12）に合わせる。
    /// 作品を開く挙動だけ調整できるよう、chips の表示閾値とは独立して持つ。
    static let preserveWorkViewportMinZoom: Double = 12

    /// 作品フィットの上限。これ以上寄ると「作品の広がり」ではなく 1 点の景色になる。
    static let maxFitZoom: Double = 17
    /// 飛行時間の**上限**（Web 版 flyTo の体感 ≒1.2 秒）。実際の時間は `flightDuration` が
    /// 道のりに合わせて縮める —— 隣の点への 200m にも 1.2 秒掛けると「押したのに動かない」
    /// 間だけが残る（動きの量は入力の量に釣り合わせる）。
    static let flyDuration: TimeInterval = 1.2
    /// 飛行時間の下限。これ未満だと easeInOut の立ち上がりが潰れて 1 コマ切替に見える。
    static let minFlyDuration: TimeInterval = 0.35

    /// 道のり（今の視口 → 目標視口）から飛行時間を決める。道のりは
    /// **パンの「画面何枚ぶん」＋ズームの「倍率何段ぶん」**の和 —— Mapbox の flyTo と同じ考え方で、
    /// 遠い都市への飛行は上限いっぱい（映画的に）、隣の点への跳びは 0.4〜0.6 秒（機敏に）。
    static func flightDuration(
        from current: MKCoordinateRegion,
        to target: MKCoordinateRegion
    ) -> TimeInterval {
        let currentSpan = max(current.span.longitudeDelta, 1e-9)
        let targetSpan = max(target.span.longitudeDelta, 1e-9)
        // ズームの段数差。span は 1 段ごとに半分になるので log2 がそのまま段数。
        let zoomTravel = abs(log2(currentSpan / targetSpan))
        // パンの画面数。広い方の視口で測る —— 飛行は一度引いてから寄るので、
        // 巡航高度での横移動が体感の道のりになる。
        let panTravel = hypot(
            target.center.longitude - current.center.longitude,
            target.center.latitude - current.center.latitude
        ) / max(currentSpan, targetSpan)
        return min(flyDuration, max(minFlyDuration, 0.35 + 0.12 * (panTravel + zoomTravel)))
    }

    // MARK: ズーム ↔ 範囲

    static func zoom(for region: MKCoordinateRegion, width: CGFloat) -> Double {
        guard region.span.longitudeDelta > 0, width > 0 else { return 0 }
        return log2(360 * Double(width) / (256 * region.span.longitudeDelta))
    }

    /// 指定ズームちょうどの表示矩形。`setRegion` は要求範囲が必ず収まるよう span を切り上げるので
    /// 実測ズームが 0.2 ほど浅くなるが、MKMapRect は投影後の単位が画面ピクセルと線形なので、
    /// 画面比に合わせた矩形を渡せば厳密に一致する。`verticalOffset` は目標を上へ逃がす量。
    static func mapRect(
        center: CLLocationCoordinate2D,
        zoom: Double,
        size: CGSize,
        verticalOffset: CGFloat = 0
    ) -> MKMapRect {
        let unitsPerPoint = MKMapSize.world.width / (256 * pow(2, zoom))
        let width = Double(size.width) * unitsPerPoint
        let height = Double(size.height) * unitsPerPoint
        let point = MKMapPoint(center)
        return MKMapRect(
            x: point.x - width / 2,
            y: point.y - height / 2 + Double(verticalOffset) * unitsPerPoint,
            width: width,
            height: height
        )
    }

    // MARK: 一覧から選んだ点へ寄る

    /// Web 版の密度テーブル。`priority` は最近傍までの距離（m）＝周りの混み具合なので、
    /// 「隣の点と区別が付く」ところまで寄る倍率がそのまま決まる。
    static func flyZoom(priority: Int?) -> Double {
        guard let priority else { return 15 }
        return switch priority {
        case let p where p > 64: 15
        case let p where p > 32: 16
        case let p where p > 16: 17
        case let p where p > 8: 18
        case let p where p > 4: 19
        case let p where p > 2: 20
        case let p where p > 1: 21
        default: 22
        }
    }

    // MARK: 作品フィット

    /// 作品の点群が収まる矩形。飛び地の離群点で「太平洋まで」表示になるのを防ぐ（web 版
    /// `fitBoundsByBangumi` の移植）。判定は分位数ではなく**各点の「他の全点までの平均距離」**で、
    /// `(最大 + 平均) / 2 × 0.8` を超える点を捨てる（残りが 3 点未満なら元の点群を使う）。
    static func fitRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count >= 4 else { return enclosingRect(of: coordinates) }

        let locations = coordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let n = locations.count
        var eccentricities = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var total = 0.0
            for j in 0..<n where j != i {
                total += locations[i].distance(from: locations[j])
            }
            eccentricities[i] = total / Double(n - 1)
        }
        let maxEccentricity = eccentricities.max() ?? 0
        let meanEccentricity = eccentricities.reduce(0, +) / Double(n)
        let cutoff = (maxEccentricity + meanEccentricity) / 2 * 0.8

        let kept = coordinates.indices
            .filter { eccentricities[$0] <= cutoff }
            .map { coordinates[$0] }
        return enclosingRect(of: kept.count >= 3 ? kept : coordinates)
    }

    /// 与えられた座標を**そのまま**囲む矩形（離群点の切り捨てをしない）。
    /// 圧暗レイヤーの頂点（`WorkRegionOverlay.hull`）を収めるときはこちら ——
    /// あの多角形は既に全点から組まれているので、ここで間引くと枠が画面外にはみ出す。
    static func enclosingRect(of coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        guard let first = coordinates.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        // 1 点だけの作品は面積 0 になるので最低限の広がりを与える。
        if rect.size.width < 1 || rect.size.height < 1 {
            let padding = MKMapPointsPerMeterAtLatitude(first.latitude) * 400
            rect = rect.insetBy(dx: -padding, dy: -padding)
        }
        return rect
    }

    /// 四辺 7% ＋ 上辺に安全区（Dynamic Island／ステータスバー）＋ 下辺にカードの高さ。
    /// 地図は `.ignoresSafeArea()` で窓いっぱいに広がっているので、安全区はここで明示するしかない。
    static func edgePadding(
        viewSize: CGSize,
        topInset: CGFloat = 0,
        bottomInset: CGFloat
    ) -> UIEdgeInsets {
        let inset = viewSize.width * 0.07
        return UIEdgeInsets(
            top: inset + topInset,
            left: inset,
            bottom: inset + bottomInset,
            right: inset
        )
    }

    /// フィット結果が寄りすぎないよう `maxFitZoom` で頭打ちにする。
    static func clampedToMaxZoom(_ rect: MKMapRect, viewSize: CGSize) -> MKMapRect {
        let region = MKCoordinateRegion(rect)
        let currentZoom = zoom(for: region, width: viewSize.width)
        guard currentZoom > maxFitZoom else { return rect }
        let scale = pow(2, currentZoom - maxFitZoom)
        let width = rect.size.width * scale
        let height = rect.size.height * scale
        return MKMapRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}
