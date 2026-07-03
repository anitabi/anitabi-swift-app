//
//  PersistentWebView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import WebKit

// 永続的なWKWebViewを使用するSwiftUIビュー
struct PersistentWebView: UIViewRepresentable {
    @ObservedObject private var webViewStore: WebViewStore
    @ObservedObject var imageViewModel: ImageViewModel
    @ObservedObject var safariViewModel: SafariViewModel
    @ObservedObject var sceneComparisonViewModel: SceneComparisonViewModel
    
    init(imageViewModel: ImageViewModel, safariViewModel: SafariViewModel, sceneComparisonViewModel: SceneComparisonViewModel) {
        self.webViewStore = WebViewStore.shared
        self.imageViewModel = imageViewModel
        self.safariViewModel = safariViewModel
        self.sceneComparisonViewModel = sceneComparisonViewModel
        
        // 画像処理ハンドラーとURLハンドラーを設定（初期化時に一度だけ）
        self.webViewStore.configureHandlers(imageViewModel: imageViewModel, safariViewModel: safariViewModel, sceneComparisonViewModel: sceneComparisonViewModel)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        // ナビゲーションデリゲートを設定
        webViewStore.webView.navigationDelegate = context.coordinator
        return webViewStore.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // UIViewRepresentableの更新時には特に何もしない
        // WebViewは永続的なインスタンスなので、毎回再ロードする必要はない
    }

    func makeCoordinator() -> WebViewNavigationDelegate {
        return WebViewNavigationDelegate(safariViewModel: safariViewModel)
    }
}

// メイン WebView のナビゲーション制御。
// App-Bound Domains 有効時、外部ドメインへのメインフレーム遷移は WebKit にブロックされ
// 何も起きないため、ここで先に検知して SafariView（シート）へ振り分ける。
// （従来の「リンク長押し→開くで地図ページが外部サイトに置き換わり戻れなくなる」問題もこれで解消）
class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    private let safariViewModel: SafariViewModel

    init(safariViewModel: SafariViewModel) {
        self.safariViewModel = safariViewModel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // targetFrame が nil（新規ウィンドウ扱い）の場合もメインフレーム相当として扱う
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = url.host?.lowercased(),
           host != "anitabi.cn", !host.hasSuffix(".anitabi.cn") {
            safariViewModel.openInSafari(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

// ステータスバーとセーフエリアを無視するためのモディファイア
extension View {
    func hideStatusBar() -> some View {
        self
            .statusBar(hidden: true)
            .edgesIgnoringSafeArea(.all)
    }
} 
