//
//  ContentView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import SafariServices
import UIKit

// MARK: - 设备判断

/// Dynamic Island 搭載機かどうかを Safe Area の上端インセットで判定する。
/// 機種リストをハードコードする方式（新機種が出るたびに追記が必要）と違い、これなら自動で追従できる。
/// 目安: Dynamic Island ≈ 59pt / ノッチ ≤ 50pt / ホームボタン = 20pt。
func isDynamicIslandSupported() -> Bool {
    let topInset = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0
    return topInset >= 51
}

// MARK: - 应用标识胶囊视图
struct AppIdentityPillView: View {
    var body: some View {
        HStack(spacing: 10) {
            if let uiImage = UIImage(named: "favicon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
            // localizedInfoDictionary 経由で表示名を取得する（displayName 拡張で対応済み）。
            // infoDictionary 直接参照だと英語/日本語表示でも中国語名が出てしまうため使わない。
            Text(Bundle.main.displayName ?? "Anitabi")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(Color.white)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}

struct ContentView: View {
    @StateObject private var imageViewModel = ImageViewModel()
    @StateObject private var safariViewModel = SafariViewModel()
    @StateObject private var sceneComparisonViewModel = SceneComparisonViewModel()
    
    // 用于控制是否显示欢迎界面
    @State private var showingOnboarding = false

    // Dynamic Island 機かどうか（onAppear で確定する。body 評価時点では Safe Area 未確立のため）
    @State private var showsIdentityPill = false
    
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
                        // ウィンドウ確立後に Safe Area から判定する
                        showsIdentityPill = isDynamicIslandSupported()
                    }
            }
            // 动态岛支持机型时显示应用标识胶囊
            if showsIdentityPill {
                VStack {
                    AppIdentityPillView()
                        .padding(.top, 15)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
            }
        }
    }
}

#Preview {
    ContentView()
}
