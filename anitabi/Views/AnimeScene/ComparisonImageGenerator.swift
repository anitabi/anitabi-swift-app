//
//  ComparisonImageGenerator.swift
//  anitabi
//
//  Created by 维安雨轩 on 2025/05/13.
//

import UIKit
import SwiftUI

// MARK: - 对比图生成器
class ComparisonImageGenerator {
    
    struct DesignConstants {
        static let cornerRadius: CGFloat = 12
        static let horizontalPadding: CGFloat = 20
        static let topPadding: CGFloat = 24
        static let bottomPadding: CGFloat = 24
        static let imageSpacing: CGFloat = 12
        static let iconSize: CGFloat = 28
        static let iconTextSpacing: CGFloat = 10
        static let titleFontSize: CGFloat = 24
        static let locationFontSize: CGFloat = 16
        static let fixedAnimeWidth: CGFloat = 640
        static let fixedAnimeHeight: CGFloat = 360
    }
    
    func generateComparisonImage(
        animeImage: UIImage,
        userImage: UIImage?,
        sceneName: String,
        sceneColor: UIColor,
        sceneLocation: String
    ) -> UIImage? {
        // 常量实例化
        let constants = DesignConstants.self
        
        // 计算画布尺寸
        let contentWidth = constants.fixedAnimeWidth
        let canvasWidth = contentWidth + (constants.horizontalPadding * 2)
        
        // 顶部和底部元素的高度
        let topElementHeight = max(constants.iconSize, constants.titleFontSize + 6) + 6
        let bottomElementHeight = max(constants.iconSize, constants.locationFontSize + 6) + 10
        
        // 画布总高度
        let totalHeight = constants.topPadding + topElementHeight + constants.fixedAnimeHeight + 
                        constants.imageSpacing + constants.fixedAnimeHeight + bottomElementHeight + constants.bottomPadding
        
        let canvasSize = CGSize(width: canvasWidth, height: totalHeight)
        
        // 创建图像渲染器
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        
        return renderer.image { context in
            let ctx = context.cgContext
            
            // 绘制背景和圆角
            drawBackground(in: ctx, size: canvasSize, color: sceneColor)
            
            // 绘制标题区域
            drawTitleArea(in: ctx, sceneName: sceneName)
            
            // 绘制动漫场景图片
            let animeImageRect = CGRect(
                x: constants.horizontalPadding,
                y: constants.topPadding + topElementHeight + 8,
                width: constants.fixedAnimeWidth,
                height: constants.fixedAnimeHeight
            )
            drawImage(animeImage, in: ctx, rect: animeImageRect)
            
            // 绘制用户图像（如果可用）
            if let userImage = userImage {
                let userImageRect = CGRect(
                    x: constants.horizontalPadding,
                    y: animeImageRect.maxY + constants.imageSpacing,
                    width: constants.fixedAnimeWidth,
                    height: constants.fixedAnimeHeight
                )
                drawImage(userImage, in: ctx, rect: userImageRect)
                
                // 绘制位置信息
                drawLocationInfo(in: ctx, at: userImageRect.maxY + bottomElementHeight - constants.iconSize,
                                 location: sceneLocation, canvasWidth: canvasWidth)
            }
        }
    }
    
    // MARK: - 私有绘图方法
    
    private func drawBackground(in context: CGContext, size: CGSize, color: UIColor) {
        let backgroundRect = CGRect(origin: .zero, size: size)
        let backgroundPath = UIBezierPath(roundedRect: backgroundRect, cornerRadius: DesignConstants.cornerRadius)
        color.setFill()
        backgroundPath.fill()
    }
    
    private func drawTitleArea(in context: CGContext, sceneName: String) {
        let constants = DesignConstants.self

        // 绘制favicon（存在する場合のみ）
        let favicon = UIImage(named: "favicon")
        if let favicon = favicon {
            let faviconRect = CGRect(
                x: constants.horizontalPadding,
                y: constants.topPadding,
                width: constants.iconSize,
                height: constants.iconSize
            )
            favicon.draw(in: faviconRect)
        }

        // 绘制场景名称文本（favicon の有無に関わらず常に描画する）
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: constants.titleFontSize, weight: .medium),
            .foregroundColor: UIColor.white,
            .shadow: {
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
                shadow.shadowOffset = CGSize(width: 1, height: 1)
                shadow.shadowBlurRadius = 3
                return shadow
            }()
        ]

        // favicon がある場合はその右隣から、ない場合は左端から描画する
        let titleX = favicon != nil
            ? constants.horizontalPadding + constants.iconSize + constants.iconTextSpacing
            : constants.horizontalPadding
        let titleRect = CGRect(
            x: titleX,
            y: constants.topPadding + (constants.iconSize - constants.titleFontSize) / 2 - 2,
            width: constants.fixedAnimeWidth - (titleX - constants.horizontalPadding),
            height: constants.titleFontSize + 4
        )

        sceneName.draw(in: titleRect, withAttributes: titleAttributes)
    }
    
    private func drawImage(_ image: UIImage, in context: CGContext, rect: CGRect) {
        // 创建用于裁剪的圆角路径
        let imagePath = UIBezierPath(roundedRect: rect, cornerRadius: DesignConstants.cornerRadius)
        context.saveGState()
        imagePath.addClip()
        
        // 计算图像的缩放比例
        let imageAspect = image.size.width / image.size.height
        let targetAspect = rect.width / rect.height
        
        var drawRect = rect
        
        if imageAspect > targetAspect {
            // 原图比例更宽，以高度为基准缩放
            let scaledWidth = rect.height * imageAspect
            drawRect.origin.x = rect.minX + (rect.width - scaledWidth) / 2
            drawRect.size.width = scaledWidth
        } else {
            // 原图比例更窄，以宽度为基准缩放
            let scaledHeight = rect.width / imageAspect
            drawRect.origin.y = rect.minY + (rect.height - scaledHeight) / 2
            drawRect.size.height = scaledHeight
        }
        
        image.draw(in: drawRect)
        context.restoreGState()
    }
    
    private func drawLocationInfo(in context: CGContext, at y: CGFloat, location: String, canvasWidth: CGFloat) {
        guard !location.isEmpty else { return }
        
        let constants = DesignConstants.self
        
        let locationAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: constants.locationFontSize, weight: .regular),
            .foregroundColor: UIColor.white
        ]
        
        // 计算位置文本大小
        let locationTextSize = location.size(withAttributes: locationAttributes)
        
        // 绘制位置图标
        if let locationIcon = UIImage(systemName: "mappin.and.ellipse") {
            let iconTint = locationIcon.withTintColor(.white, renderingMode: .alwaysOriginal)
            
            // 位置从右侧开始，为文本留出空间
            let locationIconRect = CGRect(
                x: canvasWidth - constants.horizontalPadding - locationTextSize.width - constants.iconTextSpacing - constants.iconSize,
                y: y,
                width: constants.iconSize,
                height: constants.iconSize
            )
            iconTint.draw(in: locationIconRect)
            
            // 绘制位置文本
            let locationRect = CGRect(
                x: locationIconRect.maxX + constants.iconTextSpacing,
                y: locationIconRect.minY + (constants.iconSize - constants.locationFontSize) / 2 - 2,
                width: locationTextSize.width,
                height: locationTextSize.height
            )
            
            location.draw(in: locationRect, withAttributes: locationAttributes)
        }
    }
} 