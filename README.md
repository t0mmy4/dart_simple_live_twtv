> ### ⚠ 本项目不提供Release安装包，请自行编译后运行测试。


<p align="center">
    <img width="128" src="/assets/logo.png" alt="Simple Live logo">
</p>
<h2 align="center">Simple Live</h2>

<p align="center">
简简单单的看直播
</p>

![浅色模式](/assets/screenshot_light.jpg)

![深色模式](/assets/screenshot_dark.jpg)

## 支持直播平台：

- 虎牙直播

- 斗鱼直播

- 哔哩哔哩直播

- 抖音直播

- Twitch `本分支新增`

## 本分支（Fork）说明

> 本分支基于 [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)，在其之上新增与修复如下：

### 新增 Twitch 直播
- 核心库新增 `TwitchSite` 与 Twitch 弹幕（IRC over WebSocket），App / TV / 控制台均已接入分类、热门、搜索、播放与弹幕。
- 无需登录即可观看；可在「设置 → 其他设置」配置可选的「去广告代理」（TTV‑LOL 兼容，默认直连）。
- 支持粘贴 `twitch.tv/<频道>` 链接解析直接打开。

### 修复抖音 / 斗鱼在部分设备闪退
- 抖音 `a_bogus`、斗鱼签名脚本改为**预编译 QuickJS 字节码**加载（运行时不再深度解析脚本），修复部分设备（线程栈较小）打开抖音直播列表 / 斗鱼直播间时的原生闪退。

### 抖音搜索改为「网页内搜索」
- 抖音搜索接口已被风控拦截（`verify_check`，根因是 `msToken` 无法在客户端伪造），登录也无法从接口绕过；改为在 App 内打开抖音网页搜索结果页，点击其中的直播间即在原生播放器中打开。

### 其它
- 「检查更新」指向本仓库（`t0mmy4/dart_simple_live_twtv`）。
- 账号管理：抖音保留 ttwid 配置（用于解锁画质）；Twitch 的「去广告代理」位于「设置 → 其他设置」。

## APP支持平台

- [x] Android
- [x] iOS
- [x] Windows `BETA`
- [x] MacOS `BETA`
- [x] Linux `BETA`
- [x] Android TV `BETA`

## 项目结构

- `simple_live_core` 项目核心库，实现获取各个网站的信息及弹幕。
- `simple_live_console` 基于simple_live_core的控制台程序。
- `simple_live_app` 基于核心库实现的Flutter APP客户端。
- `simple_live_tv_app` 基于核心库实现的Flutter Android TV客户端。

## 环境

Flutter : `3.38`（本分支签名脚本字节码依赖 native assets，建议使用 `3.44+` 并启用 `--enable-native-assets` 编译）

## 参考及引用

[AllLive](https://github.com/xiaoyaocz/AllLive) `本项目的C#版，有兴趣可以看看`

[dart_tars_protocol](https://github.com/xiaoyaocz/dart_tars_protocol.git)

[wbt5/real-url](https://github.com/wbt5/real-url)

[lovelyyoshino/Bilibili-Live-API](https://github.com/lovelyyoshino/Bilibili-Live-API/blob/master/API.WebSocket.md)

[IsoaSFlus/danmaku](https://github.com/IsoaSFlus/danmaku)

[BacooTang/huya-danmu](https://github.com/BacooTang/huya-danmu)

[TarsCloud/Tars](https://github.com/TarsCloud/Tars)

[YunzhiYike/douyin-live](https://github.com/YunzhiYike/douyin-live)

[5ime/Tiktok_Signature](https://github.com/5ime/Tiktok_Signature)

## 声明

本项目的所有功能都是基于互联网上公开的资料开发，无任何破解、逆向工程等行为。

本项目仅用于学习交流编程技术，严禁将本项目用于商业目的。如有任何商业行为，均与本项目无关。

如果本项目存在侵犯您的合法权益的情况，请及时与开发者联系，开发者将会及时删除有关内容。

## Star History

<a href="https://www.star-history.com/#xiaoyaocz/dart_simple_live&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=xiaoyaocz/dart_simple_live&type=Date" />
 </picture>
</a>
