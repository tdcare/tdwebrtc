/**
 * 摄像头采集模块
 *
 * 使用 HarmonyOS Camera Kit 采集视频帧，支持：
 * - 预览输出到 XComponent Surface（本地预览）
 * - 通过 ImageReceiver 获取原始帧数据（用于 H.264 编码 & RTP 发送）
 *
 * ## 参考官方文档 & 社区案例
 *
 * - OpenHarmony ImageReceiver 官方文档: 使用 JPEG 格式 ImageReceiver 接收预览流
 * - 官方 Camera Kit 标准流程:
 *   1. getCameraManager() → getSupportedCameras()
 *   2. getSupportedOutputCapability(camera, sceneMode)
 *   3. createCameraInput(camera) → cameraInput.open()
 *   4. createPreviewOutput(profile, surfaceId) × 2 (本地预览 + ImageReceiver)
 *   5. createSession(sceneMode) → beginConfig → addInput/Output → commitConfig → start
 *
 * ## 关键实现要点 (来自官方文档)
 *
 * - ImageReceiver 必须使用 JPEG 格式创建 (image.ImageFormat.JPEG)
 * - getComponent 必须使用 ComponentType.JPEG 获取数据
 * - 实际返回的数据是 NV21 格式 (YUV_420_SP)，非 JPEG 压缩
 * - 需要检查 rowStride 与 width 的关系，去除对齐填充
 * - 摄像头输出 NV21，编码器需要 NV12，需交换 UV 分量
 *
 * ## 双路输出架构
 *
 * Camera → Session ┬→ PreviewOutput #1 → XComponent (本地预览)
 *                   └→ PreviewOutput #2 → ImageReceiver → NV21 → NV12 → H.264 编码
 */

import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { LogUtil } from './utils/LogUtil';
import { BusinessError } from '@kit.BasicServicesKit';
import common from '@ohos.app.ability.common';
import { processCameraFrame } from 'libwebrtc_client.so';

// ============================================================
// 采集配置接口
// ============================================================

export interface CameraCaptureConfig {
  width?: number;       // 默认 640
  height?: number;      // 默认 480
  frameRate?: number;   // 默认 30
  cameraPosition?: 'back' | 'front'; // 默认 back
  isLowEndDevice?: boolean; // v26: 低端设备标志
}

interface CameraCaptureDefaults {
  width: number;
  height: number;
  frameRate: number;
  cameraPosition: 'back' | 'front';
  isLowEndDevice: boolean; // v26: 低端设备标志
}

const DEFAULTS: CameraCaptureDefaults = {
  width: 640,
  height: 480,
  frameRate: 30,
  cameraPosition: 'back',
  isLowEndDevice: false, // v26: 默认非低端设备
};

// ============================================================
// 摄像头采集器
// ============================================================

export class CameraCapture {
  private context: common.Context;
  private config: CameraCaptureDefaults;

  // Camera 组件
  private cameraManager: camera.CameraManager | null = null;
  private cameraInput: camera.CameraInput | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  private frameCaptureOutput: camera.PreviewOutput | null = null;
  private session: camera.Session | null = null;

  // 帧获取
  private imageReceiver: image.ImageReceiver | null = null;

  // 实际分辨率
  private actualWidth: number = 0;
  private actualHeight: number = 0;

  private isRunning: boolean = false;
  private frameCount: number = 0;
  private lastFrameLogTime: number = 0;
  // v19: 帧级节流 — 相机 30fps 但 VP8 软编码只能 ~8fps
  // 每帧的 getComponent + processFrameData 耗时 ~5ms，30fps = 150ms/s 主线程时间
  // 节流到 ~14fps 可节省 ~60ms/s，且多余的帧反正会被 MediaStream 丢弃
  private lastProcessedTime: number = 0;
  private frameSkipCount: number = 0;
  // v26: 低端设备动态调整帧间隔
  private readonly FRAME_INTERVAL_MS: number = 100; // 默认 ~10fps (原 70ms/~14fps)
  private readonly LOW_END_FRAME_INTERVAL_MS: number = 150; // 低端设备 ~6.7fps (原 100ms/~10fps)

  /** 视频帧回调：NV12 格式数据 */
  public onVideoFrame?: (nv12Data: ArrayBuffer, width: number, height: number, timestampUs: number) => void;
  public onError?: (error: string) => void;

  constructor(context: common.Context, config?: CameraCaptureConfig) {
    this.context = context;
    this.config = {
      width: config?.width ?? DEFAULTS.width,
      height: config?.height ?? DEFAULTS.height,
      frameRate: config?.frameRate ?? DEFAULTS.frameRate,
      cameraPosition: config?.cameraPosition ?? DEFAULTS.cameraPosition,
      isLowEndDevice: config?.isLowEndDevice ?? DEFAULTS.isLowEndDevice,
    };
  }

  /**
   * 初始化摄像头
   *
   * @param previewSurfaceId XComponent 的 surfaceId，用于本地预览显示
   */
  public async initialize(previewSurfaceId?: string): Promise<boolean> {
    try {
      LogUtil.info(`[CameraCapture] 开始初始化, 预览SurfaceId=${previewSurfaceId ?? 'none'}`);

      // ── 1. 获取 CameraManager ──
      this.cameraManager = camera.getCameraManager(this.context);

      // ── 2. 获取摄像头列表 ──
      const cameras: camera.CameraDevice[] = this.cameraManager.getSupportedCameras();
      if (cameras.length === 0) {
        LogUtil.error('[CameraCapture] 没有可用的摄像头');
        return false;
      }
      LogUtil.info(`[CameraCapture] 发现 ${cameras.length} 个摄像头`);

      // ── 3. 选择摄像头（优先匹配指定方向） ──
      const targetCamera: camera.CameraDevice = this.selectCamera(cameras);
      LogUtil.info(`[CameraCapture] 选择摄像头: ${targetCamera.cameraId}, position=${targetCamera.cameraPosition}`);

      // ── 4. 检测设备支持的场景模式 & 获取输出能力 ──
      const supportedModes: camera.SceneMode[] = this.cameraManager.getSupportedSceneModes(targetCamera);
      LogUtil.info(`[CameraCapture] 设备支持的场景模式: [${supportedModes.join(', ')}]`);

      // 优先使用 NORMAL_PHOTO（兼容性最好），回退到 NORMAL_VIDEO
      let sceneMode: camera.SceneMode = camera.SceneMode.NORMAL_PHOTO;
      if (supportedModes.indexOf(camera.SceneMode.NORMAL_PHOTO) >= 0) {
        sceneMode = camera.SceneMode.NORMAL_PHOTO;
        LogUtil.info('[CameraCapture] 使用 NORMAL_PHOTO 场景模式');
      } else if (supportedModes.indexOf(camera.SceneMode.NORMAL_VIDEO) >= 0) {
        sceneMode = camera.SceneMode.NORMAL_VIDEO;
        LogUtil.info('[CameraCapture] 使用 NORMAL_VIDEO 场景模式');
      } else if (supportedModes.length > 0) {
        sceneMode = supportedModes[0];
        LogUtil.warn(`[CameraCapture] 使用回退场景模式: ${sceneMode}`);
      }

      const capability: camera.CameraOutputCapability =
        this.cameraManager.getSupportedOutputCapability(targetCamera, sceneMode);

      // ── 5. 选择预览 Profile ──
      const previewProfiles: camera.Profile[] = capability.previewProfiles;
      if (previewProfiles.length === 0) {
        LogUtil.error('[CameraCapture] 摄像头无可用预览 Profile');
        return false;
      }
      const previewProfile: camera.Profile = this.selectProfile(previewProfiles);
      this.actualWidth = previewProfile.size.width;
      this.actualHeight = previewProfile.size.height;
      LogUtil.info(`[CameraCapture] 预览 Profile: ${this.actualWidth}x${this.actualHeight}`);

      // ── 6. 创建摄像头输入 & 打开 ──
      this.cameraInput = this.cameraManager.createCameraInput(targetCamera);
      await this.cameraInput.open();
      LogUtil.info('[CameraCapture] 摄像头已打开');

      // ── 7. 创建本地预览输出 ──
      if (previewSurfaceId !== undefined && previewSurfaceId.length > 0) {
        this.previewOutput = this.cameraManager.createPreviewOutput(previewProfile, previewSurfaceId);
        LogUtil.info(`[CameraCapture] 本地预览输出已创建, surfaceId=${previewSurfaceId}`);
      } else {
        LogUtil.warn('[CameraCapture] 未提供预览 SurfaceId，跳过本地预览');
      }

      // ── 8. 创建 ImageReceiver + 帧捕获输出 ──
      await this.setupFrameCapture(previewProfile);

      // ── 9. 创建会话（使用检测到的场景模式） ──
      this.session = this.cameraManager.createSession(sceneMode);
      LogUtil.info(`[CameraCapture] 会话已创建, sceneMode=${sceneMode}`);

      // ── 10. 配置会话：beginConfig → addInput/Output → commitConfig ──
      this.session.beginConfig();

      this.session.addInput(this.cameraInput);
      LogUtil.info('[CameraCapture] 摄像头输入已添加');

      if (this.previewOutput !== null) {
        this.session.addOutput(this.previewOutput);
        LogUtil.info('[CameraCapture] 本地预览输出已添加到会话');
      }

      if (this.frameCaptureOutput !== null) {
        this.session.addOutput(this.frameCaptureOutput);
        LogUtil.info('[CameraCapture] 帧捕获输出已添加到会话');
      }

      await this.session.commitConfig();
      LogUtil.info('[CameraCapture] 会话配置已提交');

      // ── 11. 启动会话 ──
      await this.session.start();
      LogUtil.info(`[CameraCapture] 会话已启动: ${this.actualWidth}x${this.actualHeight}`);

      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      const msg: string = `初始化失败: ${err.message} (code=${err.code})`;
      LogUtil.error(`[CameraCapture] ${msg}`);
      this.onError?.(msg);
      // 清理已创建的资源
      await this.release();
      return false;
    }
  }

  /**
   * 选择摄像头（优先匹配指定位置）
   */
  private selectCamera(cameras: camera.CameraDevice[]): camera.CameraDevice {
    const targetPosition: camera.CameraPosition = this.config.cameraPosition === 'front'
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
    for (let i = 0; i < cameras.length; i++) {
      if (cameras[i].cameraPosition === targetPosition) {
        return cameras[i];
      }
    }
    return cameras[0];
  }

  /**
   * 创建 ImageReceiver 和帧捕获输出
   *
   * 官方文档要求 ImageReceiver 使用 JPEG 格式创建：
   * - image.createImageReceiver(size, image.ImageFormat.JPEG, capacity)
   * - 虽然格式为 JPEG，但摄像头预览流输出的实际数据是 NV21 原始帧
   * - 通过 getComponent(ComponentType.JPEG) 获取帧数据
   */
  private async setupFrameCapture(profile: camera.Profile): Promise<void> {
    if (this.cameraManager === null) {
      return;
    }

    try {
      // 创建 ImageReceiver（官方文档标准：使用 JPEG 格式）
      // v17: capacity 从 8 降到 2，减少缓冲延迟（旧帧在 buffer 中等待的时间更短）
      const receiverSize: image.Size = { width: this.actualWidth, height: this.actualHeight };
      this.imageReceiver = image.createImageReceiver(receiverSize, image.ImageFormat.JPEG, 2);
      LogUtil.info(`[CameraCapture] ImageReceiver 已创建: ${this.actualWidth}x${this.actualHeight}, format=JPEG`);

      // 获取 ImageReceiver 的接收 Surface
      const receiverSurfaceId: string = await this.imageReceiver.getReceivingSurfaceId();
      LogUtil.info(`[CameraCapture] ImageReceiver surfaceId=${receiverSurfaceId}`);

      // 创建帧捕获用的 PreviewOutput（输出到 ImageReceiver）
      this.frameCaptureOutput = this.cameraManager.createPreviewOutput(profile, receiverSurfaceId);
      LogUtil.info('[CameraCapture] 帧捕获 PreviewOutput 已创建');

      // 注册帧到达回调
      this.imageReceiver.on('imageArrival', () => {
        this.handleImageArrival();
      });
      LogUtil.info('[CameraCapture] ImageReceiver 回调已注册');
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      LogUtil.error(`[CameraCapture] 帧捕获设置失败: ${err.message} (code=${err.code})`);
      // 帧捕获失败不阻断初始化，本地预览仍可工作
      this.imageReceiver = null;
      this.frameCaptureOutput = null;
    }
  }

  /**
   * 处理 ImageReceiver 帧到达
   *
   * 官方文档标准流程：
   * 1. readNextImage() 获取图像
   * 2. getComponent(ComponentType.JPEG) 获取原始帧数据
   * 3. 检查 rowStride 与 width 的关系，去除对齐填充
   * 4. 将 NV21 数据转换为 NV12 格式（交换 UV 分量）
   * 5. 通过 onVideoFrame 回调传递给编码器
   */
  private handleImageArrival(): void {
    if (this.imageReceiver === null || !this.isRunning) {
      return;
    }

    this.imageReceiver.readNextImage((readErr: BusinessError, img: image.Image) => {
      if (readErr || img === undefined) {
        if (this.frameCount <= 5) {
          LogUtil.warn(`[CameraCapture] readNextImage 失败: ${readErr?.message ?? 'undefined'}`);
        }
        return;
      }

      this.frameCount++;

      // v19: 帧级节流 — 跳过间隔 <70ms 的帧，避免不必要的 NV12 转换
      // 相机 30fps 但 VP8 编码只能 ~8fps，多余帧会被 MediaStream 丢弃
      // 节流在此处可跳过 getComponent + processFrameData（每帧 ~5ms）
      // v26: 低端设备使用更大的帧间隔 (100ms)，进一步降低 CPU 负载
      const now: number = Date.now();
      const frameInterval: number = this.config.isLowEndDevice 
        ? this.LOW_END_FRAME_INTERVAL_MS 
        : this.FRAME_INTERVAL_MS;
      
      if (now - this.lastProcessedTime < frameInterval) {
        this.frameSkipCount++;
        img.release();
        return;
      }
      this.lastProcessedTime = now;

      const timestampUs: number = Math.floor(this.frameCount * 1000000 / this.config.frameRate);
      const width: number = this.actualWidth;
      const height: number = this.actualHeight;

      // 每3秒打一次帧统计日志
      if (now - this.lastFrameLogTime >= 3000) {
        LogUtil.info(`[CameraCapture] 帧统计: 已捕获${this.frameCount}帧, 跳过${this.frameSkipCount}帧, 处理${this.frameCount - this.frameSkipCount}帧, ${width}x${height}`);
        this.lastFrameLogTime = now;
      }

      // 官方文档: 使用 ComponentType.JPEG 获取预览流数据（实际为 NV21 格式）
      img.getComponent(image.ComponentType.JPEG, (compErr: BusinessError, imgComponent: image.Component) => {
        if (compErr || imgComponent === undefined) {
          if (this.frameCount <= 5) {
            LogUtil.warn(`[CameraCapture] 帧#${this.frameCount}: getComponent 失败: ${compErr?.message ?? 'undefined'}`);
          }
          img.release();
          return;
        }

        if (!imgComponent.byteBuffer) {
          if (this.frameCount <= 5) {
            LogUtil.warn(`[CameraCapture] 帧#${this.frameCount}: byteBuffer 为空`);
          }
          img.release();
          return;
        }

        const stride: number = imgComponent.rowStride;
        const imgWidth: number = img.size.width;
        const imgHeight: number = img.size.height;

        if (this.frameCount <= 3) {
          LogUtil.info(`[CameraCapture] 帧#${this.frameCount}: size=${imgWidth}x${imgHeight}, stride=${stride}, bufLen=${imgComponent.byteBuffer.byteLength}`);
        }

        // v26: 方案 C - 使用 setTimeout(0) 异步执行 NV12 转换
        // 避免阻塞主线程，让 UI 渲染和音频回调优先执行
        setTimeout(() => {
          // 处理 stride 对齐 + NV21→NV12 转换
          const nv12Buffer: ArrayBuffer = this.processFrameData(imgComponent.byteBuffer, imgWidth, imgHeight, stride);

          // 回调
          this.onVideoFrame?.(nv12Buffer, imgWidth, imgHeight, timestampUs);

          // 释放图像资源
          img.release();
        }, 0);
      });
    });
  }

  /**
   * 处理帧数据：去除 stride 对齐填充 + NV21 → NV12 转换
   *
   * 使用 Rust NAPI 高性能实现：
   * - ARM NEON 自动向量化 UV 交换
   * - memcpy 级别的行拷贝
   * - 无 GC / 无 bounds check 开销
   * 预计比 ArkTS 实现快 ~10x
   */
  private processFrameData(srcBuffer: ArrayBuffer, width: number, height: number, stride: number): ArrayBuffer {
    // 调试日志（仅前3帧）
    if (this.frameCount <= 3) {
      const yuvSize: number = Math.floor(width * height * 3 / 2);
      LogUtil.info('[CameraCapture] NV12转换(Rust): ' + width.toString() + 'x' + height.toString() + ', stride=' + stride.toString() + ', yuvSize=' + yuvSize.toString());
    }

    // Rust NAPI: stride 去填充 + NV21→NV12 转换，返回 ArrayBuffer
    const srcView: Uint8Array = new Uint8Array(srcBuffer);
    const nv12Buffer: ArrayBuffer = processCameraFrame(srcView, width, height, stride);

    // 调试日志（仅前2帧）
    if (this.frameCount <= 2) {
      const ySize: number = width * height;
      const uvSize: number = Math.floor(width * height / 2);
      const dstView: Uint8Array = new Uint8Array(nv12Buffer);
      const sampleUv: string[] = [];
      for (let i = 0; i < Math.min(10, uvSize); i += 2) {
        const pair: string = dstView[ySize + i].toString() + ',' + dstView[ySize + i + 1].toString();
        sampleUv.push(pair);
      }
      LogUtil.info('[CameraCapture] NV12 UV样本(前5对): [' + sampleUv.join(', ') + ']');
    }

    return nv12Buffer;
  }

  // ============================================================
  // 启停控制
  // ============================================================

  /**
   * 开始采集
   *
   * 会话在 initialize() 中已启动，此方法只需设置运行状态，
   * 使 ImageReceiver 回调开始处理帧数据。
   */
  public async start(): Promise<boolean> {
    if (this.session === null) {
      LogUtil.error('[CameraCapture] 未初始化，无法启动');
      return false;
    }

    this.isRunning = true;
    this.frameCount = 0;
    LogUtil.info('[CameraCapture] 采集已启动');
    return true;
  }

  /**
   * 停止采集
   */
  public async stop(): Promise<void> {
    this.isRunning = false;

    if (this.session !== null) {
      try {
        await this.session.stop();
        LogUtil.info('[CameraCapture] 会话已停止');
      } catch (error) {
        const err: BusinessError = error as BusinessError;
        LogUtil.warn(`[CameraCapture] 停止异常: ${err.message}`);
      }
    }
  }

  /**
   * 释放所有资源
   */
  public async release(): Promise<void> {
    this.isRunning = false;

    // 1. 停止并释放会话
    if (this.session !== null) {
      try {
        await this.session.stop();
      } catch (_e) { /* ignore */ }
      try {
        await this.session.release();
      } catch (_e) { /* ignore */ }
      this.session = null;
    }

    // 2. 关闭摄像头输入
    if (this.cameraInput !== null) {
      try {
        await this.cameraInput.close();
      } catch (_e) { /* ignore */ }
      this.cameraInput = null;
    }

    // 3. 释放预览输出
    if (this.previewOutput !== null) {
      try {
        await this.previewOutput.release();
      } catch (_e) { /* ignore */ }
      this.previewOutput = null;
    }

    // 4. 释放帧捕获输出
    if (this.frameCaptureOutput !== null) {
      try {
        await this.frameCaptureOutput.release();
      } catch (_e) { /* ignore */ }
      this.frameCaptureOutput = null;
    }

    // 5. 释放 ImageReceiver
    if (this.imageReceiver !== null) {
      try {
        await this.imageReceiver.release();
      } catch (_e) { /* ignore */ }
      this.imageReceiver = null;
    }

    this.cameraManager = null;
    LogUtil.info('[CameraCapture] 所有资源已释放');
  }

  // ============================================================
  // Getters
  // ============================================================

  public getIsRunning(): boolean {
    return this.isRunning;
  }

  public getActualWidth(): number {
    return this.actualWidth;
  }

  public getActualHeight(): number {
    return this.actualHeight;
  }

  public getFrameRate(): number {
    return this.config.frameRate;
  }

  // ============================================================
  // 前后摄像头切换
  // ============================================================

  /**
   * 切换前后摄像头
   *
   * 需要调用方先 stop/release，再用新配置 initialize/start。
   */
  public async switchCamera(): Promise<boolean> {
    const newPosition: 'back' | 'front' = this.config.cameraPosition === 'back' ? 'front' : 'back';
    this.config.cameraPosition = newPosition;
    LogUtil.info(`[CameraCapture] 切换到 ${newPosition} 摄像头`);
    return true;
  }

  // ============================================================
  // Profile 选择
  // ============================================================

  /**
   * 选择最接近目标分辨率的 Profile
   */
  private selectProfile(profiles: camera.Profile[]): camera.Profile {
    let bestProfile: camera.Profile = profiles[0];
    let bestDiff: number = Number.MAX_VALUE;

    for (let i = 0; i < profiles.length; i++) {
      const p: camera.Profile = profiles[i];
      const diff: number = Math.abs(p.size.width - this.config.width) +
        Math.abs(p.size.height - this.config.height);
      if (diff < bestDiff) {
        bestDiff = diff;
        bestProfile = p;
      }
    }

    return bestProfile;
  }
}
