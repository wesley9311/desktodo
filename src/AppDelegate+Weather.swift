import Cocoa
import WebKit

// 天气：IP 定位 + open-meteo，全 HTTPS、不要 key、不弹权限
extension AppDelegate {

    // MARK: 天气（IP 定位 + open-meteo：全 HTTPS、不要 key、不弹权限）

    /// 城市来源：自动（IP）/ 手动。没存过就按自动算
    var weatherAuto: Bool {
        if UserDefaults.standard.object(forKey: "wxAuto") == nil { return true }
        return UserDefaults.standard.bool(forKey: "wxAuto")
    }

    /// 关掉联网。这一条不是"天气可选"，而是**整个 app 唯一的外部连接**的闸门。
    /// 打开它之后，进程一次网络请求都不会发——这一点可以用 lsof 当场验证，
    /// 不需要相信任何人（README 里有那条命令）。
    var weatherOffline: Bool { UserDefaults.standard.bool(forKey: "wxOff") }

    /// 网页加载完成后才启动：先贴缓存（秒出），再在后台更新
    func startWeather() {
        if weatherOffline {
            injectWeather("{\"off\":true}")
            return
        }
        if let cached = UserDefaults.standard.string(forKey: "wxJSON"), !cached.isEmpty {
            injectWeather(cached)
        }
        refreshWeather(force: false)
        startWeatherTimer()
    }

    /// 半小时一轮。以前只在 startWeather 里建，于是"启动时就是离线、之后才恢复联网"
    /// 的用户永远不会有定时刷新。抽出来给 toggleOffline 用。
    func startWeatherTimer() {
        guard weatherTimer == nil else { return }
        let t = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refreshWeather(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        weatherTimer = t
    }

    func injectWeather(_ json: String) {
        webView?.evaluateJavaScript("window.__onWeather && window.__onWeather(\(json));", completionHandler: nil)
    }

    /// 半小时刷一次；force = 用户点了温度胶囊
    func refreshWeather(force: Bool) {
        if weatherOffline { return }        // 闸门在这一行：关掉之后没有任何请求能出去
        if weatherBusy { return }
        let last = UserDefaults.standard.double(forKey: "wxAt")
        if !force, last > 0, Date().timeIntervalSince1970 - last < 1500 { return }
        weatherBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let dict = self.fetchWeather()
            DispatchQueue.main.async {
                self.weatherBusy = false
                // 请求在途时用户可能刚勾上「不联网」：这时不许把结果推回界面，
                // 也不许写回缓存——留着旧温度等于让人以为它还在更新。
                guard !self.weatherOffline else { return }
                guard let dict = dict,
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let s = String(data: data, encoding: .utf8) else { return }
                UserDefaults.standard.set(s, forKey: "wxJSON")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wxAt")
                self.injectWeather(s)
            }
        }
    }

    /// 全 app 唯一的网络出口。闸门放在第一行：
    /// 勾上「不联网」之后，连"手动改天气城市"这条路径也不许发请求——
    /// README 教用户用 lsof 验证这件事，验证方法不能有一条后门。
    func httpJSON(_ url: String, timeout: TimeInterval = 8) -> Any? {
        guard !weatherOffline else { return nil }
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue("DeskTodo/1.0", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        var out: Any?
        let sem = DispatchSemaphore(value: 0)
        // ephemeral：不落 cookie、不落磁盘缓存。这样 SECURITY 里那句
        // "没有 cookie、没有标识符" 才是实现事实，而不是只靠天气接口不设 cookie。
        Self.weatherSession.dataTask(with: req) { data, _, _ in
            if let data = data { out = try? JSONSerialization.jsonObject(with: data) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }

    private static let weatherSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg)
    }()

    func fetchWeather() -> [String: Any]? {
        var lat = UserDefaults.standard.double(forKey: "wxLat")
        var lon = UserDefaults.standard.double(forKey: "wxLon")
        var city = UserDefaults.standard.string(forKey: "wxCity") ?? ""

        // 位置只认一次：拿到坐标就存着，之后只刷天气，不再频繁打定位接口
        if lat == 0 && lon == 0 {
            guard let o = httpJSON("https://ipwho.is/?lang=zh-CN") as? [String: Any],
                  (o["success"] as? Bool) == true,
                  let la = o["latitude"] as? Double,
                  let lo = o["longitude"] as? Double else { return nil }
            lat = la
            lon = lo
            city = (o["city"] as? String) ?? ""
            UserDefaults.standard.set(lat, forKey: "wxLat")
            UserDefaults.standard.set(lon, forKey: "wxLon")
            UserDefaults.standard.set(city, forKey: "wxCity")
        }

        let u = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            + "&timezone=auto&forecast_days=1"
        guard let o = httpJSON(u) as? [String: Any],
              let cur = o["current"] as? [String: Any] else { return nil }
        let daily = o["daily"] as? [String: Any] ?? [:]
        func num(_ k: String) -> Double { (cur[k] as? Double) ?? 0 }

        var out: [String: Any] = [
            "city": city,
            "temp": num("temperature_2m"),
            "feels": num("apparent_temperature"),
            "hum": num("relative_humidity_2m"),
            "code": (cur["weather_code"] as? Int) ?? 0,
            "isDay": ((cur["is_day"] as? Int) ?? 1) == 1,
            "at": Int(Date().timeIntervalSince1970)
        ]
        if let a = daily["temperature_2m_max"] as? [Double], let v = a.first { out["tmax"] = v }
        if let a = daily["temperature_2m_min"] as? [Double], let v = a.first { out["tmin"] = v }
        if let a = daily["precipitation_probability_max"] as? [Double], let v = a.first { out["rain"] = v }
        return out
    }

    // MARK: 外观（浅色 / 深色 / 跟随系统）

    /// 菜单里那个"不联网"开关。打开时把缓存的天气一起删掉——
    /// 留着一个旧温度，等于让人以为它还在更新。
    @objc func toggleOffline() {
        let on = !weatherOffline
        UserDefaults.standard.set(on, forKey: "wxOff")
        if on {
            for k in ["wxJSON", "wxAt"] { UserDefaults.standard.removeObject(forKey: k) }
            injectWeather("{\"off\":true}")
            nativeToast("已断网：天气停更，进程不再发任何请求")
        } else {
            nativeToast("恢复联网：只请求天气，本地数据一个字节都不传")
            startWeatherTimer()
            refreshWeather(force: true)
        }
    }

    // MARK: 手动指定天气城市（IP 落在代理出口时兜底）

    @objc func useAutoCity() {
        for k in ["wxLat", "wxLon", "wxCity", "wxAt"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "wxAuto")
        refreshWeather(force: true)
        nativeToast("已改回自动定位，正在重找位置")
    }

    @objc func askWeatherCity() {
        let alert = NSAlert()
        alert.messageText = "天气城市"
        alert.informativeText = "填城市名，比如「杭州」「成都」。留空则恢复自动定位。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = UserDefaults.standard.string(forKey: "wxCity") ?? ""
        tf.placeholderString = "城市名"
        alert.accessoryView = tf
        alert.window.initialFirstResponder = tf

        suppressCount += 1
        let resp = alert.runModal()
        suppressCount = max(0, suppressCount - 1)
        guard resp == .alertFirstButtonReturn else { return }

        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if weatherOffline {
            nativeToast("现在是「不联网」状态，先恢复联网再改城市")
            return
        }
        if name.isEmpty {
            for k in ["wxLat", "wxLon", "wxCity", "wxAt"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
            UserDefaults.standard.set(true, forKey: "wxAuto")
            refreshWeather(force: true)
            nativeToast("留空了，改回自动定位")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let url = "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=zh&format=json"
            let o = self.httpJSON(url) as? [String: Any]
            let first = (o?["results"] as? [[String: Any]])?.first
            guard let la = first?["latitude"] as? Double,
                  let lo = first?["longitude"] as? Double else {
                DispatchQueue.main.async { self.nativeToast("没找到「\(name)」，换个写法试试") }
                return
            }
            let cn = (first?["name"] as? String) ?? name
            DispatchQueue.main.async {
                UserDefaults.standard.set(la, forKey: "wxLat")
                UserDefaults.standard.set(lo, forKey: "wxLon")
                UserDefaults.standard.set(cn, forKey: "wxCity")
                UserDefaults.standard.set(false, forKey: "wxAuto")
                UserDefaults.standard.set(0, forKey: "wxAt")
                self.refreshWeather(force: true)
                self.nativeToast("天气城市已设为 \(cn)")
            }
        }
    }

    func nativeToast(_ text: String) {
        let safe = text.replacingOccurrences(of: "\\", with: "\\\\")
                      .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__toast && window.__toast('\(safe)');", completionHandler: nil)
    }
}
