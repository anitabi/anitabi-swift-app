//
//  SafariView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import WebKit

// アプリ内ブラウザ（シート表示）。
// App-Bound Domains 有効化に伴い、この WebView（外部ドメインも開くため
// limitsNavigationsToAppBoundDomains は付けない）ではスクリプト注入・messageHandler が
// WebKit により無効化される。そのため旧来の「JS で閉じるボタンを注入する」方式をやめ、
// ネイティブのバーで閉じる。
struct SafariView: View {
    let url: URL
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.host ?? "")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    onClose?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                        Text("关闭")
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
            Divider()
            SafariWebView(url: url)
        }
    }
}

// WKWebView 本体。注入なしの素の閲覧のみ。
private struct SafariWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 表示対象の URL が差し替えられた場合のみ再ロード
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}
