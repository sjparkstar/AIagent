import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ─── Win32 상수 ──────────────────────────────────────────────────────────────

const int _mouseeventfLeftdown = 0x0002;
const int _mouseeventfLeftup = 0x0004;
const int _mouseeventfRightdown = 0x0008;
const int _mouseeventfRightup = 0x0010;
const int _mouseeventfMiddledown = 0x0020;
const int _mouseeventfMiddleup = 0x0040;
const int _mouseeventfWheel = 0x0800;

const int _keyeventfKeyup = 0x0002;
const int _keyeventfExtendedkey = 0x0001;

// 확장 키(0xE0 prefix) VK 목록 — keybd_event의 dwFlags에 KEYEVENTF_EXTENDEDKEY 필요
const Set<int> _extendedKeys = {
  0x25, 0x26, 0x27, 0x28, // Arrow keys
  0x21, 0x22, 0x23, 0x24, // PageUp/Down, End, Home
  0x2D, 0x2E, // Insert, Delete
  0xA2, 0xA3, // Ctrl L/R
  0xA4, 0xA5, // Alt L/R
  0x5B, 0x5C, // Win L/R
};

// DOM KeyboardEvent.code → Windows Virtual-Key 코드 매핑
const Map<String, int> _vkMap = {
  // 알파벳
  'KeyA': 0x41, 'KeyB': 0x42, 'KeyC': 0x43, 'KeyD': 0x44,
  'KeyE': 0x45, 'KeyF': 0x46, 'KeyG': 0x47, 'KeyH': 0x48,
  'KeyI': 0x49, 'KeyJ': 0x4A, 'KeyK': 0x4B, 'KeyL': 0x4C,
  'KeyM': 0x4D, 'KeyN': 0x4E, 'KeyO': 0x4F, 'KeyP': 0x50,
  'KeyQ': 0x51, 'KeyR': 0x52, 'KeyS': 0x53, 'KeyT': 0x54,
  'KeyU': 0x55, 'KeyV': 0x56, 'KeyW': 0x57, 'KeyX': 0x58,
  'KeyY': 0x59, 'KeyZ': 0x5A,
  // 숫자
  'Digit0': 0x30, 'Digit1': 0x31, 'Digit2': 0x32, 'Digit3': 0x33,
  'Digit4': 0x34, 'Digit5': 0x35, 'Digit6': 0x36, 'Digit7': 0x37,
  'Digit8': 0x38, 'Digit9': 0x39,
  // 숫자패드
  'Numpad0': 0x60, 'Numpad1': 0x61, 'Numpad2': 0x62, 'Numpad3': 0x63,
  'Numpad4': 0x64, 'Numpad5': 0x65, 'Numpad6': 0x66, 'Numpad7': 0x67,
  'Numpad8': 0x68, 'Numpad9': 0x69,
  'NumpadMultiply': 0x6A, 'NumpadAdd': 0x6B, 'NumpadSubtract': 0x6D,
  'NumpadDecimal': 0x6E, 'NumpadDivide': 0x6F, 'NumpadEnter': 0x0D,
  // 제어 키
  'Enter': 0x0D, 'Space': 0x20, 'Backspace': 0x08,
  'Tab': 0x09, 'Escape': 0x1B, 'Delete': 0x2E, 'Insert': 0x2D,
  // 방향키 / 탐색
  'ArrowUp': 0x26, 'ArrowDown': 0x28, 'ArrowLeft': 0x25, 'ArrowRight': 0x27,
  'Home': 0x24, 'End': 0x23, 'PageUp': 0x21, 'PageDown': 0x22,
  // 기능 키
  'F1': 0x70, 'F2': 0x71, 'F3': 0x72, 'F4': 0x73,
  'F5': 0x74, 'F6': 0x75, 'F7': 0x76, 'F8': 0x77,
  'F9': 0x78, 'F10': 0x79, 'F11': 0x7A, 'F12': 0x7B,
  // 수정자 키
  'ShiftLeft': 0xA0, 'ShiftRight': 0xA1,
  'ControlLeft': 0xA2, 'ControlRight': 0xA3,
  'AltLeft': 0xA4, 'AltRight': 0xA5,
  'MetaLeft': 0x5B, 'MetaRight': 0x5C,
  // 토글 키
  'CapsLock': 0x14, 'NumLock': 0x90, 'ScrollLock': 0x91,
  // 구두점 / 기호
  'Semicolon': 0xBA, 'Equal': 0xBB, 'Comma': 0xBC,
  'Minus': 0xBD, 'Period': 0xBE, 'Slash': 0xBF,
  'Backquote': 0xC0, 'BracketLeft': 0xDB, 'Backslash': 0xDC,
  'BracketRight': 0xDD, 'Quote': 0xDE,
  // 기타
  'PrintScreen': 0x2C, 'Pause': 0x13, 'ContextMenu': 0x5D,
};

// ─── Win32 FFI 함수 시그니처 ──────────────────────────────────────────────────

typedef _SetCursorPosNative = Int32 Function(Int32 x, Int32 y);
typedef _SetCursorPosDart = int Function(int x, int y);

typedef _GetSystemMetricsNative = Int32 Function(Int32 nIndex);
typedef _GetSystemMetricsDart = int Function(int nIndex);

typedef _MouseEventNative = Void Function(
  Uint32 dwFlags,
  Int32 dx,
  Int32 dy,
  Uint32 dwData,
  IntPtr dwExtraInfo,
);
typedef _MouseEventDart = void Function(
  int dwFlags,
  int dx,
  int dy,
  int dwData,
  int dwExtraInfo,
);

typedef _KeybdEventNative = Void Function(
  Uint8 bVk,
  Uint8 bScan,
  Uint32 dwFlags,
  IntPtr dwExtraInfo,
);
typedef _KeybdEventDart = void Function(
  int bVk,
  int bScan,
  int dwFlags,
  int dwExtraInfo,
);

// ─── 화면 영역 정보 ──────────────────────────────────────────────────────────

class ScreenBounds {
  final int left;
  final int top;
  final int width;
  final int height;
  final double scaleFactor;

  const ScreenBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.scaleFactor = 1.0,
  });
}

// ─── InputHandler ─────────────────────────────────────────────────────────────

class InputHandler {
  // 현재 활성 화면 영역 (뷰어가 source-changed 메시지로 갱신)
  ScreenBounds? _activeBounds;

  late final _SetCursorPosDart _setCursorPos;
  late final _GetSystemMetricsDart _getSystemMetrics;
  late final _MouseEventDart _mouseEvent;
  late final _KeybdEventDart _keybdEvent;

  final bool _isWindows = Platform.isWindows;

  InputHandler() {
    if (!_isWindows) return;

    try {
      final user32 = DynamicLibrary.open('user32.dll');

      _setCursorPos =
          user32.lookupFunction<_SetCursorPosNative, _SetCursorPosDart>(
        'SetCursorPos',
      );
      _getSystemMetrics =
          user32.lookupFunction<_GetSystemMetricsNative, _GetSystemMetricsDart>(
        'GetSystemMetrics',
      );
      _mouseEvent = user32.lookupFunction<_MouseEventNative, _MouseEventDart>(
        'mouse_event',
      );
      _keybdEvent = user32.lookupFunction<_KeybdEventNative, _KeybdEventDart>(
        'keybd_event',
      );
    } catch (e) {
      debugPrint('[input] FFI 초기화 실패: $e');
    }
  }

  // 뷰어가 source-changed 메시지를 보낼 때 호출
  void setActiveBounds(ScreenBounds bounds) {
    _activeBounds = bounds;
    debugPrint('[input] 활성 화면 영역 갱신: '
        '${bounds.left},${bounds.top} ${bounds.width}x${bounds.height} '
        'scale=${bounds.scaleFactor}');
  }

  // DataChannel onMessage 진입점
  Future<void> handleInput(Map<String, dynamic> msg) async {
    if (!_isWindows) {
      debugPrint('[input] Windows 환경 아님 — 무시');
      return;
    }

    final type = msg['type'] as String?;
    try {
      switch (type) {
        case 'mousemove':
          _handleMouseMove(msg);
        case 'mousedown':
          _handleMouseDown(msg);
        case 'mouseup':
          _handleMouseUp(msg);
        case 'scroll':
          _handleScroll(msg);
        case 'keydown':
          _handleKey(msg, isDown: true);
        case 'keyup':
          _handleKey(msg, isDown: false);
        case 'text-input':
          await _handleTextInput(msg);
        case 'clipboard-sync':
          await _handleClipboardSync(msg);
        default:
          debugPrint('[input] 알 수 없는 타입: $type');
      }
    } catch (e) {
      debugPrint('[input] handleInput 오류 (type=$type): $e');
    }
  }

  // ─── 좌표 변환 ─────────────────────────────────────────────────────────────

  // 정규화 좌표(0~1)를 절대 화면 좌표로 변환
  (int, int) _toAbsolute(double nx, double ny) {
    if (_activeBounds != null) {
      final b = _activeBounds!;
      final x = b.left + (nx * b.width / b.scaleFactor).round();
      final y = b.top + (ny * b.height / b.scaleFactor).round();
      return (x, y);
    }
    // activeBounds 없으면 주 모니터 전체 기준
    final screenW = _getSystemMetrics(0); // SM_CXSCREEN = 0
    final screenH = _getSystemMetrics(1); // SM_CYSCREEN = 1
    return ((nx * screenW).round(), (ny * screenH).round());
  }

  // ─── 마우스 핸들러 ─────────────────────────────────────────────────────────

  void _handleMouseMove(Map<String, dynamic> msg) {
    final nx = (msg['x'] as num).toDouble();
    final ny = (msg['y'] as num).toDouble();
    final (x, y) = _toAbsolute(nx, ny);
    _setCursorPos(x, y);
  }

  void _handleMouseDown(Map<String, dynamic> msg) {
    final button = (msg['button'] as num?)?.toInt() ?? 0;
    final flags = switch (button) {
      1 => _mouseeventfMiddledown,
      2 => _mouseeventfRightdown,
      _ => _mouseeventfLeftdown,
    };
    _mouseEvent(flags, 0, 0, 0, 0);
  }

  void _handleMouseUp(Map<String, dynamic> msg) {
    final button = (msg['button'] as num?)?.toInt() ?? 0;
    final flags = switch (button) {
      1 => _mouseeventfMiddleup,
      2 => _mouseeventfRightup,
      _ => _mouseeventfLeftup,
    };
    _mouseEvent(flags, 0, 0, 0, 0);
  }

  void _handleScroll(Map<String, dynamic> msg) {
    final dy = (msg['deltaY'] as num?)?.toInt() ?? 0;
    // Windows WHEEL_DELTA 단위(120) — 뷰어가 이미 120 단위로 보내므로 부호만 반전
    if (dy != 0) {
      _mouseEvent(_mouseeventfWheel, 0, 0, (-dy) & 0xFFFFFFFF, 0);
    }

    // 수평 스크롤은 MOUSEEVENTF_HWHEEL(0x1000)로 처리
    final dx = (msg['deltaX'] as num?)?.toInt() ?? 0;
    if (dx != 0) {
      _mouseEvent(0x1000, 0, 0, dx & 0xFFFFFFFF, 0);
    }
  }

  // ─── 키보드 핸들러 ─────────────────────────────────────────────────────────

  void _handleKey(Map<String, dynamic> msg, {required bool isDown}) {
    final code = msg['code'] as String?;
    if (code == null) return;

    final vk = _vkMap[code];
    if (vk == null) {
      debugPrint('[input] 매핑 없는 키 코드: $code');
      return;
    }

    // keydown 메시지에 modifiers가 있으면 수정자 키를 먼저 누른다
    if (isDown) {
      final mods = (msg['modifiers'] as List?)?.cast<String>() ?? [];
      for (final mod in mods) {
        final modVk = _modifierVk(mod);
        if (modVk != null) _sendKey(modVk, isDown: true);
      }
    }

    _sendKey(vk, isDown: isDown);

    // keyup 시 수정자 키도 해제
    if (!isDown) {
      final mods = (msg['modifiers'] as List?)?.cast<String>() ?? [];
      for (final mod in mods) {
        final modVk = _modifierVk(mod);
        if (modVk != null) _sendKey(modVk, isDown: false);
      }
    }
  }

  void _sendKey(int vk, {required bool isDown}) {
    int flags = isDown ? 0 : _keyeventfKeyup;
    if (_extendedKeys.contains(vk)) flags |= _keyeventfExtendedkey;
    _keybdEvent(vk, 0, flags, 0);
  }

  int? _modifierVk(String modifier) {
    return switch (modifier.toLowerCase()) {
      'control' || 'ctrl' => 0xA2, // VK_LCONTROL
      'shift' => 0xA0, // VK_LSHIFT
      'alt' => 0xA4, // VK_LMENU
      'meta' || 'win' => 0x5B, // VK_LWIN
      _ => null,
    };
  }

  // ─── 텍스트 / 클립보드 핸들러 ──────────────────────────────────────────────

  // 텍스트 입력: 클립보드에 설정 후 Ctrl+V 시뮬레이션
  Future<void> _handleTextInput(Map<String, dynamic> msg) async {
    final text = msg['text'] as String?;
    if (text == null || text.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: text));

    // 잠깐 대기 후 붙여넣기 (클립보드 반영 타이밍 보장)
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _sendKey(0xA2, isDown: true); // Ctrl down
    _sendKey(0x56, isDown: true); // V down
    _sendKey(0x56, isDown: false); // V up
    _sendKey(0xA2, isDown: false); // Ctrl up
  }

  // 클립보드 동기화: 뷰어 클립보드 내용을 호스트 클립보드로 복사
  Future<void> _handleClipboardSync(Map<String, dynamic> msg) async {
    final text = msg['text'] as String?;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    debugPrint('[input] 클립보드 동기화 완료 (${text.length}자)');
  }
}
