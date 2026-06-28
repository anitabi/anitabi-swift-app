//
//  ImageViewer.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/11.
//

import SwiftUI
import Photos
import UIKit

// 画像保存コールバックを処理するヘルパークラス
class ImageSaver: NSObject {
    var onSuccess: () -> Void
    var onError: (Error) -> Void
    
    init(onSuccess: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.onSuccess = onSuccess
        self.onError = onError
    }
    
    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            onError(error)
        } else {
            onSuccess()
        }
    }
}

struct ImageViewer: View {
    // MARK: - Properties
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss
    let imageURL: URL?
    
    // MARK: - States
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showingSaveConfirmation = false
    @State private var saveError: String? = nil
    @State private var imageSaver: ImageSaver?
    @State private var imageLoadingState: LoadingState = .loading
    
    enum LoadingState {
        case loading
        case success
        case failure
    }
    
    // MARK: - Body
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                        .ignoresSafeArea()
                    
                    imageContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                leadingToolbarItems
                trailingToolbarItems
            }
            .alert("已保存", isPresented: $showingSaveConfirmation) {
                Button("OK", role: .cancel) { }
            }
            .alert("出现错误", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                if let error = saveError {
                    Text(error)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - View Components
    @ViewBuilder
    private var imageContent: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    loadingView
                case .success(let image):
                    successView(image: image)
                case .failure:
                    failureView
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
    
    private var loadingView: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .onAppear {
                imageLoadingState = .loading
            }
    }
    
    private func successView(image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(dragGesture)
            .gesture(pinchGesture)
            .onTapGesture(count: 2, perform: resetImage)
            .onAppear {
                imageLoadingState = .success
            }
    }
    
    private var failureView: some View {
        VStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.white)
            Text("无法加载图片")
                .foregroundColor(.white)
                .padding(.top, 8)
        }
        .onAppear {
            imageLoadingState = .failure
        }
    }
    
    // MARK: - Toolbar Items
    private var leadingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                dismiss()
                isPresented = false
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(.white)
            }
        }
    }
    
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 20) {
                if let url = imageURL, imageLoadingState == .success {
                    Button(action: {
                        saveImageToPhotoLibrary(from: url)
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(.white)
                    }
                    
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
    
    // MARK: - Gestures
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
    
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                // スケール制限（0.5〜3.0）
                let newScale = scale * delta
                scale = min(max(newScale, 0.5), 3.0)
            }
            .onEnded { _ in
                lastScale = 1.0
            }
    }
    
    // MARK: - Actions
    private func resetImage() {
        withAnimation(.spring()) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }
    
    private func saveImageToPhotoLibrary(from url: URL) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    await MainActor.run {
                        saveError = String(localized: "下载图片失败")
                    }
                    return
                }
                
                await MainActor.run {
                    // 新しいImageSaverインスタンスを作成
                    imageSaver = ImageSaver(
                        onSuccess: {
                            showingSaveConfirmation = true
                        },
                        onError: { error in
                            saveError = String(localized: "保存到相册失败: \(error.localizedDescription)")
                        }
                    )
                    
                    // フォトライブラリに保存
                    UIImageWriteToSavedPhotosAlbum(
                        image,
                        imageSaver,
                        #selector(ImageSaver.image(_:didFinishSavingWithError:contextInfo:)),
                        nil
                    )
                }
            } catch {
                await MainActor.run {
                    saveError = String(localized: "下载图片失败: \(error.localizedDescription)")
                }
            }
        }
    }
} 