# 漫画坞 MangaDock

连 WebDAV 看漫画的 iOS 客户端。自己写的，没广告、没账号、不联网校验，只连你自己的服务器。

## 能干什么

- **WebDAV 浏览**：填服务器地址 + 账号密码，直接按目录翻你的漫画库
- **CBZ / ZIP 直读**：点开即下载到本地缓存（有进度条），自动按自然序排页（第2话 在 第10话 前面）
- **散图文件夹**：一个文件夹里全是 jpg/png 也能当一话读，图片按需下载并缓存
- **翻页阅读器**：左右翻页、点击左右三分之一翻页、点中间调出工具栏
- **条漫模式**：竖向连续滚动
- **进度记忆**：退出记住页码，首页「继续阅读」一键回到上次位置
- **内存友好**：图片按屏幕分辨率降采样，翻页用 UIPageViewController 只保留相邻 3 页

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

产物是**未签名** IPA，用你现有的侧载环境签：

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
├── Core/           WebDAV 无关的模型、缓存、ZIP 解析、图片解码
├── Net/            WebDAV 客户端（PROPFIND / GET / 下载进度 / Basic+Digest 认证）
└── Views/          首页、目录浏览、阅读器、设置
```

ZIP 解析是自己写的（`Core/ZipArchive.swift`），只依赖系统 `Compression`，没有第三方包 —— 云编译不会卡在拉依赖上。
