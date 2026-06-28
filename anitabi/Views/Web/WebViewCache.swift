//
//  WebViewCache.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import Foundation
@preconcurrency import WebKit

// URLキャッシュを管理するクラス
class ResourceCacheManager {
    static let shared = ResourceCacheManager()
    private let cache = NSCache<NSString, NSData>()
    private var expirationTimes = [String: Date]()
    private let cacheValidityPeriod: TimeInterval = 3600 // 1時間（秒単位）
    // expirationTimes は複数スレッドから読み書きされうるため保護する
    private let lock = NSLock()
    
    private let cachableResources = [
        "https://anitabi.cn/mapbox/anitabi/ani@2x.png",
        "https://anitabi.cn/mapbox/anitabi/ani@2x.csv",
        "https://anitabi.cn/images/bangumi-icons.webp"
    ]
    
    func isCachableResource(_ urlString: String) -> Bool {
        return cachableResources.contains(urlString)
    }
    
    func cacheData(_ data: Data, for urlString: String) {
        let key = urlString as NSString
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(data as NSData, forKey: key)
        expirationTimes[urlString] = Date().addingTimeInterval(cacheValidityPeriod)
    }

    func getCachedData(for urlString: String) -> Data? {
        let key = urlString as NSString
        lock.lock()
        defer { lock.unlock() }

        // キャッシュの有効期限をチェック
        if let expirationTime = expirationTimes[urlString], expirationTime > Date(),
           let cachedData = cache.object(forKey: key) {
            return cachedData as Data
        } else {
            // 期限切れなら削除
            cache.removeObject(forKey: key)
            expirationTimes.removeValue(forKey: urlString)
            return nil
        }
    }
}

// URLをインターセプトするためのURL Scheme Handler
class CacheURLSchemeHandler: NSObject, WKURLSchemeHandler {
    // 進行中のタスクを追跡。stop 後に didReceive / didFinish を呼ぶと
    // 「This task has already been stopped」で例外（クラッシュ）になるため、
    // コールバック前に有効性を確認する。
    private var activeTasks = Set<ObjectIdentifier>()
    private let tasksLock = NSLock()

    private func markActive(_ task: WKURLSchemeTask) {
        tasksLock.lock(); defer { tasksLock.unlock() }
        activeTasks.insert(ObjectIdentifier(task as AnyObject))
    }

    /// タスクがまだ有効なら true を返し、同時に追跡から外す（= これ以上コールバックしない）。
    private func consumeIfActive(_ task: WKURLSchemeTask) -> Bool {
        tasksLock.lock(); defer { tasksLock.unlock() }
        return activeTasks.remove(ObjectIdentifier(task as AnyObject)) != nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let urlString = url.absoluteString.replacingOccurrences(of: "cached:", with: "") as String? else {
            urlSchemeTask.didFailWithError(NSError(domain: "Invalid URL", code: 0, userInfo: nil))
            return
        }

        markActive(urlSchemeTask)

        // キャッシュからデータを取得
        if let cachedData = ResourceCacheManager.shared.getCachedData(for: urlString) {
            guard consumeIfActive(urlSchemeTask) else { return }
            // キャッシュから応答
            let response = URLResponse(url: url, mimeType: getMimeType(for: url), expectedContentLength: cachedData.count, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(cachedData)
            urlSchemeTask.didFinish()
            return
        }

        // キャッシュになければ通常のリクエストを行い、キャッシュに保存
        if let originalURL = URL(string: urlString) {
            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: originalURL)
                    // キャッシュ保存は stop されていても問題ないので先に行う
                    ResourceCacheManager.shared.cacheData(data, for: urlString)
                    await MainActor.run {
                        guard self.consumeIfActive(urlSchemeTask) else { return }
                        // 応答を返す
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(data)
                        urlSchemeTask.didFinish()
                    }
                } catch {
                    await MainActor.run {
                        guard self.consumeIfActive(urlSchemeTask) else { return }
                        urlSchemeTask.didFailWithError(error)
                    }
                }
            }
        } else {
            guard consumeIfActive(urlSchemeTask) else { return }
            urlSchemeTask.didFailWithError(NSError(domain: "Invalid URL", code: 0, userInfo: nil))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 追跡から外し、以降のコールバックを抑止する
        _ = consumeIfActive(urlSchemeTask)
    }
    
    private func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "application/octet-stream"
        }
    }
}

// URLインターセプトするためのNavigationDelegate
class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let urlString = navigationAction.request.url?.absoluteString,
           ResourceCacheManager.shared.isCachableResource(urlString) {
            // キャッシュ対象のURLならcached:スキームに変換してリクエスト
            if let cachedURL = URL(string: "cached:" + urlString) {
                webView.load(URLRequest(url: cachedURL))
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
} 
