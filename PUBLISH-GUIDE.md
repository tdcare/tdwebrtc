# TD WebRTC 发布到 OpenHarmony 库指南

## 前置准备

### 1. 注册 OpenHarmony 账号

访问 [OpenHarmony 官网](https://www.openharmony.cn/) 注册开发者账号。

### 2. 创建组织命名空间

登录 [OHPM 管理后台](https://ohpm.openharmony.cn/) 创建组织。

### 3. 配置发布密钥

```bash
# 设置私钥路径
ohpm config set key_path "c:\users\tzw\.ssh\tzw-ohpm"

# 发布码：ROBB1D18RX
```

### 4. 必需文件清单

发布前确保以下文件已准备：

| 文件 | 说明 |
|------|------|
| README.md | 使用说明文档，必须包含 `ohpm install xxx` 安装命令 |
| CHANGELOG.md | 变更日志，时间戳需更新为发布日期 |
| LICENSE | 许可证文件 |
| oh-package.json5 | 包配置文件 |
| libs/*.so | Rust 原生库（arm64-v8a, armeabi-v7a, x86_64） |

## 发布步骤

### 步骤 1: 编译 Rust 原生库

```powershell
cd D:\tdcare\tdcareos\tdnis-ohos\tdwebrtc
.\build-rust.ps1
```

确保生成以下文件：
- `libs/arm64-v8a/libwebrtc_client.so`
- `libs/armeabi-v7a/libwebrtc_client.so`
- `libs/x86_64/libwebrtc_client.so`
- `src/types/libwebrtc_client.so.d.ts`

### 步骤 2: 构建 HAR 包

```powershell
# 进入项目根目录
cd D:\tdcare\tdcareos\tdnis-ohos

# 使用 DevEco Studio 自带的 hvigor 构建
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHar --mode module -p module=tdwebrtc@default
```

构建完成后，HAR 包位于：
```
tdwebrtc/build/default/outputs/default/tdwebrtc.har
```

### 步骤 3: 发布到 OHPM

```powershell
cd D:\tdcare\tdcareos\tdnis-ohos\tdwebrtc
ohpm publish build\default\outputs\default\tdwebrtc.har
```

发布过程中会提示输入私钥密码。

### 步骤 4: 验证发布

发布成功后，可在以下地址查看包状态：
https://ohpm.openharmony.cn/#/cn/personalCenter/package

## 实际发布记录

### tdwebrtc@1.0.0 发布详情

```
=== Harball Contents ===
611B     CHANGELOG.md
1.2kB    Index.d.ets
11.1kB   LICENSE
5.9kB    README.md
1.2kB    ResourceTable.txt
1.0kB    oh-package.json5
249.8kB  ets/modules.abc
193.3kB  ets/sourceMaps.map
4.8MB    libs/arm64-v8a/libwebrtc_client.so
3.9MB    libs/armeabi-v7a/libwebrtc_client.so
5.0MB    libs/x86_64/libwebrtc_client.so
666B     src/main/module.json
1.3kB    src/main/ets/AudioCapture.d.ets
1.7kB    src/main/ets/AudioPlayback.d.ets
4.6kB    src/main/ets/CameraCapture.d.ets
3.2kB    src/main/ets/MediaCodec.d.ets
10.2kB   src/main/ets/MediaStream.d.ets
6.4kB    src/main/ets/SignalingClient.d.ets
2.8kB    src/main/ets/VideoDecoderH264.d.ets
2.0kB    src/main/ets/VideoDecoderVP8.d.ets
2.3kB    src/main/ets/VideoSurface.d.ets
9.4kB    src/main/ets/WebRTCAdapter.d.ets
16.1kB   src/main/ets/WebRTCManager.d.ets
1.7kB    src/main/ets/entity/constraint.d.ets
1.3kB    src/main/ets/utils/Base64Util.d.ets
185B     src/main/ets/utils/Index.d.ets
2.7kB    src/main/ets/utils/LogUtil.d.ets
11.5kB   src/main/ets/utils/NetworkUtil.d.ets
2.7kB    src/main/ets/utils/PermissionUtil.d.ets
6.6kB    src/main/ets/utils/StrUtil.d.ets
109B     src/main/resources/base/element/string.json

=== Harball Details ===
name:           tdwebrtc
version:        1.0.0
filename:       tdwebrtc-1.0.0.har
package size:   6.4 MB
unpacked size:  14.2 MB
total files:    31
```

## 使用方式

### 安装

```bash
ohpm install tdwebrtc
# 或简写
ohpm i tdwebrtc
```

### 在项目中引用

在 `oh-package.json5` 中添加：

```json5
{
  "dependencies": {
    "tdwebrtc": "^1.0.0"
  }
}
```

### 代码示例

```typescript
import { WebRTC, createMediaStream, VideoSurface, RemoteVideoSurface } from 'tdwebrtc';
import type { SurfaceInfo, MediaStreamConfig } from 'tdwebrtc';

// 初始化 WebRTC
const success = await WebRTC.init({
  stunServers: ['stun:stun.l.google.com:19302'],
  localPort: 0,
});

// 创建媒体流
const mediaStream = createMediaStream({
  video: { enabled: true, width: 1280, height: 720, codec: 'H264' },
  audio: { enabled: true, sampleRate: 8000, codec: 'PCMU' },
}, context);

// 设置视频 Surface
mediaStream.setLocalVideoSurface(localSurfaceId);
mediaStream.setRemoteVideoSurface(remoteSurfaceId);

// 启动媒体流
await mediaStream.startSending();
await mediaStream.startReceiving();
```

## 版本更新流程

```bash
# 1. 修改 oh-package.json5 中的 version
# 2. 更新 CHANGELOG.md 时间戳和变更内容
# 3. 如有 Rust 代码变更，重新编译
.\build-rust.ps1

# 4. 构建 HAR
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHar --mode module -p module=tdwebrtc@default

# 5. 发布新版本
ohpm publish build\default\outputs\default\tdwebrtc.har

# 6. 打 Git 标签
git tag v1.0.0
git push origin v1.0.0
```

## 常见问题

### Q: 构建时报错 "Cannot find hvigor executable"

A: 使用 DevEco Studio 自带的 hvigor：
```powershell
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHar --mode module -p module=tdwebrtc@default
```

### Q: 发布时报错 "key_path is empty or not found"

A: 配置发布密钥路径：
```bash
ohpm config set key_path "c:\users\tzw\.ssh\tzw-ohpm"
```

### Q: 编译报错 "Exported variable has or is using name from external module but cannot be named"

A: 需要导出相关类型。例如：
```typescript
// 将 interface CachedIceCandidate 改为
export interface CachedIceCandidate { ... }
```

### Q: 发布警告 "har file contains source code"

A: 这是正常警告，HAR 包含 sourceMaps.map 文件，不影响发布。如需移除，可在构建配置中禁用 sourceMap。

### Q: 发布失败 "Package name already exists"

A: 需要升级版本号：
```json5
{
  "version": "1.0.1"
}
```

## 注意事项

### 1. Native 库大小

- 每个架构的 `.so` 文件建议不超过 10MB
- 如果文件过大，考虑优化 Rust 代码或使用动态加载

### 2. 许可证要求

- Apache-2.0 是开源友好的许可证
- 确保 Rust 依赖 (webrtc-rs/rtc) 的许可证兼容

### 3. API 兼容性

- 保持主版本号稳定时，不要破坏已有 API
- 重大变更请升级主版本号

### 4. 文档完整性

- README.md 必须包含 `ohpm install xxx` 安装命令
- 提供 API 参考和示例代码
- 说明依赖和前置条件

## 参考资料

- [OHPM 官方文档](https://developer.harmonyos.com/cn/docs/documentation/doc-guides-V1/ohpm-cli-V1)
- [OpenHarmony 应用开发](https://developer.harmonyos.com/cn/docs/documentation/doc-references-V5/overview-0000001745697524)
- [ohpm 命令行工具](https://ohpm.openharmony.cn/#/cn/help/help)
