//
//  ContentView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import SafariServices
import UIKit

// MARK: - Dynamic Island 適配

/// Safe Area の上端インセットから Dynamic Island のフレームを推定する。
/// Island 搭載全機種で「島の中心 y ≈ topInset − 29pt、サイズ ≈ 126×37.3pt」が成立する
/// （14 Pro: inset 59 / 島 y 11.3、16 Pro〜17 世代: inset 62 / 島 y 14 — いずれも実測と一致）。
/// ノッチ機は inset ≤ 50、横向きは inset ≈ 0 になるため nil を返し、自動的に非表示になる。
func dynamicIslandFrame(topInset: CGFloat, containerWidth: CGFloat) -> CGRect? {
    guard topInset >= 51 else { return nil }
    let size = CGSize(width: 126.0, height: 37.33)
    return CGRect(
        x: (containerWidth - size.width) / 2,
        y: topInset - 29.0 - size.height / 2,
        width: size.width,
        height: size.height
    )
}

// MARK: - 应用标识胶囊视图

/// Dynamic Island そっくりの黒いカプセルとして、島のフレームぴったりに描画する。
/// 実機では OS が島の領域を常時黒くマスクするため肉眼では見えず、
/// スクリーンショットにだけ「島にアプリ名が表示されている」ように写る（宣伝用透かし）。
/// 影は付けない — 影はカプセルの外側（＝島のマスクの外側）に描画され、実機でも見えてしまうため。
struct AppIdentityPillView: View {
    var body: some View {
        HStack(spacing: 8) {
            if let uiImage = UIImage(named: "favicon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
            // localizedInfoDictionary 経由で表示名を取得する（displayName 拡張で対応済み）。
            // infoDictionary 直接参照だと英語/日本語表示でも中国語名が出てしまうため使わない。
            Text(Bundle.main.displayName ?? "Anitabi")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(Capsule())
    }
}

struct ContentView: View {
    @StateObject private var imageViewModel = ImageViewModel()
    @StateObject private var safariViewModel = SafariViewModel()
    @StateObject private var sceneComparisonViewModel = SceneComparisonViewModel()
    
    // 用于控制是否显示欢迎界面
    @State private var showingOnboarding = false

    var body: some View {
        ZStack {
            // 主内容
            NavigationStack {
                PersistentWebView(imageViewModel: imageViewModel, safariViewModel: safariViewModel, sceneComparisonViewModel: sceneComparisonViewModel)
                    .edgesIgnoringSafeArea(.all)
                    // 画像ビューワー
                    .sheet(isPresented: $imageViewModel.isImagePresented) {
                        ImageViewer(isPresented: $imageViewModel.isImagePresented, imageURL: imageViewModel.imageURL)
                    }
                    // SafariView
                    .sheet(isPresented: $safariViewModel.isSafariPresented) {
                        if let url = safariViewModel.safariURL {
                            SafariView(url: url, onClose: {
                                safariViewModel.closeSafari()
                            })
                                .edgesIgnoringSafeArea(.all)
                        }
                    }
                    // シーン比較ビューへのナビゲーション
                    .navigationDestination(isPresented: $sceneComparisonViewModel.isSceneComparisonPresented) {
                        if let url = sceneComparisonViewModel.scenePhotoURL,
                           let name = sceneComparisonViewModel.sceneName,
                           let color = sceneComparisonViewModel.sceneColor,
                           let location = sceneComparisonViewModel.sceneLocation {
                            SceneComparisonView(
                                scenePhotoURL: url,
                                sceneName: name,
                                sceneColor: color,
                                sceneLocation: location
                            )
                        }
                    }
                    // ようこそ画面
                    .fullScreenCover(isPresented: $showingOnboarding) {
                        OnboardingView(isPresented: $showingOnboarding)
                            .edgesIgnoringSafeArea(.all)
                    }
                    .onAppear {
                        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
                        if !hasCompletedOnboarding {
                            showingOnboarding = true
                        }
                    }
            }
            // Dynamic Island の直下に隠すスクリーンショット専用ウォーターマーク。
            // GeometryReader で Safe Area を監視するため、回転すると即座に再評価される
            // （横向きは topInset ≈ 0 → 自動非表示）。フレームは島より 2pt 内側に収めて
            // はみ出しを構造的に防ぎ、hitTesting を切って下の地図操作を邪魔しない。
            // 注意: .ignoresSafeArea() を付けると proxy.safeAreaInsets が 0 になり判定できないため、
            // Safe Area 内に置いたまま、画面座標 → ローカル座標（y − topInset）に変換して上へ描き出す。
            GeometryReader { geo in
                let topInset = geo.safeAreaInsets.top
                if let island = dynamicIslandFrame(topInset: topInset, containerWidth: geo.size.width) {
                    AppIdentityPillView()
                        .frame(width: island.width - 4, height: island.height - 4)
                        .position(x: island.midX, y: island.midY - topInset)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

#Preview {
    ContentView()
}
