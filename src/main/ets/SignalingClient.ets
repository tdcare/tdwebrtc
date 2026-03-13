/**
 * WebRTC 信令客户端
 *
 * 完整对齐 Android td-webrtc 的 webRtc.java 信令协议
 * 通过 WebSocket 与信令服务器通信，支持：
 * - 房间管理（join/leave）
 * - SDP/ICE 交换（offer/answer/iceCandidate）
 * - 呼叫控制（call/doing/hangup/transfer/ignore/notice）
 * - 视频呼叫（video_call/video_hangup）
 * - SOS 呼叫（sos/soshangup/video_sos/video_soshangup）
 * - 心跳保活 + 断线重连
 */

import webSocket from '@ohos.net.webSocket';
import { LogUtil } from './utils/LogUtil';

// ============================================================
// 常量定义 — 与 Android CmdAction / CmdType / Constants 对齐
// ============================================================

/** 消息类型（外层 type 字段） */
export class CmdType {
  static readonly TYPE_PING: string = 'ping';
  static readonly TYPE_FORWARD: string = 'forward';
  static readonly TYPE_RTC_DATA: string = 'rtcdata';
}

/** 动作类型（data.action 字段） */
export class CmdAction {
  // 房间管理
  static readonly ACTION_CLIENT_JOIN: string = 'client_join';
  static readonly ACTION_CLIENT_LEAVE: string = 'client_leave';
  static readonly ACTION_CLIENT_JOINED: string = 'client_joined';
  static readonly ACTION_CLIENT_LEAVED: string = 'client_leaved';

  // WebRTC SDP/ICE
  static readonly ACTION_OFFER: string = 'offer';
  static readonly ACTION_ANSWER: string = 'answer';
  static readonly ACTION_ICE_CANDIDATE: string = 'iceCandidate';

  // 语音呼叫控制
  static readonly ACTION_CALL: string = 'call';
  static readonly ACTION_DOING: string = 'doing';
  static readonly ACTION_HANGUP: string = 'hangup';
  static readonly ACTION_TRANSFER: string = 'transfer';
  static readonly ACTION_IGNORE: string = 'ignore';
  static readonly ACTION_NOTICE: string = 'notice';

  // SOS
  static readonly ACTION_SOS_CALL: string = 'sos';
  static readonly ACTION_SOS_HANGUP: string = 'soshangup';

  // 视频呼叫
  static readonly ACTION_VIDEO_CALL: string = 'video_call';
  static readonly ACTION_VIDEO_HANGUP: string = 'video_hangup';
  static readonly ACTION_VIDEO_SOS_CALL: string = 'video_sos';
  static readonly ACTION_VIDEO_SOS_HANGUP: string = 'video_soshangup';
}

/** 通话类型 — 对齐 Android CallType */
export enum CallType {
  VOICE = 'voice',
  VIDEO = 'video',
}

/** 通话类型字段名 */
const KEY_CALL_TYPE: string = 'call_type';

// ============================================================
// 信令消息接口
// ============================================================

/** 信令服务器消息外层结构 */
interface SignalingEnvelope {
  type: string;
  from_mac: string;
  to_mac?: string;
  is_echo: string;
  data?: SignalingData;
  jsonStr?: string;
}

/** 信令消息数据层 */
export interface SignalingData {
  action: string;
  from_mac: string;
  to_mac?: string;
  room_id: string;
  sdp?: string;
  sdpMid?: string;
  sdpMLineIndex?: number;
  msg?: string;
  call_type?: string;
  result?: string;
}

// ============================================================
// 回调接口
// ============================================================

/** 信令事件回调 */
export interface SignalingCallback {
  /** 连接成功 */
  onInitSuccess(): void;

  /** 有对端加入房间 */
  onPeerJoined(fromMac: string, roomId: string): void;

  /** 有对端离开房间 */
  onPeerLeaved(fromMac: string, roomId: string): void;

  /** 收到 Offer */
  onOfferReceived(data: SignalingData): void;

  /** 收到 Answer */
  onAnswerReceived(data: SignalingData): void;

  /** 收到 ICE 候选 */
  onIceCandidateReceived(data: SignalingData): void;

  /** 收到呼叫 */
  onCall(data: SignalingData): void;

  /** 收到接听/处理 */
  onDoing(data: SignalingData): void;

  /** 收到挂断 */
  onHangup(data: SignalingData): void;

  /** 收到转接 */
  onTransfer(data: SignalingData): void;

  /** 收到忽略 */
  onIgnore(data: SignalingData): void;

  /** 收到通知 */
  onNotice(data: SignalingData): void;

  /** 收到 SOS 呼叫 */
  onSosCall(data: SignalingData): void;

  /** 收到 SOS 挂断 */
  onSosHangup(data: SignalingData): void;

  /** 收到视频呼叫 */
  onVideoCall(data: SignalingData): void;

  /** 收到视频挂断 */
  onVideoHangup(data: SignalingData): void;

  /** 收到视频 SOS 呼叫 */
  onVideoSosCall(data: SignalingData): void;

  /** 收到视频 SOS 挂断 */
  onVideoSosHangup(data: SignalingData): void;
}

// ============================================================
// 信令客户端
// ============================================================

const TAG = '[Signaling]';
const PING_MIN_TIME = 3000;
const PING_MAX_TIME = 6000;
const CONNECT_TIMEOUT = 31000;
const MAX_PENDING_QUEUE_SIZE = 1000;

export class SignalingClient {
  private ws: webSocket.WebSocket | null = null;
  private mac: string = '';
  private jsonStr: string = '';
  private socketUrl: string = '';
  private isConnected: boolean = false;
  private callback: SignalingCallback | null = null;

  // 心跳 & 重连
  private pingTimer: number | null = null;
  private reconnectTimer: number | null = null;
  private lastMsgTime: number = 0;

  // 待发送消息队列
  private pendingQueue: string[] = [];

  // 当前通话类型
  private currentCallType: CallType = CallType.VOICE;

  /**
   * 初始化信令连接
   *
   * @param url 信令服务器 URL（不含 MAC 后缀）
   * @param mac 本机设备标识
   * @param jsonStr 扩展信息 JSON
   * @param callback 信令回调
   */
  public init(url: string, mac: string, jsonStr: string, callback: SignalingCallback): void {
    this.mac = mac;
    this.jsonStr = jsonStr;
    this.socketUrl = url + mac;
    this.callback = callback;

    LogUtil.info(`${TAG} 初始化, url=${this.socketUrl}`);
    this.connect();
  }

  /**
   * 建立 WebSocket 连接
   */
  private connect(): void {
    if (this.ws !== null) {
      LogUtil.warn(`${TAG} WebSocket 已存在，跳过重复连接`);
      return;
    }

    this.ws = webSocket.createWebSocket();

    this.ws.on('open', () => {
      LogUtil.info(`${TAG} WebSocket 已连接`);
      this.isConnected = true;
      this.lastMsgTime = Date.now();
      this.startHeartbeat();
      this.flushPendingMessages();
      this.callback?.onInitSuccess();
    });

    this.ws.on('message', (err: Error, value: string | ArrayBuffer) => {
      if (err) {
        LogUtil.error(`${TAG} 消息接收错误: ${err.message}`);
        return;
      }
      if (typeof value === 'string') {
        this.processMessage(value);
      }
    });

    this.ws.on('close', () => {
      LogUtil.info(`${TAG} WebSocket 已关闭`);
      this.isConnected = false;
      this.ws = null;
      this.scheduleReconnect();
    });

    this.ws.on('error', (err: Error) => {
      LogUtil.error(`${TAG} WebSocket 错误: ${err.message}`);
      this.isConnected = false;
      this.ws = null;
      this.scheduleReconnect();
    });

    this.ws.connect(this.socketUrl);
  }

  // ---- 消息处理 ----

  private processMessage(text: string): void {
    let envelope: SignalingEnvelope | null = null;
    try {
      envelope = JSON.parse(text) as SignalingEnvelope;
    } catch (e) {
      LogUtil.warn(`${TAG} JSON 解析失败: ${text}`);
      return;
    }
    if (envelope === null) return;

    const isEcho = envelope.is_echo;
    const data = envelope.data;
    if (data === undefined || data === null) {
      // 可能是心跳回执
      if (isEcho !== '0' && isEcho !== '1') {
        this.lastMsgTime = Date.now();
      }
      return;
    }

    const action = data.action;

    if (isEcho === '0') {
      // 来自其他客户端的消息
      LogUtil.info(`${TAG} 收到客户端消息: action=${action}`);
      this.dispatchClientMessage(action, data);
    } else if (isEcho === '1') {
      // 来自服务器的通知
      LogUtil.info(`${TAG} 收到服务器通知: action=${action}`);
      this.dispatchServerMessage(action, data);
    } else {
      // 服务器回执（心跳等）
      this.lastMsgTime = Date.now();
    }
  }

  private dispatchClientMessage(action: string, data: SignalingData): void {
    if (action === CmdAction.ACTION_OFFER) {
      this.callback?.onOfferReceived(data);
    } else if (action === CmdAction.ACTION_ANSWER) {
      this.callback?.onAnswerReceived(data);
    } else if (action === CmdAction.ACTION_ICE_CANDIDATE) {
      this.callback?.onIceCandidateReceived(data);
    } else if (action === CmdAction.ACTION_CALL) {
      this.callback?.onCall(data);
    } else if (action === CmdAction.ACTION_DOING) {
      this.callback?.onDoing(data);
    } else if (action === CmdAction.ACTION_HANGUP) {
      this.callback?.onHangup(data);
    } else if (action === CmdAction.ACTION_TRANSFER) {
      this.callback?.onTransfer(data);
    } else if (action === CmdAction.ACTION_IGNORE) {
      this.callback?.onIgnore(data);
    } else if (action === CmdAction.ACTION_NOTICE) {
      this.callback?.onNotice(data);
    } else if (action === CmdAction.ACTION_SOS_CALL) {
      this.callback?.onSosCall(data);
    } else if (action === CmdAction.ACTION_SOS_HANGUP) {
      this.callback?.onSosHangup(data);
    } else if (action === CmdAction.ACTION_VIDEO_CALL) {
      this.callback?.onVideoCall(data);
    } else if (action === CmdAction.ACTION_VIDEO_HANGUP) {
      this.callback?.onVideoHangup(data);
    } else if (action === CmdAction.ACTION_VIDEO_SOS_CALL) {
      this.callback?.onVideoSosCall(data);
    } else if (action === CmdAction.ACTION_VIDEO_SOS_HANGUP) {
      this.callback?.onVideoSosHangup(data);
    } else {
      LogUtil.debug(`${TAG} 未处理的 action: ${action}`);
    }
  }

  private dispatchServerMessage(action: string, data: SignalingData): void {
    if (action === CmdAction.ACTION_CLIENT_JOINED) {
      this.callback?.onPeerJoined(data.from_mac, data.room_id);
    } else if (action === CmdAction.ACTION_CLIENT_LEAVED) {
      this.callback?.onPeerLeaved(data.from_mac, data.room_id);
    } else {
      LogUtil.debug(`${TAG} 服务器通知: action=${action}, room=${data.room_id}`);
    }
  }

  // ---- 心跳保活 ----

  private startHeartbeat(): void {
    this.stopHeartbeat();
    const interval = PING_MIN_TIME + Math.floor(Math.random() * (PING_MAX_TIME - PING_MIN_TIME));
    this.pingTimer = setInterval(() => {
      this.sendPing();
    }, interval);
  }

  private stopHeartbeat(): void {
    if (this.pingTimer !== null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  private sendPing(): void {
    // 检查是否超时
    if (Date.now() - this.lastMsgTime >= CONNECT_TIMEOUT) {
      LogUtil.warn(`${TAG} 心跳超时，触发重连`);
      this.closeWebSocket();
      this.scheduleReconnect();
      return;
    }

    const pingMsg = JSON.stringify({
      type: CmdType.TYPE_PING,
      from_mac: this.mac,
      jsonStr: this.jsonStr,
    });
    this.sendRawMessage(pingMsg);
  }

  // ---- 断线重连 ----

  private scheduleReconnect(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer !== null) return;

    const delay = PING_MIN_TIME + Math.floor(Math.random() * (PING_MAX_TIME - PING_MIN_TIME));
    LogUtil.info(`${TAG} ${delay}ms 后尝试重连`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  // ---- 消息发送 ----

  private sendRawMessage(text: string): boolean {
    LogUtil.info(`${TAG} sendRawMessage: isConnected=${this.isConnected}, ws=${this.ws !== null ? 'ok' : 'null'}, msg=${text}`);
    if (this.ws !== null && this.isConnected) {
      this.ws.send(text);
      LogUtil.info(`${TAG} 消息已发送`);
      return true;
    }
    LogUtil.warn(`${TAG} 连接未就绪，消息入队`);
    return this.enqueueMessage(text);
  }

  private enqueueMessage(text: string): boolean {
    if (this.pendingQueue.length >= MAX_PENDING_QUEUE_SIZE) {
      this.pendingQueue.shift();
    }
    this.pendingQueue.push(text);
    LogUtil.debug(`${TAG} 消息入队, 队列长度: ${this.pendingQueue.length}`);
    return true;
  }

  private flushPendingMessages(): void {
    if (this.pendingQueue.length === 0) return;
    LogUtil.info(`${TAG} 发送队列消息, 共 ${this.pendingQueue.length} 条`);
    while (this.pendingQueue.length > 0) {
      const msg = this.pendingQueue.shift();
      if (msg !== undefined && this.ws !== null && this.isConnected) {
        this.ws.send(msg);
      } else if (msg !== undefined) {
        this.pendingQueue.unshift(msg);
        break;
      }
    }
  }

  /**
   * 构造转发消息外层
   */
  private buildForwardEnvelope(toMac: string): SignalingEnvelope {
    const env: SignalingEnvelope = {
      type: CmdType.TYPE_FORWARD,
      from_mac: this.mac,
      to_mac: toMac,
      is_echo: '0',
    };
    return env;
  }

  /**
   * 构造 rtcdata 消息外层
   */
  private buildRtcDataEnvelope(): SignalingEnvelope {
    const env: SignalingEnvelope = {
      type: CmdType.TYPE_RTC_DATA,
      from_mac: this.mac,
      is_echo: '0',
    };
    return env;
  }

  // ============================================================
  // 公开发送方法 — 完全对齐 Android webRtc.java
  // ============================================================

  /** 加入房间 */
  public sendJoinRoom(roomId: string): void {
    LogUtil.info(`${TAG} sendJoinRoom: room_id=${roomId}, from_mac=${this.mac}`);
    const env = this.buildRtcDataEnvelope();
    const data: SignalingData = {
      action: CmdAction.ACTION_CLIENT_JOIN,
      room_id: roomId,
      from_mac: this.mac,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendJoinRoom JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 离开房间 */
  public sendLeaveRoom(roomId: string): void {
    const env = this.buildRtcDataEnvelope();
    const data: SignalingData = {
      action: CmdAction.ACTION_CLIENT_LEAVE,
      room_id: roomId,
      from_mac: this.mac,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送 SDP (offer/answer) */
  public sendSessionDescription(sdp: string, sdpType: string, toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: sdpType, // "offer" 或 "answer"
      sdp: sdp,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      call_type: this.currentCallType,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送 ICE 候选 */
  public sendIceCandidate(sdp: string, sdpMid: string, sdpMLineIndex: number, toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_ICE_CANDIDATE,
      sdpMLineIndex: sdpMLineIndex,
      sdpMid: sdpMid,
      sdp: sdp,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送接听 */
  public sendAnswer(toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_DOING,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送语音呼叫 */
  public sendCall(toMac: string, roomId: string, msg: string): void {
    LogUtil.info(`${TAG} sendCall: from_mac=${this.mac}, to_mac=${toMac}, room_id=${roomId}, msg=${msg}`);
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_CALL,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: msg,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendCall JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 发送挂断 */
  public sendHangup(toMac: string, roomId: string): void {
    LogUtil.info(`${TAG} sendHangup: from_mac=${this.mac}, to_mac=${toMac}, room_id=${roomId}`);
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_HANGUP,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendHangup JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 发送转接 */
  public sendTransfer(toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_TRANSFER,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送忽略 */
  public sendIgnore(toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_IGNORE,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送通知 */
  public sendNotice(toMac: string, roomId: string, msg: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_NOTICE,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: msg,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送 SOS 呼叫 */
  public sendSosCall(toMac: string, roomId: string, msg: string): void {
    LogUtil.info(`${TAG} sendSosCall: from_mac=${this.mac}, to_mac=${toMac}, room_id=${roomId}, msg=${msg}`);
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_SOS_CALL,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: msg,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendSosCall JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 发送 SOS 挂断 */
  public sendSosHangup(toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_SOS_HANGUP,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: '',
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送视频呼叫 */
  public sendVideoCall(toMac: string, roomId: string, msg: string, callType: CallType): void {
    LogUtil.info(`${TAG} sendVideoCall: from_mac=${this.mac}, to_mac=${toMac}, room_id=${roomId}, msg=${msg}, callType=${callType}`);
    this.currentCallType = callType;
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_VIDEO_CALL,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: msg,
      call_type: callType,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendVideoCall JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 发送视频挂断 */
  public sendVideoHangup(toMac: string, roomId: string): void {
    LogUtil.info(`${TAG} sendVideoHangup: from_mac=${this.mac}, to_mac=${toMac}, room_id=${roomId}`);
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_VIDEO_HANGUP,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
    };
    env.data = data;
    const jsonStr = JSON.stringify(env);
    LogUtil.info(`${TAG} sendVideoHangup JSON: ${jsonStr}`);
    this.sendRawMessage(jsonStr);
  }

  /** 发送视频 SOS 呼叫 */
  public sendVideoSosCall(toMac: string, roomId: string, msg: string, callType: CallType): void {
    this.currentCallType = callType;
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_VIDEO_SOS_CALL,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: msg,
      call_type: callType,
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  /** 发送视频 SOS 挂断 */
  public sendVideoSosHangup(toMac: string, roomId: string): void {
    const env = this.buildForwardEnvelope(toMac);
    const data: SignalingData = {
      action: CmdAction.ACTION_VIDEO_SOS_HANGUP,
      room_id: roomId,
      from_mac: this.mac,
      to_mac: toMac,
      msg: '',
    };
    env.data = data;
    this.sendRawMessage(JSON.stringify(env));
  }

  // ---- 状态查询 & 工具 ----

  /** 获取连接状态 */
  public getIsConnected(): boolean {
    return this.isConnected;
  }

  /** 获取本机 MAC */
  public getMac(): string {
    return this.mac;
  }

  /** 设置当前通话类型 */
  public setCurrentCallType(callType: CallType): void {
    this.currentCallType = callType;
  }

  /** 获取当前通话类型 */
  public getCurrentCallType(): CallType {
    return this.currentCallType;
  }

  /** 关闭连接 */
  private closeWebSocket(): void {
    this.stopHeartbeat();
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (e) {
        // 忽略关闭错误
      }
      this.ws = null;
    }
    this.isConnected = false;
  }

  /** 销毁信令客户端 */
  public destroy(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.closeWebSocket();
    this.callback = null;
    this.pendingQueue = [];
    LogUtil.info(`${TAG} 已销毁`);
  }
}
