import SwiftUI
import UIKit

/// 全屏图片查看器：捏合缩放 + 双击缩放 + 1x 时下拉关闭。
///
/// 关键在 `isScrollEnabled`：放大后交给 UIScrollView 拖动图片，
/// 回到 1x 时交回 SwiftUI，下拉手势才能被我们接住（否则被 scrollview 吃掉）。
struct ImageViewerScreen: View {

    let url: URL
    var title: String = ""

    @Environment(\.presentationMode) private var presentationMode
    @State private var image: UIImage?
    @State private var errorText: String?
    @State private var zoom: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing = false
    @State private var showChrome = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImage(image: image, zoom: $zoom)
                    .ignoresSafeArea()
                    .offset(y: dragOffset.height)
                    .scaleEffect(dragOffset == .zero ? 1 : 0.94)
                    .animation(.interactiveSpring(), value: dragOffset)
            } else if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                ProgressView().progressViewStyle(.circular).tint(.white)
            }

            if showChrome {
                VStack {
                    HStack {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .statusBar(hidden: !showChrome)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard zoom <= 1.01, !isDismissing else { return }
                    dragOffset = CGSize(width: value.translation.width * 0.4,
                                        height: max(0, value.translation.height))
                }
                .onEnded { value in
                    guard zoom <= 1.01, !isDismissing else { return }
                    let predicted = value.predictedEndTranslation.height
                    if value.translation.height > 120 || predicted > 320 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .task {
            do {
                // 查看器要的是原图：这里**不**降采样（maxPixelSize: nil），
                // 反正全屏也就这一张，而且用户放大时得看细节
                image = try await FAImageCache.shared.image(for: url, maxPixelSize: nil)
            } catch {
                errorText = String(describing: error)
            }
        }
    }

    private func close() {
        if !showChrome { showChrome = true }
        presentationMode.wrappedValue.dismiss()
    }

    private func dismiss() {
        isDismissing = true
        dragOffset.height = max(dragOffset.height, 200)
        presentationMode.wrappedValue.dismiss()
    }
}

/// UIScrollView 版缩放：支持捏合、双击放大/还原，双击点即缩放锚点。
///
/// 布局这层踩过一个坑：`makeUIView`/`updateUIView` 被调用时 bounds 常常还全是 0，
/// 在那里算 aspectFit 会把 imageView 留成原始像素尺寸（真机上表现为「只看到图的一个角」）。
/// 所以布局挂在 `UIScrollView.layoutSubviews` 上（自定义子类），
/// 并且只在 bounds 真的变化时才重算 —— 否则每次缩放回调引起的 SwiftUI 重绘都会把 zoomScale 打回 1。
struct ZoomableImage: UIViewRepresentable {

    let image: UIImage
    @Binding var zoom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let scrollView = ZoomingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.imageSize = image.size
        scrollView.onLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView else { return }
            coordinator?.layoutIfNeeded(in: scrollView)
        }

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // 单击用于切换 chrome：交给 SwiftUI 的 onTapGesture 处理，这里不抢
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layoutIfNeeded(in: scrollView)
        // 放大时才让 scrollview 接管拖拽
        scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
    }

    /// 只做一件事：每次 bounds 变化时把内容按 aspectFit 摆好
    final class ZoomingScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?
        var imageSize: CGSize = .zero
        private var lastBounds: CGSize = .zero

        init(_ parent: ZoomableImage) { self.parent = parent }

        /// 按 aspectFit 铺满，并同步 contentSize；只在尺寸变化时才重算，避免把用户缩放的 zoomScale 重置
        func layoutIfNeeded(in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            guard bounds.width > 1, bounds.height > 1, imageSize.width > 0, imageSize.height > 0 else { return }
            guard bounds != lastBounds else { center(scrollView); return }
            lastBounds = bounds

            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let fitted = CGSize(width: (imageSize.width * scale).rounded(.down),
                                height: (imageSize.height * scale).rounded(.down))
            imageView?.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            scrollView.zoomScale = 1
            center(scrollView)
        }

        /// 图片比屏幕小时居中
        private func center(_ scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = scrollView.contentSize
            let vertical = max(0, (bounds.height - content.height) / 2)
            let horizontal = max(0, (bounds.width - content.width) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                                   bottom: vertical, right: horizontal)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoom = scrollView.zoomScale
            scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
            center(scrollView)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let target: CGFloat = 2.5
                let width = scrollView.bounds.width / target
                let height = scrollView.bounds.height / target
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2,
                                  width: width, height: height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
