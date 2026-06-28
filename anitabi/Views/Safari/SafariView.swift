//
//  SafariView.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import WebKit

struct SafariView: UIViewRepresentable {
    let url: URL
    var cssString: String = """
        .func-header-box nav a.router-link-active,
        .func-header-box nav a[href*="bangumi"],
        a[href*="sponsor.png"] {
            display: none !important;
        }
        """
    var onClose: (() -> Void)? = nil  // 添加关闭回调函数
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        
        // 添加消息处理器以处理关闭按钮点击
        configuration.userContentController.add(context.coordinator, name: "closeHandler")
        
        // 创建用于注入CSS的用户脚本
        let jsString = """
        function injectCSS() {
            const style = document.createElement('style');
            style.textContent = `\(cssString)`;
            document.head.appendChild(style);
        }
        
        // 在DOM加载完成后执行
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectCSS);
        } else {
            injectCSS();
        }
        """
        
        // 只有在有CSS需要注入时才创建并添加脚本
        if !cssString.isEmpty {
            let userScript = WKUserScript(
                source: jsString,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(userScript)
        }
        
        // 添加关闭按钮注入脚本
        let closeButtonScript = """
        function injectCloseButton() {
            // 查找导航栏
            const nav = document.querySelector('nav.layout');
            if (nav) {
                // 检查是否已经存在关闭按钮
                if (!document.getElementById('close-safari-btn')) {
                    // 创建关闭按钮
                    const closeButton = document.createElement('a');
                    closeButton.id = 'close-safari-btn';
                    closeButton.className = "";
                    closeButton.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" class="ui-icon"><path d="M18.3 5.71a1 1 0 0 0-1.42 0L12 10.59 7.12 5.7A1 1 0 0 0 5.7 7.12L10.59 12l-4.88 4.88a1 1 0 1 0 1.42 1.42L12 13.41l4.88 4.88a1 1 0 0 0 1.42-1.42L13.41 12l4.88-4.88a1 1 0 0 0 0-1.41z"/></svg><span>\(String(localized: "关闭"))</span></a>';
                    
                    // 添加点击事件监听器
                    closeButton.addEventListener('click', function(e) {
                        e.preventDefault();
                        window.webkit.messageHandlers.closeHandler.postMessage('close');
                    });
                    
                    // 添加到导航栏
                    nav.appendChild(closeButton);
                }
            }
        }

        // 初始运行
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectCloseButton);
        } else {
            injectCloseButton();
        }

        // 用 MutationObserver 代替每秒轮询：仅在 DOM 变化时（动态加载的页面）重新注入，
        // 通过 requestAnimationFrame 合并连续变化，空闲时零开销。
        let closeBtnScheduled = false;
        const closeBtnObserver = new MutationObserver(function() {
            if (closeBtnScheduled) return;
            closeBtnScheduled = true;
            requestAnimationFrame(function() {
                closeBtnScheduled = false;
                injectCloseButton();
            });
        });
        closeBtnObserver.observe(document.documentElement, { childList: true, subtree: true });
        """
        
        let closeButtonUserScript = WKUserScript(
            source: closeButtonScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(closeButtonUserScript)
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 如果URL发生改变，重新加载
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: SafariView
        
        init(_ parent: SafariView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 如果CSS内容在页面加载后改变，可以在这里重新注入
            if !parent.cssString.isEmpty {
                let jsString = """
                var style = document.createElement('style');
                style.textContent = `\(parent.cssString)`;
                document.head.appendChild(style);
                """
                webView.evaluateJavaScript(jsString, completionHandler: nil)
            }
            
            // 页面加载完成后，确保关闭按钮被注入
            webView.evaluateJavaScript("injectCloseButton();", completionHandler: nil)
        }
        
        // 处理来自JavaScript的消息
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "closeHandler" && message.body as? String == "close" {
                // 调用关闭回调
                DispatchQueue.main.async {
                    self.parent.onClose?()
                }
            }
        }
    }
}