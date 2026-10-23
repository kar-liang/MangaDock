# 漫画坞 MangaDock

连 WebDAV 看漫画的 iOS 客户端。自己写的，没广告、没账号、不联网校验，只连你自己的服务器。

最低 **iOS 18**；在 **iOS 26** 上自动使用 Liquid Glass（底栏、工具栏、阅读器悬浮条由系统渲染玻璃）。
界面全部是原生 SwiftUI + UIKit（`UIPageViewController` 翻页、`Core Image` 增强），没有第三方框架。

## 能干什么

- **底栏三个标签**：书架 / 阅读记录 / 设置
- **WebDAV 浏览**：填服务器地址 + 账号密码，直接按目录翻你的漫画库
- **列表 / 网格两种视图**：右上角一键切换，网格带封面缩略图（2:3 卡片）
- **CBZ / ZIP 直读**：点开即下载到本地缓存（有进度条），自动按自然序排页（第2话 在 第10话 前面）
- **散图文件夹**：一个文件夹里全是 jpg/png 也能当一话读，图片按需下载并缓存
- **翻页阅读器**：左右滑动；点左/右三分之一翻页，点中间收起工具栏；工具栏隐藏后任意点击恢复
- **条漫模式**：竖向连续滚动，点页面本身切换工具栏
- **画质增强**：阅读器右上角 `✨` 开关，本地 GPU 做 2 倍 Lanczos 上采样 + 锐化（见下）
- **进度记忆**：退出记住页码，「记录」标签里带进度条，点一下回到上次位置
- **内存友好**：图片按屏幕分辨率降采样，翻页只保留相邻 3 页；增强结果按页缓存

### 网格封面怎么来的（不整本下载）

覆盖三层策略，逐层降级：

1. 这本书已经读过（本地有缓存）→ 直接从本地 CBZ 里取第一页
2. 是散图文件夹 → 取文件夹里第一张图
3. 远程 CBZ 且没缓存 → **HTTP Range 只读压缩包尾部**，解析 EOCD / 中央目录拿到第一张图的偏移，
   再按 Range 取那一页的压缩数据解压成缩略图

第 3 步要求服务器支持 `Range` 请求（nginx dav、Alist、群晖都支持）。服务器不支持时会退化成
带书名和文件大小的占位卡片，**不会**为了显示封面去下载整本。封面缓存在 `Caches/MangaDock/covers`。

## 画质增强

阅读器右上角 `✨` 开关。引擎分两级，本地跑，不联网：

| 引擎 | 触发条件 | 代价 |
|---|---|---|
| **Metal 边缘导向放大**（默认） | 总是可用 | 一页几十到一两百毫秒，零体积 |
| **Core ML 超分模型** | 把 `SuperResolution.mlmodelc` 放进 target | 一页 0.5~3 秒，体积 +20~60MB |

### Metal 引擎做了什么

不是「Lanczos 放大 + 锐化」。那套的问题在于 Lanczos 会**跨过边缘**做混合 —— 一条 1 像素的墨线被摊成 1.5 像素的灰带，
再叠 unsharp mask 只会给线条镶一圈光晕。

这里是 Anime4K 的思路：

1. 用 Sobel 算每个像素的梯度方向，判断这条边是横的、竖的还是斜的；
2. **沿边缘方向**插值，**跨边缘方向**保持最近邻 —— 所以线条宽度不变，不会被摊灰；
3. 按梯度幅值识别线稿，只对已经是暗色的描边做加深（`线条加黑`），
   并把描边的灰色过渡压向黑白两端（`细化线条`）。整图无差别锐化会出光晕，这个不会。

设置页两个滑块实时调参，改完重开漫画生效。

着色器在运行时从 Swift 字符串编译（`makeLibrary(source:)`），所以仓库里没有 `.metal` 文件，
XcodeGen 不用加任何配置，**着色器写错也不会导致编译失败** —— 最坏情况是自动降级回 Lanczos。

### 接真·AI 超分

```swift
// Core/ImageEnhancer.swift
static var coreMLModelURL: URL? {
    Bundle.main.url(forResource: "SuperResolution", withExtension: "mlmodelc")
}
```

把编译好的 Core ML 模型命名成 `SuperResolution.mlmodelc` 放进 target，重新构建即生效，
设置页的「当前引擎」会自动变成「Core ML 超分模型（已安装）」。

推理走 Vision（`VNCoreMLRequest`），不用手搓 `CVPixelBuffer` 和猜张量名 —— Vision 负责颜色空间、
缩放和输入格式。模型只暴露 multiArray 张量时它会抛错，自动退回 Metal 引擎。

候选模型：waifu2x / Real-ESRGAN 的 **anime** 版（对线稿友好；通用照片模型会把网点纸糊成噪点）。
注意 `computeUnits = .all` 会走 ANE，这是 2× 模型能压进几百毫秒的关键。

**AI 上色**没有内置。它同样依赖模型（漫画上色专用 GAN 或云端接口），手机上对黑白线稿的上色质量
普遍不稳，一页要几秒到几十秒。要做的话优先走云端接口（可插拔 provider + 你自己的 API key），
不适合塞进当前这个纯本地、零依赖的架构里。


## 不支持的

| 格式 | 状态 |
|---|---|
| CBZ / ZIP | 支持 |
| 图片文件夹 | 支持 |
| CBR / RAR | 不支持（先转 CBZ） |
| PDF | 不支持 |
| 加密 ZIP | 不支持 |
| ZIP64（>4GB 或 >65535 个文件） | 不支持 |

## 构建

没有 Mac 也能出 IPA —— 编译跑在 GitHub Actions 的 macOS runner 上。

推送到 `main` 或手动触发 `Build IPA` workflow，产物在 Actions 页面的 **Artifacts → MangaDock-ipa**。

本地有 Mac 的话：

```bash
brew install xcodegen
xcodegen generate
open MangaDock.xcodeproj
```

## 安装（侧载）

产物是**未签名** IPA，用你现有的侧载环境签。要求设备系统 **iOS 18 或更高**（iOS 26 自动上液体玻璃）：

1. **SideStore / AltStore**：下载 `MangaDock.ipa` → App 内安装 → 它会用你的 Apple ID 证书现场签名
2. **LiveContainer**：直接把 ipa 丢进去运行

首次打开如果连不上，检查：

- 服务器地址是否指向**漫画目录**（不是站点根）
- 局域网地址在 Wi-Fi 下能不能访问（`http://IP:端口/dav/...`）
- 账号密码是否是 WebDAV 专用账号

## 项目结构

```
MangaDock/
├── App/            入口 + 根视图
├── Core/           模型、缓存、ZIP 解析、封面、图片解码与增强
├── Net/            WebDAV 客户端、Range 读远程 ZIP
└── Views/          底栏、书架、记录、浏览、阅读器、设置、网格
```

ZIP 解析是自己写的（`Core/ZipArchive.swift`），只依赖系统 `Compression`，没有第三方包 —— 云编译不会卡在拉依赖上。

## 版本

| 版本 | 内容 |
|---|---|
| 1.0 | WebDAV 浏览、CBZ 直读、翻页/条漫、进度记忆 |
| 1.1 | 缩略图网格（Range 取封面）、修复工具栏隐藏后无法恢复 |
| 1.2 | iOS 26 液体玻璃 + 底栏三标签、GPU 画质增强、Core ML 模型接入点 |

