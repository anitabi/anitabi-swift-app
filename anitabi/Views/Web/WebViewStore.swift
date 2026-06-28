//
//  WebViewStore.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import WebKit
import Combine
import UIKit

// WKWebViewのインスタンスを永続化するためのクラス
class WebViewStore: ObservableObject {
    // WKWebViewのシングルトンインスタンス
    @Published var webView: WKWebView
    private var cancellables = Set<AnyCancellable>()
    // ハンドラー / ユーザースクリプトを一度だけ設定するためのフラグ
    private var handlersConfigured = false
    
    // シングルトンパターンの実装
    static let shared = WebViewStore()
    
    init() {
        // WKWebViewConfigurationを作成
        let configuration = WKWebViewConfiguration()
        
        // カスタムURLスキームハンドラーを登録
        let schemeHandler = CacheURLSchemeHandler()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "cached")
        
        // ウェブコンテンツのスケーリングを制御するスクリプト
        let disableZoomScript = WKUserScript(
            source: "var meta = document.createElement('meta'); meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover'; document.getElementsByTagName('head')[0].appendChild(meta);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        
        // スクリプトをコンフィギュレーションに追加
        configuration.userContentController.addUserScript(disableZoomScript)
        
        // WebViewの作成
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        // 设置自定义UA
        let version = Bundle.main.versionString ?? "unknown"
        webView.customUserAgent = "Ukenn2112/anitabiApp/\(version) (iOS) (https://github.com/Ukenn2112/anitabiApp)"
        
        // CSS注入
        // 機種リストのハードコード（新機種が出るたびに追記が必要）をやめ、
        // CSS の env(safe-area-inset-*) で端末の Safe Area に自動追従させる。
        // ※ env() を有効にするため viewport に viewport-fit=cover を付与済み（disableZoomScript）。
        //   目安: Dynamic Island/ノッチ機は inset-top≈59 → margin≈70/80、
        //         非ノッチ機（SE/iPad 等）は inset-top≈0 → margin≈11/21 と自動で縮む。
        let cssString =
        """
            a[href*="sponsor.png"] {
              display: none !important;
            }
            @media (max-width: 800px) {
                .map-box {
                    --mobile-map-side-height: 45vh;
                }
                .side-search-form, .func-change-logs-fixed, .window-bangumis-box {
                    margin-top: calc(env(safe-area-inset-top) + 11px) !important;
                    background-image: none !important;
                }
                /* 検索結果リストの容器。検索フォーム（margin-top: env+11, 高さ約58px）を
                   下へずらした分、結果リストの上パディングも合わせて確保し、
                   先頭項目がフォームに隠れる不具合を防ぐ。 */
                .side-search-box .features-box {
                    padding-top: calc(env(safe-area-inset-top) + 75px) !important;
                }
                .window-points-box {
                    margin-bottom: calc(env(safe-area-inset-bottom) + 16px) !important;
                }
                .func-change-logs-fixed {
                    margin-top: calc(env(safe-area-inset-top) + 21px) !important;
                }
            }
        """
        // JavaScriptでCSSを注入するための関数
        let jsString = """
        function injectCSS() {
            const style = document.createElement('style');
            style.textContent = `\(cssString)`;
            document.head.appendChild(style);
        }
        
        // DOMが読み込まれたら実行
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectCSS);
        } else {
            injectCSS();
        }
        """
        // ユーザースクリプトを作成
        let userScript = WKUserScript(
            source: jsString,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        // スクリプトをウェブビューに追加
        webView.configuration.userContentController.addUserScript(userScript)
        
        // 初期ロード
        if let url = URL(string: "https://anitabi.cn/map") {
            webView.load(URLRequest(url: url))
        }
    }
    
    // インスタンスに画像ハンドラーとURLハンドラーを設定するメソッド
    func configureHandlers(imageViewModel: ImageViewModel, safariViewModel: SafariViewModel, sceneComparisonViewModel: SceneComparisonViewModel) {
        // PersistentWebView は SwiftUI の struct のため、ContentView の body 再評価のたびに init → 本メソッドが呼ばれる。
        // ViewModel は ContentView の @StateObject で生成され不変なので、設定は一度きりで十分。
        // 一度きりにしないと addUserScript が累積し、window.open の多重フック・setInterval タイマーの多重登録（メモリ/CPU リーク）を招く。
        guard !handlersConfigured else { return }
        handlersConfigured = true

        // 以前のハンドラーを削除（再設定の場合）
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "imageHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "urlHandler")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "compareImageHandler")

        // 新しいハンドラーを追加
        let messageHandler = WebViewMessageHandler(imageViewModel: imageViewModel, safariViewModel: safariViewModel, sceneComparisonViewModel: sceneComparisonViewModel)
        webView.configuration.userContentController.add(messageHandler, name: "imageHandler")
        webView.configuration.userContentController.add(messageHandler, name: "urlHandler")
        webView.configuration.userContentController.add(messageHandler, name: "compareImageHandler")

        // window.openをハイジャックするスクリプト（相対パスを絶対パスに変換）
        let windowOpenInterceptScript = """
        // window.openをハイジャック
        const originalWindowOpen = window.open;
        window.open = function(url, target, features) {
            // URLが指定されている場合
            if (url) {
                try {
                    // 相対パスを絶対パスに変換
                    let fullUrl;
                    
                    // URLが既に完全な形式かチェック
                    if (url.startsWith('http://') || url.startsWith('https://')) {
                        fullUrl = url;
                    } else {
                        // 相対パスの場合は現在のオリジンを先頭に追加
                        fullUrl = new URL(url, window.location.origin).href;
                    }

                    // 「做对比图」リンクの検出
                    if (fullUrl.includes('https://lab.magiconch.com')) {
                        window.webkit.messageHandlers.compareImageHandler.postMessage(fullUrl);
                        return null;
                    }

                    // 「原图」リンクの検出と処理
                    if (fullUrl.includes('https://image.anitabi.cn')) {
                        window.webkit.messageHandlers.imageHandler.postMessage(fullUrl);
                        return null;
                    }
                    
                    // 完全なURLをハンドラーに送信
                    window.webkit.messageHandlers.urlHandler.postMessage(fullUrl);
                    return null; // window.openの戻り値を期待するコードに対応
                } catch (e) {
                    console.error('URL conversion error:', e);
                    // エラーが発生した場合は元のURLを送信
                    window.webkit.messageHandlers.urlHandler.postMessage(url);
                    return null;
                }
            }
            
            // URLが指定されていない場合は元の関数を呼び出す
            return originalWindowOpen.apply(this, arguments);
        };
        """
        
        // ウィンドウオープンスクリプトの追加
        let windowOpenUserScript = WKUserScript(
            source: windowOpenInterceptScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(windowOpenUserScript)
        
        // フッター注入スクリプト
        let footerInjectionScript = """
        function injectFooterContent() {
            const funcChangeLogsFixed = document.querySelector('div.func-change-logs-fixed');
            if (funcChangeLogsFixed) {
                const footerDiv = funcChangeLogsFixed.querySelector('div.foot');
                if (footerDiv) {
                    // 既に追加されているか確認
                    const existingNotice = footerDiv.querySelector('div[data-injected-notice]');
                    if (!existingNotice) {
                        const noticeElement = document.createElement('div');
                        noticeElement.setAttribute('data-injected-notice', 'true');
                        noticeElement.innerHTML = '<a><i>下列部分按钮可能需要长按才能被跳转</i></a></br>';
                        footerDiv.insertBefore(noticeElement, footerDiv.firstChild);
                    }
                }
            }
        }
        
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectFooterContent);
        } else {
            injectFooterContent();
        }

        // ポーリング（setInterval）の代わりに MutationObserver で DOM 変化を監視する。
        // DOM がアイドルの間は一切処理せず、変化時のみ requestAnimationFrame でまとめて 1 回実行する。
        let footerScheduled = false;
        const footerObserver = new MutationObserver(function() {
            if (footerScheduled) return;
            footerScheduled = true;
            requestAnimationFrame(function() {
                footerScheduled = false;
                injectFooterContent();
            });
        });
        footerObserver.observe(document.documentElement, { childList: true, subtree: true });
        """
        
        let footerInjectionUserScript = WKUserScript(
            source: footerInjectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(footerInjectionUserScript)
    }
} 
