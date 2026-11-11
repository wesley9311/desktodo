import Cocoa
import WebKit

// 页面 ↔ 原生：WKScriptMessageHandler 与导航回调
extension AppDelegate {

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = readStore()
        let js = "window.__load && window.__load(\(json));"
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { NSLog("DeskTodo inject error: \(err)") }
        }
        // 读盘过程发生过什么，必须让页面知道——否则用户看到空清单，
        // 会以为"我记的东西没了"，而实际上备份救回来了或者坏文件还留着。
        pushStoreStatus()
        webView.evaluateJavaScript("window.__setManual && window.__setManual(\(manualSize ? "true" : "false"));", completionHandler: nil)
        webView.evaluateJavaScript("window.__setTheme && window.__setTheme('\(themeMode)');", completionHandler: nil)
        webView.evaluateJavaScript("window.__setZoom && window.__setZoom(\(uiZoom));", completionHandler: nil)
        startWeather()
        startSources()

        // 排查用：只有显式带 --dev 启动时才认这些开关。
        // 以前只看 UserDefaults：任何本地进程写一个 dbgWipe 就能让下次启动无确认清空数据，
        // 发行包里留着这种入口等于给自己埋雷。现在 --dev 是第二把钥匙。
        if devMode, UserDefaults.standard.string(forKey: "dbgExport") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.exportViaPage { ok in NSLog("DeskTodo export(dbg run) ok=\(ok)") }
            }
        }

        // 排查用：DESKTODO_REPORT=1 启动时直接摊开某页报告
        var reportArg = devMode ? (ProcessInfo.processInfo.environment["DESKTODO_REPORT"] ?? "") : ""
        // open --args 在部分系统上会被吞掉，所以给一个偏好开关当备用（只生效一次）
        if devMode, let d = UserDefaults.standard.string(forKey: "dbgReport"), !d.isEmpty {
            reportArg = d
            UserDefaults.standard.removeObject(forKey: "dbgReport")
        }
        if let i = CommandLine.arguments.firstIndex(of: "--report"), i + 1 < CommandLine.arguments.count {
            reportArg = CommandLine.arguments[i + 1]
        }
        if !reportArg.isEmpty {
            let t = reportArg
            // 先让权限框、首批数据都落地，再把窗口拉到前台并钉住（截屏核对用）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self = self else { return }
                self.alertUntil = Date().addingTimeInterval(180)
                self.showMain()
                self.webView?.evaluateJavaScript("window.__openReport && window.__openReport('\(t)');", completionHandler: nil)
            }
        }
        // 不抢用户键盘焦点：启动后主动放弃 key window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let w = self.window else { return }
            w.makeFirstResponder(nil)
            if w.isKeyWindow { w.resignKey() }
            self.debugLog("statusItem frame after 0.6s = \(String(describing: self.statusItem?.button?.frame))")
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "save":
            // 写不进去必须让页面知道：否则"我勾完了"和"一个字节都没落盘"同时成立
            if let s = body["payload"] as? String {
                switch writeStore(s) {
                case .ok:
                    break
                case .rejected:
                    // 写不进去必须让页面知道：否则"我勾完了"和"一个字节都没落盘"同时成立
                    webView?.evaluateJavaScript(
                        "window.__saveFail && window.__saveFail();", completionHandler: nil)
                case .conflict(let disk):
                    /* 磁盘上已经是别的实例写的版本。不覆盖它，让页面按磁盘那份重载，
                       并明确说一句"我改的是另一个窗口"——而不是假装自己写成功了。 */
                    NSLog("DeskTodo save: 冲突，页面按磁盘版本重载")
                    let js = "window.__storeConflict && window.__storeConflict(\(disk));"
                    webView?.evaluateJavaScript(js, completionHandler: nil)
                }
            } else {
                NSLog("DeskTodo save: payload 不是字符串，已忽略")
            }

        case "log":
            // 页面侧写日志（排查尺寸/收起这类只在真机才复现的问题）
            debugLog("JS: " + (body["msg"] as? String ?? ""))

        case "resize":
            if let n = body["height"] as? NSNumber {
                let h = CGFloat(truncating: n)
                if !isCollapsed { normalHeight = max(120, h) }
                applyHeight(h, animate: false)
            }
            if let wn = body["width"] as? NSNumber {
                let wd = CGFloat(truncating: wn)
                if wd > 100 { manualW = min(max(wd, minW), maxW) }
            }

        case "resizeStart":
            beginResizeDrag()

        case "resizeDrag":
            // 页面报的是 CSS 像素，视图放大后要折回实际的点
            resizeDrag(edge: body["edge"] as? String ?? "r",
                       dw: CGFloat(truncating: body["dw"] as? NSNumber ?? 0) * uiZoom,
                       dh: CGFloat(truncating: body["dh"] as? NSNumber ?? 0) * uiZoom)

        case "resizeEnd":
            endResizeDrag()

        case "theme":
            themeMode = body["mode"] as? String ?? "auto"

        case "weatherRefresh":
            refreshWeather(force: true)

        case "extRefresh":
            refreshSources()

        case "extAuth":
            // 页面上的"授权"链接：kind 可以是 cal / rem / both
            let kind = body["kind"] as? String ?? "both"
            if kind == "both" {
                requestBoth()
            } else {
                requestSource(kind)
            }

        case "privacy":
            openPrivacyPane(body["pane"] as? String ?? "Privacy_Calendars")

        case "fda":
            openFDA()

        case "collapse":
            setCollapsed(body["value"] as? Bool ?? false)

        case "dragStart":
            beginDrag()

        case "dragMove":
            updateDrag()

        case "alert":
            let title = body["title"] as? String ?? "该做这件事了"
            fireAlert(title)

        case "ack":
            statusItem.button?.contentTintColor = nil

        case "status":
            if let pending = body["pending"] as? NSNumber, pending.intValue > 0 {
                statusItem.button?.title = " \(pending.intValue)"
            } else {
                statusItem.button?.title = ""
            }

        case "menu":
            showMenu()

        case "hide":
            hideToDot()

        case "pick":
            pickPath(mode: body["mode"] as? String ?? "file",
                     callbackId: body["id"] as? String ?? "",
                     startPath: body["start"] as? String ?? "")

        case "open":
            if let p = body["path"] as? String, !p.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
            }

        case "reveal":
            if let p = body["path"] as? String, !p.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }

        case "revealStore":
            NSWorkspace.shared.activateFileViewerSelecting([storeURL])

        case "export":
            exportViaPage { ok in
                self.nativeToast(ok ? "已导出：原始数据 + 一份说明" : "没有导出（已取消或写失败）")
            }

        case "copyDiag":
            copyDiagToPasteboard()

        case "quit":
            NSApp.terminate(nil)

        default:
            break
        }
    }

    // MARK: 数据状态回执

    /// 把"这次读盘怎么了"告诉页面。只有 normal / fresh 不会在界面上留东西。
    func pushStoreStatus() {
        let st = storeStatus
        let kept = st.kept.map { jsString($0) }.joined(separator: ",")
        let js = "window.__storeState && window.__storeState({ state: \(jsString(st.kind.rawValue)), kept: [\(kept)], files: \(storeFiles().count) });"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 清空之后让页面立刻变空，而不是等下次启动
    func reloadEmptyStore() {
        webView?.evaluateJavaScript("window.__load && window.__load(null);", completionHandler: nil)
    }

    /* 反馈用：把诊断信息放进剪贴板。里面只有计数和状态枚举——
       任务内容、日历标题、文件名、app 名一个都不带。
       体验官直接粘进聊天窗口就行，不需要"上传日志"。 */
    func copyDiagToPasteboard() {
        let text = diagnosticText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        nativeToast("诊断信息已复制（不含任何内容）")
    }
}
