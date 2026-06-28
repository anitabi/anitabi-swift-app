//
//  UIOnboardingHelper.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/17.
//

import UIKit
import SwiftUI
import UIOnboarding

// MARK: - UIOnboardingHelper

struct UIOnboardingHelper {
    // App Icon
    static func setUpIcon() -> UIImage {
        // 获取应用的 AppIcon
        return Bundle.main.appIcon ?? UIImage(systemName: "app.fill")!
    }

    // First Title Line (欢迎文本)
    static func setUpFirstTitleLine() -> NSMutableAttributedString {
        // 创建 NSMutableAttributedString，设置文字颜色为 .label (适应深色/浅色模式)
        .init(string: String(localized: "欢迎来到"), attributes: [.foregroundColor: UIColor.label])
    }

    // Second Title Line (应用名称)
    static func setUpSecondTitleLine() -> NSMutableAttributedString {
        // 创建 NSMutableAttributedString，设置文字为应用显示名称或默认值，并设置颜色
        .init(string: Bundle.main.displayName ?? "Anitabi", attributes: [
            // 使用 Assets 中的 "camou" 颜色，如果不存在则使用一个默认的绿色
            .foregroundColor: UIColor.init(red: 0.957, green: 0.804, blue: 0.361, alpha: 1.0)
        ])
    }

    // Core Features (核心功能列表) - 根据你的 App 解释进行修改
    static func setUpFeatures() -> Array<UIOnboardingFeature> {
        // 创建 UIOnboardingFeature 数组，每个 feature 包含图标、标题和描述
        // 图标暂时使用系统符号，你可以之后替换为你自己的图片
        return .init([
            .init(icon: UIImage(systemName: "map.fill")!, // 地图/巡礼相关的图标
                  title: String(localized: "探索动画巡礼圣地"), // 标题：强调核心功能 - 发现圣地
                  description: String(localized: "汇集大量动画、漫画、游戏等作品的实地取景地标与配套截图，为你的巡礼做好准备。")), // 描述：说明数据内容和作用
            .init(icon: UIImage(systemName: "square.and.pencil")!, // 投稿/编辑相关的图标
                  title: String(localized: "轻松贡献与共建"), // 标题：强调社区贡献
                  description: String(localized: "在地图上点击即可投稿地标截图信息，参与完善地图数据，让更多巡礼人受益。")), // 描述：说明如何贡献以及意义
            .init(icon: UIImage(systemName: "location.fill")!, // 定位/周边相关的图标
                  title: String(localized: "随时随地发现周边"), // 标题：强调实地使用场景
                  description: String(localized: "身处巡礼地附近？快速查找你当前位置周围的动画取景地，开启一场说走就走的发现之旅。")) // 描述：说明在现场如何使用
        ])
    }

    // Notice Text (底部通知/链接文本) - 根据你的 App 解释进行修改
    static func setUpNotice() -> UIOnboardingTextViewConfiguration {
        // 创建 UIOnboardingTextViewConfiguration，包含可选图标、文本、链接文字和实际链接
        // 图标是可选的 (UIImage?)
        return .init(icon: UIImage(systemName: "book.closed"), // 协议/信息相关的图标
                     text: String(localized: "本工具基于社区共建，数据遵循 署名、非商业性使用、相同方式共享 的 CC BY-NC-SA 4.0 协议共享。"), // 文本：说明社区共建和协议
                     linkTitle: String(localized: "了解协议细节"), // 链接显示的文字
                     link: String(localized: "https://creativecommons.org/licenses/by-nc-sa/4.0/deed.zh-hans"), // 实际链接 URL 到协议页面（按语言切换 deed 页面）
                     tint: UIColor.init(red: 0.957, green: 0.804, blue: 0.361, alpha: 1.0))
    }

    // Continuation Button (继续按钮)
    static func setUpButton() -> UIOnboardingButtonConfiguration {
        // 创建 UIOnboardingButtonConfiguration，设置按钮文字和背景色
        return .init(title: String(localized: "开始使用"), // 按钮文字
                     // titleColor: .white, // 可选，默认为 .white
                     backgroundColor: .init(red: 0.957, green: 0.804, blue: 0.361, alpha: 1.0))
    }
}

// 扩展 UIOnboardingViewConfiguration，添加一个便捷的 setup 方法
extension UIOnboardingViewConfiguration {
    static func setUp() -> UIOnboardingViewConfiguration {
        return .init(appIcon: UIOnboardingHelper.setUpIcon(),
                     firstTitleLine: UIOnboardingHelper.setUpFirstTitleLine(),
                     secondTitleLine: UIOnboardingHelper.setUpSecondTitleLine(),
                     features: UIOnboardingHelper.setUpFeatures(),
                     textViewConfiguration: UIOnboardingHelper.setUpNotice(),
                     buttonConfiguration: UIOnboardingHelper.setUpButton())
    }
}

// Bundle 扩展，用于获取 AppIcon 和 displayName
extension Bundle {
    var appIcon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? Dictionary<String, Any>,
           let primary = icons["CFBundlePrimaryIcon"] as? Dictionary<String, Any>,
           let files = primary["CFBundleIconFiles"] as? Array<String>,
           let icon = files.last {
            return .init(named: icon)
        } else {
            return nil
        }
    }

    var displayName: String? {
        // localizedInfoDictionary は InfoPlist.strings のローカライズ済みの値を返す。
        // infoDictionary だけだと常に Base（zh-Hans）の値になり、英語/日本語表示でも中国語名が出てしまう。
        return (localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleDisplayName"] as? String)
    }

    var versionString: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

// OnboardingView 是一个 UIViewControllerRepresentable，用于在 SwiftUI 中使用 UIOnboardingViewController
struct OnboardingView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIOnboardingViewController

    // 使用 @Binding 来接收一个 Bool 值，用于控制视图的显示/隐藏
    @Binding var isPresented: Bool

    // Coordinator 类用于作为 UIOnboardingViewController 的代理
    // 当用户完成引导时，UIOnboardingViewController 会调用代理方法
    class Coordinator: NSObject, UIOnboardingViewControllerDelegate {
        // 存储对 OnboardingView 父视图的引用，以便更新 isPresented 状态
        var parent: OnboardingView

        init(parent: OnboardingView) {
            self.parent = parent
        }

        // UIOnboardingViewControllerDelegate 方法，当用户点击"继续"按钮时被调用
        func didFinishOnboarding(onboardingViewController: UIOnboardingViewController) {
            // 在这里处理完成引导后的逻辑，例如设置 UserDefaults
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding") // 设置 UserDefaults 标记用户已完成引导

            // 解除呈现 onboardingViewController
            onboardingViewController.modalTransitionStyle = .crossDissolve // 设置过渡动画 (可选)
            onboardingViewController.dismiss(animated: true) {
                // 动画完成后，更新 isPresented 状态，隐藏 SwiftUI 中的 fullScreenCover
                self.parent.isPresented = false
            }
        }
    }

    // SwiftUI 调用此方法来创建 UIOnboardingViewController 实例
    func makeUIViewController(context: Context) -> UIOnboardingViewController {
        // 使用 UIOnboardingHelper 中定义的配置来创建 UIOnboardingViewController
        let onboardingController: UIOnboardingViewController = .init(withConfiguration: .setUp())
        // 设置代理为 Coordinator 实例
        onboardingController.delegate = context.coordinator
        // modalPresentationStyle 默认为 .fullScreen，所以这里可以省略
        // onboardingController.modalPresentationStyle = .fullScreen
        return onboardingController
    }

    // SwiftUI 调用此方法来更新 UIOnboardingViewController
    // 对于 UIOnboarding，通常不需要在这里做太多更新逻辑
    func updateUIViewController(_ uiViewController: UIOnboardingViewController, context: Context) {
        // 根据需要更新视图控制器
    }

    // 创建并返回 Coordinator 实例
    func makeCoordinator() -> Coordinator {
        // 将当前的 OnboardingView 实例传递给 Coordinator
        Coordinator(parent: self)
    }
}