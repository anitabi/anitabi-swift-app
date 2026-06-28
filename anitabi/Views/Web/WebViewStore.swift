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
    // コンパス（端末の方位）→ 地図回転 のブリッジを担うマネージャー
    private let headingManager = HeadingManager()
    
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
            /* 方向追従（コンパス）関連。@media の外＝全端末共通で適用する。
               方向扇形そのものは Mapbox 標準の .mapboxgl-user-location-heading
               （GeolocateControl の showUserHeading）を使うため自作しない。
               ここではコンパスボタンの状態表示だけを行う。 */
            .mapboxgl-ctrl-compass.anitabi-heading-cone-mode {   /* 1段目: 正北固定・扇形回転 */
                background-color: #d6e4ff !important;
            }
            .mapboxgl-ctrl-compass.anitabi-heading-mapup-mode {  /* 2段目: 地図ごと方向朝上に回転 */
                background-color: #aecbff !important;
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

        // コンパス（方位）追従のセットアップ
        setupHeadingBridge()

        // 初期ロード
        if let url = URL(string: "https://anitabi.cn/map") {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - コンパス（方位）追従

    /// 端末の方位（コンパス）で向きを示す「方向追従」機能を WebView に組み込む。
    ///
    /// コンパスボタン（.mapboxgl-ctrl-compass）のクリックを乗っ取り、3 段階で循環させる:
    ///   1 段目（コーン回転）: 地図は正北固定のまま、Mapbox 標準の方向扇形
    ///     （GeolocateControl の showUserHeading が描く .mapboxgl-user-location-heading）を
    ///     端末の方位へ回転させる。＝ Google マップ既定の見え方。
    ///   2 段目（方向朝上）: 地図ごと方位の方向へ回転（heading-up）。扇形は常に画面上を向く。
    ///   3 段目（OFF）: 扇形を消し、地図を正北へ戻す。
    ///
    /// 方位は WKWebView では deviceorientation イベントが不安定なため、ネイティブの
    /// CoreLocation（HeadingManager）から取得し、Mapbox 標準コンポーネントを直接駆動する。
    /// - `headingHandler` メッセージで Web → Native の開始/停止を伝える（HeadingManager が処理）
    /// - `window.__anitabiOnHeading(deg)` を Native が呼び、向きを反映する
    private func setupHeadingBridge() {
        headingManager.webView = webView
        webView.configuration.userContentController.add(headingManager, name: "headingHandler")

        let headingScript = """
        (function() {
            if (window.__anitabiHeadingInit) return;
            window.__anitabiHeadingInit = true;

            // 3 段階モード: 0=OFF, 1=コーン回転(正北固定), 2=方向朝上(地図ごと回転)
            var MODE_OFF = 0, MODE_CONE = 1, MODE_MAPUP = 2;
            var mode = MODE_OFF;
            var targetHeading = 0;     // 原生から渡る最新の方位（0-360, 真北基準・時計回り）
            var smoothed = null;       // 方向朝上モードで平滑化した現在の bearing
            var rafId = null;

            window.__anitabiHeadingMode = 0; // デバッグ/検証用

            // 最短経路で角度差を求める（-180〜180）
            function shortestDelta(to, from) {
                return ((to - from + 540) % 360) - 180;
            }
            function getMap() { return window.map; }

            // Mapbox の GeolocateControl 実例を取得（自前の扇形ではなく標準コンポーネントを駆動）
            function getGeolocate() {
                var m = getMap();
                if (!m || !m._controls) return null;
                for (var i = 0; i < m._controls.length; i++) {
                    var c = m._controls[i];
                    if (c && (c._userLocationDotMarker || c._dotElement)) return c;
                }
                return null;
            }
            function headingEl() { return document.querySelector('.mapboxgl-user-location-heading'); }

            // 標準の方向扇形（showUserHeading）を駆動する。deg=null で非表示。
            function setConeHeading(deg) {
                var ctrl = getGeolocate();
                if (!ctrl) return;
                var el = headingEl();
                if (deg === null) {
                    ctrl._heading = null;
                    if (typeof ctrl._updateMarkerRotation === 'function') ctrl._updateMarkerRotation();
                    if (el) el.style.display = 'none';
                } else {
                    ctrl._heading = deg;
                    if (typeof ctrl._updateMarkerRotation === 'function') {
                        ctrl._updateMarkerRotation();
                    } else if (ctrl._userLocationDotMarker && ctrl._userLocationDotMarker.setRotation) {
                        ctrl._userLocationDotMarker.setRotation(deg);
                    }
                    if (el) el.style.display = 'block';
                }
            }

            // 方向朝上モード: 地図 bearing を方位へ平滑に近づける（requestAnimationFrame ループ）
            function tick() {
                rafId = null;
                if (mode !== MODE_MAPUP) return;
                var m = getMap();
                if (!m) return;
                if (smoothed === null) smoothed = m.getBearing();
                smoothed += shortestDelta(targetHeading, smoothed) * 0.25;
                smoothed = ((smoothed % 360) + 360) % 360;
                m.setBearing(smoothed);
                if (Math.abs(shortestDelta(targetHeading, smoothed)) > 0.3) schedule();
            }
            function schedule() {
                if (rafId === null) rafId = requestAnimationFrame(tick);
            }

            // 現在のモードに応じて向きを反映する
            function applyHeading() {
                if (mode === MODE_OFF) return;
                setConeHeading(targetHeading);    // どちらのモードでも扇形は表示・回転
                if (mode === MODE_MAPUP) schedule(); // 方向朝上ではさらに地図も回す
            }

            // 原生がコンパス更新ごとに呼ぶ
            window.__anitabiOnHeading = function(deg) {
                if (typeof deg !== 'number' || isNaN(deg)) return;
                targetHeading = ((deg % 360) + 360) % 360;
                applyHeading();
            };

            function postNative(action) {
                try { window.webkit.messageHandlers.headingHandler.postMessage({ action: action }); } catch (e) {}
            }

            function updateButton() {
                var btn = document.querySelector('.mapboxgl-ctrl-compass');
                if (!btn) return;
                btn.classList.toggle('anitabi-heading-cone-mode', mode === MODE_CONE);
                btn.classList.toggle('anitabi-heading-mapup-mode', mode === MODE_MAPUP);
            }

            // 未定位なら定位コントロールを起動し、蓝点・方向扇形を表示＋現在地へ寄せる
            function ensureLocated() {
                var geo = document.querySelector('.mapboxgl-ctrl-geolocate');
                if (geo && !geo.classList.contains('mapboxgl-ctrl-geolocate-active')
                        && !geo.classList.contains('mapboxgl-ctrl-geolocate-background')) {
                    geo.click();
                }
            }

            function setMode(next) {
                var prev = mode;
                mode = next;
                window.__anitabiHeadingMode = next;
                updateButton();
                var m = getMap();

                // OFF から抜けるとき＝コンパス監視を開始＋定位
                if (prev === MODE_OFF && next !== MODE_OFF) {
                    postNative('start');
                    ensureLocated();
                }

                if (next === MODE_OFF) {
                    postNative('stop');
                    setConeHeading(null);                            // 扇形を消す
                    if (m) m.easeTo({ bearing: 0, duration: 500 });   // 正北へ戻す
                    smoothed = null;
                } else if (next === MODE_CONE) {
                    if (m) m.easeTo({ bearing: 0, duration: 500 });   // 地図は正北固定→扇形の回転が見える
                    smoothed = null;
                    applyHeading();
                } else if (next === MODE_MAPUP) {
                    smoothed = m ? m.getBearing() : 0;                // 現在 bearing から方向朝上へ
                    applyHeading();
                }
            }

            // コンパスボタンのクリックを乗っ取り、3 段階で循環（既定の「重置到北向」は抑止）
            function bindCompass() {
                var btn = document.querySelector('.mapboxgl-ctrl-compass');
                if (!btn || btn.__anitabiBound) return;
                btn.__anitabiBound = true;
                btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    e.stopImmediatePropagation();
                    setMode((mode + 1) % 3);
                }, true); // capture フェーズで Mapbox 既定ハンドラより先に処理
            }

            // コントロール/定位点は動的生成されるため、DOM 変化を監視して再バインド・再反映
            bindCompass();
            var scheduled = false;
            var obs = new MutationObserver(function() {
                if (scheduled) return;
                scheduled = true;
                requestAnimationFrame(function() {
                    scheduled = false;
                    bindCompass();
                    updateButton();
                    if (mode !== MODE_OFF) applyHeading(); // 定位点が再生成されたら向きを再適用
                });
            });
            obs.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """

        let headingUserScript = WKUserScript(
            source: headingScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(headingUserScript)
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
                        // 注意書きを単独行にする。フッターのボタンが増えても重ならないよう、
                        // 全幅を占有してボタン群を次の行へ折り返させる。
                        noticeElement.style.cssText = 'flex-basis: 100%; width: 100%; margin-bottom: 4px;';
                        noticeElement.innerHTML = '<a><i>下列部分按钮可能需要长按才能被跳转</i></a>';
                        // 親（div.foot）を折り返し可能にして、通知の下にボタンが回り込むようにする
                        footerDiv.style.flexWrap = 'wrap';
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
