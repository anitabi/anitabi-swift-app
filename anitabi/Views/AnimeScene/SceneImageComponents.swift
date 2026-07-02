//
//  SceneImageComponents.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/13.
//

import SwiftUI
import UIKit
import AVFoundation

// MARK: - 场景图像视图
struct SceneImageView: View {
    let url: URL
    
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                loadingView
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .clipped()
            case .failure:
                errorView
            @unknown default:
                EmptyView()
            }
        }
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black.opacity(0.8)
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }
    
    private var errorView: some View {
        ZStack {
            Color.black.opacity(0.8)
            VStack(spacing: 12) {
                Image(systemName: "photo.fill")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                Text("无法加载图片")
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - 相机视图
/// 预览层由 CameraViewModel 在 init 时创建并持有；这里只负责「挂到视图树 + 跟随布局」。
/// 渲染路径上绝不触碰会话状态（isRunning/startRunning 等）——那些读写会和会话队列同步，
/// 曾导致打开相机时整页冻结、拖动控件时逐帧微卡顿。
struct CameraView: UIViewRepresentable {
    let cameraVM: CameraViewModel

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView(previewLayer: cameraVM.previewLayer)
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // 故意留空：frame 由 layoutSubviews 跟随，会话生命周期由 VM 管理。
    }
}

/// 承载 AVCaptureVideoPreviewLayer 的 UIView：layoutSubviews 里同步 frame（禁用隐式动画，避免旋转时预览漂移）。
final class CameraPreviewUIView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 分享表单
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 图像处理工具

extension UIImage {
    /// `imageOrientation` を `.up` に正規化する。
    /// cgImage はピクセルだけを持ち向き(EXIF)を無視するため、ピクセル単位でクロップする前に必須。
    /// PHPicker 由来の任意向き画像にも効く防御策。
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 中心を基準に指定アスペクト比へクロップする（`videoGravity = .resizeAspectFill` の中心クロップを再現）。
    func cropped(toAspect aspect: CGFloat) -> UIImage {
        guard aspect > 0 else { return self }
        let img = normalizedUp()
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return img }
        let current = w / h
        var cropW = w, cropH = h
        if current > aspect {          // 横長 → 横を削る（左右をクロップ）
            cropW = h * aspect
        } else if current < aspect {   // 縦長 → 縦を削る（上下をクロップ）
            cropH = w / aspect
        }
        let s = img.scale
        let pxRect = CGRect(
            x: (w - cropW) / 2 * s,
            y: (h - cropH) / 2 * s,
            width: cropW * s,
            height: cropH * s
        ).integral
        guard let cg = img.cgImage?.cropping(to: pxRect) else { return img }
        return UIImage(cgImage: cg, scale: s, orientation: .up)
    }

    /// オーバーレイ表示用に長辺を `maxDimension` 以下へ縮小する（向きも `.up` に正規化される）。
    /// ジェスチャー中の大画像ラスタライズによるカクつきを防ぐ。原寸は合成用に別途保持する。
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return normalizedUp() }
        let ratio = maxDimension / longest
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// アスペクト比（width / height）。0 除算は防ぐ。
    var aspectRatioValue: CGFloat {
        size.height > 0 ? size.width / size.height : 1
    }
}

/// 指定アスペクト比の矩形を `box` 内に最大サイズで内接させたサイズを返す（等比・中央寄せ用）。
func aspectFit(aspect: CGFloat, into box: CGSize) -> CGSize {
    guard aspect > 0, box.width > 0, box.height > 0 else { return box }
    if box.width / box.height > aspect {
        return CGSize(width: box.height * aspect, height: box.height)
    } else {
        return CGSize(width: box.width, height: box.width / aspect)
    }
}

// MARK: - Helper Extensions
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
} 