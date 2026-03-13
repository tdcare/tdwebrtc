# OHPM 发布检查清单

## ✅ 已完成项目

### 1. 包基本信息
- [x] 包名：`tdwebrtc` （符合命名规范）
- [x] 版本：`1.0.0` （语义化版本）
- [x] 描述：详细说明了模块功能
- [x] 许可证：Apache-2.0

### 2. 文件结构
- [x] 主入口文件：`Index.ets`
- [x] 源代码：`src/main/ets/` 下的所有 .ets 文件
- [x] 原生库：`libs/arm64-v8a/libwebrtc_client.so`
- [x] 原生库：`libs/armeabi-v7a/libwebrtc_client.so`
- [x] 原生库：`libs/x86_64/libwebrtc_client.so`
- [x] 文档：`README.md`
- [x] 构建配置：`oh-package.json5`, `build-profile.json5`, `hvigorfile.ts`
- [x] 构建定义：`BUILD.gn`, `package.json`

### 3. oh-package.json5 配置
- [x] name: `tdwebrtc`
- [x] version: `1.0.0`
- [x] description: 详细描述
- [x] main: `Index.ets`
- [x] types: `Index.ets`
- [x] repository: Git 仓库地址
- [x] homepage: 项目主页
- [x] bugs: 问题追踪地址
- [x] keywords: 包含相关关键词
- [x] files: 列出所有必要文件
- [x] ohos: API 版本和 CPU 架构配置
- [x] dependencies: 正确依赖关系

### 4. API 兼容性
- [x] HarmonyOS API Version: 5.0.0 (最低兼容 4.0.0)
- [x] CPU 架构支持: arm64-v8a, armeabi-v7a, x86_64
- [x] 所有 API 符合 HarmonyOS 规范

## 📦 发布命令

```bash
# 1. 打包测试
ohpm pack

# 2. 登录 OHPM
ohpm login

# 3. 发布到公共仓库
ohpm publish

# 或发布私有包
ohpm publish --access restricted
```

## 🧪 测试验证

### 本地测试
```bash
# 1. 打包测试
ohpm pack

# 2. 在测试项目中安装
ohpm install file:../path/to/tdwebrtc-1.0.0.tgz
```

### 使用验证
```typescript
import { WebRTC, createMediaStream, VideoSurface } from 'tdwebrtc';

// 基本功能测试
const success = await WebRTC.init({
  stunServers: ['stun:stun.l.google.com:19302']
});
```

## 🚀 发布后操作

1. 更新 Git 标签
```bash
git tag v1.0.0
git push origin v1.0.0
```

2. 验证发布
- 检查 OHPM 仓库：https://ohpm.openharmony.cn/#/cn/home
- 确认包可以正常安装

## ⚠️ 注意事项

- 保持向后兼容性
- 重大变更需升级主版本号
- 发布前进行全面测试
- 文档与代码保持同步