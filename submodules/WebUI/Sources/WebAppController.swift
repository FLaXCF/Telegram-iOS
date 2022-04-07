import Foundation
import UIKit
import WebKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import AttachmentUI
import CounterContollerTitleView
import ContextUI
import PresentationDataUtils
import HexColor
import ShimmerEffect
import PhotoResources
import LegacyComponents
import UrlHandling

public struct WebAppParameters {
    let peerId: PeerId
    let botId: PeerId
    let botName: String
    let url: String?
    let queryId: Int64?
    let buttonText: String?
    let keepAliveSignal: Signal<Never, KeepWebViewError>?
    let fromMenu: Bool
    
    public init(
        peerId: PeerId,
        botId: PeerId,
        botName: String,
        url: String?,
        queryId: Int64?,
        buttonText: String?,
        keepAliveSignal: Signal<Never, KeepWebViewError>?,
        fromMenu: Bool
    ) {
        self.peerId = peerId
        self.botId = botId
        self.botName = botName
        self.url = url
        self.queryId = queryId
        self.buttonText = buttonText
        self.keepAliveSignal = keepAliveSignal
        self.fromMenu = fromMenu
    }
}

public func generateWebAppThemeParams(_ presentationTheme: PresentationTheme) -> [String: Any] {
    var backgroundColor = presentationTheme.list.plainBackgroundColor.rgb
    if backgroundColor == 0x000000 {
        backgroundColor = presentationTheme.list.itemBlocksBackgroundColor.rgb
    }
    return [
        "bg_color": Int32(bitPattern: backgroundColor),
        "text_color": Int32(bitPattern: presentationTheme.list.itemPrimaryTextColor.rgb),
        "hint_color": Int32(bitPattern: presentationTheme.list.itemSecondaryTextColor.rgb),
        "link_color": Int32(bitPattern: presentationTheme.list.itemAccentColor.rgb),
        "button_color": Int32(bitPattern: presentationTheme.list.itemCheckColors.fillColor.rgb),
        "button_text_color": Int32(bitPattern: presentationTheme.list.itemCheckColors.foregroundColor.rgb)
    ]
}

public final class WebAppController: ViewController, AttachmentContainable {
    public var requestAttachmentMenuExpansion: () -> Void = { }
    public var updateNavigationStack: (@escaping ([AttachmentContainable]) -> ([AttachmentContainable], AttachmentMediaPickerContext?)) -> Void = { _ in }
    public var updateTabBarAlpha: (CGFloat, ContainedViewLayoutTransition) -> Void  = { _, _ in }
    public var cancelPanGesture: () -> Void = { }
    public var isContainerPanning: () -> Bool = { return false }
        
    fileprivate class Node: ViewControllerTracingNode, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
        private weak var controller: WebAppController?
        
        fileprivate var webView: WebAppWebView?
        private var placeholderIcon: UIImage?
        private var placeholderNode: ShimmerEffectNode?
    
        fileprivate let loadingProgressPromise = Promise<CGFloat?>(nil)
        fileprivate let mainButtonStatePromise = Promise<AttachmentMainButtonState?>(nil)
        
        private let context: AccountContext
        var presentationData: PresentationData
        private let present: (ViewController, Any?) -> Void
        private var queryId: Int64?
        
        private var iconDisposable: Disposable?
        private var keepAliveDisposable: Disposable?
        
        init(context: AccountContext, controller: WebAppController, present: @escaping (ViewController, Any?) -> Void) {
            self.context = context
            self.controller = controller
            self.presentationData = controller.presentationData
            self.present = present
            
            super.init()
            
            if self.presentationData.theme.list.plainBackgroundColor.rgb == 0x000000 {
                self.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            } else {
                self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
            }
                         
            let webView = WebAppWebView()
            webView.alpha = 0.0
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.scrollView.delegate = self
            webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: [], context: nil)
            webView.tintColor = self.presentationData.theme.rootController.tabBar.iconColor
            webView.handleScriptMessage = { [weak self] message in
                self?.handleScriptMessage(message)
            }
            self.webView = webView
            
            let placeholderNode = ShimmerEffectNode()
            self.addSubnode(placeholderNode)
            self.placeholderNode = placeholderNode
                       
            let _ = (self.context.engine.messages.getAttachMenuBot(botId: controller.botId, cached: true)
            |> deliverOnMainQueue).start(next: { [weak self] bot in
                guard let strongSelf = self else {
                    return
                }
                var iconFile: TelegramMediaFile?
                if let file = bot.icons[.iOSStatic] {
                    iconFile = file
                } else if let file = bot.icons[.default] {
                    iconFile = file
                }
                if let iconFile = iconFile, let peer = PeerReference(bot.peer) {
                    let _ = freeMediaFileInteractiveFetched(account: strongSelf.context.account, fileReference: .attachBot(peer: peer, media: iconFile)).start()
                    strongSelf.iconDisposable = (svgIconImageFile(account: strongSelf.context.account, fileReference: .attachBot(peer: peer, media: iconFile))
                    |> deliverOnMainQueue).start(next: { [weak self] transform in
                        if let strongSelf = self {
                            let imageSize = CGSize(width: 75.0, height: 75.0)
                            let arguments = TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets())
                            let drawingContext = transform(arguments)
                            if let image = drawingContext?.generateImage()?.withRenderingMode(.alwaysTemplate) {
                                strongSelf.placeholderIcon = image
                                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                                }
                            }
                        }
                    })
                }
            })
                
            if let url = controller.url, !controller.fromMenu {
                self.queryId = controller.queryId
                if let parsedUrl = URL(string: url) {
                    self.webView?.load(URLRequest(url: parsedUrl))
                }
                
                if let keepAliveSignal = controller.keepAliveSignal {
                    self.keepAliveDisposable = (keepAliveSignal
                    |> deliverOnMainQueue).start(error: { [weak self] _ in
                        if let strongSelf = self {
                            strongSelf.controller?.dismiss()
                        }
                    }, completed: { [weak self] in
                        if let strongSelf = self {
                            strongSelf.controller?.dismiss()
                        }
                    })
                }
            } else {
                let _ = (context.engine.messages.requestWebView(peerId: controller.peerId, botId: controller.botId, url: controller.url, payload: nil, themeParams: generateWebAppThemeParams(presentationData.theme), fromMenu: controller.fromMenu, replyToMessageId: controller.replyToMessageId)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let strongSelf = self else {
                        return
                    }
                    if let parsedUrl = URL(string: result.url) {
                        strongSelf.queryId = result.queryId
                        strongSelf.webView?.load(URLRequest(url: parsedUrl))
                        
                        strongSelf.keepAliveDisposable = (result.keepAliveSignal
                        |> deliverOnMainQueue).start(error: { [weak self] _ in
                            if let strongSelf = self {
                                strongSelf.controller?.dismiss()
                            }
                        }, completed: { [weak self] in
                            if let strongSelf = self {
                                strongSelf.controller?.completion()
                                strongSelf.controller?.dismiss()
                            }
                        })
                    }
                })
            }
        }
        
        deinit {
            self.iconDisposable?.dispose()
            self.keepAliveDisposable?.dispose()
            
            self.webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        }
        
        override func didLoad() {
            super.didLoad()
            
            guard let webView = self.webView else {
                return
            }
            self.view.addSubview(webView)
        }
        
        @objc fileprivate func mainButtonPressed() {
            self.webView?.sendEvent(name: "main_button_pressed", data: nil)
        }
        
        private func updatePlaceholder(grid: Bool, layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) -> CGSize {
            var shapes: [ShimmerEffect.ShimmerEffectNode.Shape] = []
            var placeholderSize: CGSize = CGSize()
            if grid {
                let spacing: CGFloat = 8.0
                let cols: Int = min(4, Int(floor(layout.size.width / 118.0)))
                let itemSize: CGSize = CGSize(width: cols == 4 ? 111.0 : 118.0, height: 150.0)
                let rows: Int = 4
                
                let sideInset = floorToScreenPixels((layout.size.width - layout.safeInsets.left - layout.safeInsets.right - itemSize.width * CGFloat(cols) - spacing * CGFloat(cols - 1)) / 2.0)
                
                for row in 0 ..< rows {
                    for col in 0 ..< cols {
                        shapes.append(.roundedRect(rect: CGRect(x: layout.safeInsets.left + sideInset + CGFloat(col) * (itemSize.width + spacing), y: navigationBarHeight + CGFloat(row) * (itemSize.height + spacing), width: itemSize.width, height: itemSize.height), cornerRadius: 10.0))
                    }
                }
                
                placeholderSize = layout.size
            } else {
                if let icon = self.placeholderIcon {
                    shapes = [.image(image: icon, rect: CGRect(origin: CGPoint(), size: icon.size))]
                    placeholderSize = icon.size
                }
            }
            
            let theme = self.presentationData.theme
            self.placeholderNode?.update(backgroundColor: self.backgroundColor ?? .clear, foregroundColor: theme.list.mediaPlaceholderColor, shimmeringColor: theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.4), shapes: shapes, horizontal: true, size: placeholderSize)
            
            return placeholderSize
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url?.absoluteString {
                if isTelegramMeLink(url) || isTelegraPhLink(url) {
                    decisionHandler(.cancel)
                    self.controller?.openUrl(url)
                } else {
                    decisionHandler(.allow)
                }
            } else {
                decisionHandler(.allow)
            }
        }
        
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                self.controller?.openUrl(url.absoluteString)
            }
            return nil
        }
                
        private var loadCount = 0
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.loadCount += 1
        }
                
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.loadCount -= 1
            
            Queue.mainQueue().after(0.1, {
                if self.loadCount == 0, let webView = self.webView {
                    let transition = ContainedViewLayoutTransition.animated(duration: 0.2, curve: .linear)
                    transition.updateAlpha(layer: webView.layer, alpha: 1.0)
                    if let placeholderNode = self.placeholderNode {
                        self.placeholderNode = nil
                        transition.updateAlpha(node: placeholderNode, alpha: 0.0, completion: { [weak placeholderNode] _ in
                            placeholderNode?.removeFromSupernode()
                        })
                    }
                }
            })
            
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
        
        @available(iOSApplicationExtension 15.0, iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.prompt)
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let contentOffset = scrollView.contentOffset.y
            self.controller?.navigationBar?.updateBackgroundAlpha(min(30.0, contentOffset) / 30.0, transition: .immediate)
        }
        
        private var validLayout: (ContainerViewLayout, CGFloat)?
        func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
            let previousLayout = self.validLayout?.0
            self.validLayout = (layout, navigationBarHeight)
                        
            if let webView = self.webView {
                let frame = CGRect(origin: CGPoint(x: layout.safeInsets.left, y: navigationBarHeight), size: CGSize(width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(1.0, layout.size.height - navigationBarHeight - layout.intrinsicInsets.bottom)))
                let viewportFrame = CGRect(origin: CGPoint(x: layout.safeInsets.left, y: navigationBarHeight), size: CGSize(width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(1.0, layout.size.height - navigationBarHeight - layout.intrinsicInsets.bottom - layout.additionalInsets.bottom)))
                transition.updateFrame(view: webView, frame: frame)
                
                webView.updateFrame(frame: viewportFrame, transition: transition)
            }
            
            if let placeholderNode = self.placeholderNode {
                let height: CGFloat
                if case .compact = layout.metrics.widthClass {
                    height = layout.size.height - layout.additionalInsets.bottom - layout.intrinsicInsets.bottom
                } else {
                    height = layout.size.height - layout.intrinsicInsets.bottom
                }
                
                let grid = self.controller?.botId.id._internalGetInt64Value() == 2200339955
                let placeholderSize = self.updatePlaceholder(grid: grid, layout: layout, navigationBarHeight: navigationBarHeight, transition: transition)
                let placeholderY: CGFloat = grid ? 0.0 : floorToScreenPixels((height - placeholderSize.height) / 2.0)
                let placeholderFrame =  CGRect(origin: CGPoint(x: floorToScreenPixels((layout.size.width - placeholderSize.width) / 2.0), y: placeholderY), size: placeholderSize)
                transition.updateFrame(node: placeholderNode, frame: placeholderFrame)
                placeholderNode.updateAbsoluteRect(placeholderFrame, within: layout.size)
            }
            
            if let previousLayout = previousLayout, (previousLayout.inputHeight ?? 0.0).isZero, let inputHeight = layout.inputHeight, inputHeight > 44.0 {
                Queue.mainQueue().justDispatch {
                    self.controller?.requestAttachmentMenuExpansion()
                }
            }
        }
        
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if keyPath == "estimatedProgress", let webView = self.webView {
                self.loadingProgressPromise.set(.single(CGFloat(webView.estimatedProgress)))
            }
        }
                
        private func handleScriptMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else {
                return
            }
            
            guard let eventName = body["eventName"] as? String else {
                return
            }
            
            switch eventName {
                case "web_app_data_send":
                    if let eventData = body["eventData"] as? String {
                        self.handleSendData(data: eventData)
                    }
                case "web_app_setup_main_button":
                    if let webView = self.webView, !webView.didTouchOnce {
                        
                    } else if let eventData = (body["eventData"] as? String)?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: eventData, options: []) as? [String: Any] {
                        if var isVisible = json["is_visible"] as? Bool {
                            let text = json["text"] as? String
                            if (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                isVisible = false
                            }
                            
                            let backgroundColorString = json["color"] as? String
                            let backgroundColor = backgroundColorString.flatMap({ UIColor(hexString: $0) }) ?? self.presentationData.theme.list.itemCheckColors.fillColor
                            let textColorString = json["text_color"] as? String
                            let textColor = textColorString.flatMap({ UIColor(hexString: $0) }) ?? self.presentationData.theme.list.itemCheckColors.foregroundColor
                            
                            let isLoading = json["is_progress_visible"] as? Bool
                            let isEnabled = json["is_active"] as? Bool
                            let state = AttachmentMainButtonState(text: text, backgroundColor: backgroundColor, textColor: textColor, isVisible: isVisible, isLoading: isLoading ?? false, isEnabled: isEnabled ?? true)
                            self.mainButtonStatePromise.set(.single(state))
                        }
                    }
                case "web_app_request_viewport":
                    if let (layout, navigationBarHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                    }
                case "web_app_expand":
                    self.controller?.requestAttachmentMenuExpansion()
                case "web_app_close":
                    self.controller?.dismiss()
                default:
                    break
            }
        }
        
        private var dismissed = false
        private func handleSendData(data string: String) {
            guard let controller = self.controller, let buttonText = controller.buttonText, !self.dismissed else {
                return
            }
            controller.dismiss()
            
            if let data = string.data(using: .utf8), let jsonArray = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? [String: Any], let data = jsonArray["data"] {
                var resultString: String?
                if let string = data as? String {
                    resultString = string
                } else if let data1 = try? JSONSerialization.data(withJSONObject: data, options: JSONSerialization.WritingOptions.prettyPrinted), let convertedString = String(data: data1, encoding: String.Encoding.utf8) {
                    resultString = convertedString
                }
                if let resultString = resultString {
                    self.dismissed = true
                    let _ = (self.context.engine.messages.sendWebViewData(botId: controller.botId, buttonText: buttonText, data: resultString)).start()
                }
            }
        }
        
        func updatePresentationData(_ presentationData: PresentationData) {
            self.presentationData = presentationData
            
            if self.presentationData.theme.list.plainBackgroundColor.rgb == 0x000000 {
                self.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            } else {
                self.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
            }
            
            let themeParams = generateWebAppThemeParams(presentationData.theme)
            var themeParamsString = "{theme_params: {"
            for (key, value) in themeParams {
                if let value = value as? Int32 {
                    let color = UIColor(rgb: UInt32(bitPattern: value))
                    
                    if themeParamsString.count > 16 {
                        themeParamsString.append(", ")
                    }
                    themeParamsString.append("\"\(key)\": \"#\(color.hexString)\"")
                }
            }
            themeParamsString.append("}}")
            self.webView?.sendEvent(name: "theme_changed", data: themeParamsString)
        }
    }
    
    fileprivate var controllerNode: Node {
        return self.displayNode as! Node
    }
    
    private var titleView: CounterContollerTitleView?
    private let moreButtonNode: MoreButtonNode
    
    private let context: AccountContext
    private let peerId: PeerId
    private let botId: PeerId
    private let url: String?
    private let queryId: Int64?
    private let buttonText: String?
    private let fromMenu: Bool
    private let keepAliveSignal: Signal<Never, KeepWebViewError>?
    private let replyToMessageId: MessageId?
    
    private var presentationData: PresentationData
    fileprivate let updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)?
    private var presentationDataDisposable: Disposable?
    
    public var openUrl: (String) -> Void = { _ in }
    public var getNavigationController: () -> NavigationController? = { return nil }
    public var completion: () -> Void = {}
        
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, params: WebAppParameters, replyToMessageId: MessageId?) {
        self.context = context
        self.peerId = params.peerId
        self.botId = params.botId
        self.url = params.url
        self.queryId = params.queryId
        self.buttonText = params.buttonText
        self.fromMenu = params.fromMenu
        self.keepAliveSignal = params.keepAliveSignal
        self.replyToMessageId = replyToMessageId
        
        self.updatedPresentationData = updatedPresentationData
        self.presentationData = updatedPresentationData?.initial ?? context.sharedContext.currentPresentationData.with { $0 }
        
        self.moreButtonNode = MoreButtonNode(theme: self.presentationData.theme)
        self.moreButtonNode.iconNode.enqueueState(.more, animated: false)
        
        let navigationBarPresentationData = NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: self.presentationData.theme), strings: NavigationBarStrings(back: "", close: ""))
        super.init(navigationBarPresentationData: navigationBarPresentationData)
        
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Cancel, style: .plain, target: self, action: #selector(self.cancelPressed))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: self.moreButtonNode)
        self.navigationItem.rightBarButtonItem?.action = #selector(self.moreButtonPressed)
        self.navigationItem.rightBarButtonItem?.target = self
        
        let titleView = CounterContollerTitleView(theme: self.presentationData.theme)
        titleView.title = CounterContollerTitle(title: params.botName, counter: self.presentationData.strings.Bot_GenericBotStatus)
        self.navigationItem.titleView = titleView
        self.titleView = titleView
        
        self.moreButtonNode.action = { [weak self] _, gesture in
            if let strongSelf = self {
                strongSelf.morePressed(node: strongSelf.moreButtonNode.contextSourceNode, gesture: gesture)
            }
        }
        
        self.presentationDataDisposable = ((updatedPresentationData?.signal ?? context.sharedContext.presentationData)
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self {
                strongSelf.presentationData = presentationData
                
                let navigationBarPresentationData = NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: presentationData.theme), strings: NavigationBarStrings(back: "", close: ""))
                strongSelf.navigationBar?.updatePresentationData(navigationBarPresentationData)
                strongSelf.titleView?.theme = presentationData.theme
                
                if strongSelf.isNodeLoaded {
                    strongSelf.controllerNode.updatePresentationData(presentationData)
                }
            }
        })
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        assert(true)
        self.presentationDataDisposable?.dispose()
    }
    
    @objc private func cancelPressed() {
        self.dismiss()
    }
    
    @objc private func moreButtonPressed() {
        self.moreButtonNode.action?(self.moreButtonNode.contextSourceNode, nil)
    }
    
    @objc private func morePressed(node: ContextReferenceContentNode, gesture: ContextGesture?) {
        let context = self.context
        let presentationData = self.presentationData
        
        let peerId = self.peerId
        let botId = self.botId
        
        let items = context.engine.messages.attachMenuBots()
        |> map { [weak self] attachMenuBots -> ContextController.Items in
            var items: [ContextMenuItem] = []
            if peerId != botId {
                items.append(.action(ContextMenuActionItem(text: presentationData.strings.WebApp_OpenBot, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Bots"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    f(.default)
                    
                    if let strongSelf = self, let navigationController = strongSelf.getNavigationController() {
                        strongSelf.dismiss()
                        strongSelf.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: strongSelf.context, chatLocation: .peer(id: strongSelf.botId)))
                    }
                })))
            }
            
            items.append(.action(ContextMenuActionItem(text: presentationData.strings.WebApp_ReloadPage, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reload"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.default)
                
                self?.controllerNode.webView?.reload()
            })))
            
            if let _ = attachMenuBots.firstIndex(where: { $0.peer.id == botId}) {
                items.append(.action(ContextMenuActionItem(text: presentationData.strings.WebApp_RemoveBot, textColor: .destructive, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
                }, action: { [weak self] _, f in
                    f(.default)
                    
                    if let strongSelf = self {
                        let _ = context.engine.messages.removeBotFromAttachMenu(botId: strongSelf.botId).start()
                        strongSelf.dismiss()
                    }
                })))
            }
            
            return ContextController.Items(content: .list(items))
        }
        
        let contextController = ContextController(account: self.context.account, presentationData: self.presentationData, source: .reference(WebAppContextReferenceContentSource(controller: self, sourceNode: node)), items: items, gesture: gesture)
        self.presentInGlobalOverlay(contextController)
    }
    
    override public func loadDisplayNode() {
        self.displayNode = Node(context: self.context, controller: self, present: { [weak self] c, a in
            self?.present(c, in: .window(.root), with: a)
        })
        
        self.navigationBar?.updateBackgroundAlpha(0.0, transition: .immediate)
        self.updateTabBarAlpha(1.0, .immediate)
    }
        
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
    
    override public var presentationController: UIPresentationController? {
        get {
            return nil
        } set(value) {
        }
    }
    
    public var mediaPickerContext: AttachmentMediaPickerContext? {
        return WebAppPickerContext(controller: self)
    }
    
    public func prepareForReuse() {
        self.updateTabBarAlpha(1.0, .immediate)
    }
}

final class WebAppPickerContext: AttachmentMediaPickerContext {
    private weak var controller: WebAppController?
    
    var selectionCount: Signal<Int, NoError> {
        return .single(0)
    }
    
    var caption: Signal<NSAttributedString?, NoError> {
        return .single(nil)
    }
    
    public var loadingProgress: Signal<CGFloat?, NoError> {
        return self.controller?.controllerNode.loadingProgressPromise.get() ?? .single(nil)
    }
    
    public var mainButtonState: Signal<AttachmentMainButtonState?, NoError> {
        return self.controller?.controllerNode.mainButtonStatePromise.get() ?? .single(nil)
    }
        
    init(controller: WebAppController) {
        self.controller = controller
    }
    
    func setCaption(_ caption: NSAttributedString) {
    }
    
    func send(silently: Bool, mode: AttachmentMediaPickerSendMode) {
    }
    
    func schedule() {
    }
    
    func mainButtonAction() {
        self.controller?.controllerNode.mainButtonPressed()
    }
}


private final class WebAppContextReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceNode: ContextReferenceContentNode
    
    init(controller: ViewController, sourceNode: ContextReferenceContentNode) {
        self.controller = controller
        self.sourceNode = sourceNode
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}

public func standaloneWebAppController(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, params: WebAppParameters, openUrl: @escaping (String) -> Void, getInputContainerNode: @escaping () -> (CGFloat, ASDisplayNode, () -> AttachmentController.InputPanelTransition?)? = { return nil }, completion: @escaping () -> Void = {}, dismissed: @escaping () -> Void = {}) -> ViewController {
    let controller = AttachmentController(context: context, updatedPresentationData: updatedPresentationData, chatLocation: .peer(id: params.peerId), buttons: [.standalone], initialButton: .standalone, fromMenu: params.fromMenu)
    controller.getInputContainerNode = getInputContainerNode
    controller.requestController = { _, present in
        let webAppController = WebAppController(context: context, updatedPresentationData: updatedPresentationData, params: params, replyToMessageId: nil)
        webAppController.openUrl = openUrl
        webAppController.completion = completion
        present(webAppController, webAppController.mediaPickerContext)
    }
    controller.dismissed = dismissed
    return controller
}