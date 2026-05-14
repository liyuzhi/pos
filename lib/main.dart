import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class WindowsWindowController {
  WindowsWindowController._();

  static final instance = WindowsWindowController._();
  static const _channel = MethodChannel('pos/window');

  Future<bool> enterFullscreen() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('enterFullscreen') ?? false;
  }

  Future<bool> exitFullscreen() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('exitFullscreen') ?? false;
  }

  Future<bool> isFullscreen() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isFullscreen') ?? false;
  }

  Future<Rect?> getWindowRect() async {
    if (!Platform.isWindows) return null;

    final rect = await _channel.invokeMethod<List<dynamic>>('getWindowRect');
    if (rect == null || rect.length != 4) return null;

    return Rect.fromLTRB(
      (rect[0] as int).toDouble(),
      (rect[1] as int).toDouble(),
      (rect[2] as int).toDouble(),
      (rect[3] as int).toDouble(),
    );
  }
}

class KeyboardManager {
  KeyboardManager._();

  static final instance = KeyboardManager._();

  static const _defaultSuppressDuration = Duration(milliseconds: 500);

  final bottomInset = ValueNotifier<double>(0);

  DateTime? _autoShowSuppressedUntil;
  Future<void>? _activeHide;
  Timer? _keyboardInsetTimer;
  _KeyboardIntent _latestIntent = _KeyboardIntent.hide;
  int _intentGeneration = 0;

  bool get _isAutoShowSuppressed {
    final suppressedUntil = _autoShowSuppressedUntil;
    if (suppressedUntil == null) return false;
    if (DateTime.now().isBefore(suppressedUntil)) return true;

    _autoShowSuppressedUntil = null;
    return false;
  }

  /// 在路由切换或手动收起键盘时短暂禁止自动弹起，防止焦点恢复导致乱弹。
  void suppressAutoShow([
    Duration duration = _defaultSuppressDuration,
  ]) {
    _autoShowSuppressedUntil = DateTime.now().add(duration);
    _markIntent(_KeyboardIntent.hide);
  }

  int _markIntent(_KeyboardIntent intent) {
    _latestIntent = intent;
    _intentGeneration += 1;
    return _intentGeneration;
  }

  /// 打开Windows触摸键盘
  Future<void> showKeyboard({bool force = false}) async {
    if (!Platform.isWindows) return;
    if (!force && _isAutoShowSuppressed) {
      _markIntent(_KeyboardIntent.hide);
      return;
    }
    if (force) {
      _autoShowSuppressedUntil = null;
    }

    final generation = _markIntent(_KeyboardIntent.show);

    try {
      await SystemChannels.textInput.invokeMethod('TextInput.show');
      await Process.start(
        r'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe',
        const [],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {}

    if (_latestIntent == _KeyboardIntent.show &&
        generation == _intentGeneration) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (_latestIntent == _KeyboardIntent.show &&
          generation == _intentGeneration) {
        await refreshKeyboardInset();
        _startKeyboardInsetPolling();
      }
    }

    if (_latestIntent == _KeyboardIntent.hide &&
        generation != _intentGeneration) {
      await _hideKeyboardNow(_intentGeneration);
    }
  }

  /// 真正关闭Windows触摸键盘
  Future<void> hideKeyboard({
    bool clearFocus = true,
    bool suppressAutoShow = false,
    Duration? suppressDuration,
  }) async {
    bottomInset.value = 0;
    _stopKeyboardInsetPolling();

    if (suppressAutoShow) {
      this.suppressAutoShow(suppressDuration ?? _defaultSuppressDuration);
    } else {
      _markIntent(_KeyboardIntent.hide);
    }

    if (clearFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    final hideFuture = _hideKeyboardNow(_intentGeneration);
    _activeHide = hideFuture;

    try {
      await hideFuture;
    } finally {
      if (identical(_activeHide, hideFuture)) {
        _activeHide = null;
      }
    }
  }

  Future<void> waitForPendingHide() async {
    await _activeHide;
  }

  Future<void> refreshKeyboardInset() async {
    if (!Platform.isWindows) {
      bottomInset.value = 0;
      return;
    }

    final appRect = await WindowsWindowController.instance.getWindowRect();
    if (appRect == null) {
      bottomInset.value = 0;
      return;
    }

    bottomInset.value =
        _WindowsTouchKeyboardApi.instance.dockedBottomInsetFor(appRect);
  }

  void _startKeyboardInsetPolling() {
    _keyboardInsetTimer?.cancel();
    _keyboardInsetTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) async {
        if (_latestIntent != _KeyboardIntent.show) {
          _stopKeyboardInsetPolling();
          return;
        }

        await refreshKeyboardInset();
      },
    );
  }

  void _stopKeyboardInsetPolling() {
    _keyboardInsetTimer?.cancel();
    _keyboardInsetTimer = null;
  }

  Future<void> _hideKeyboardNow(int generation) async {
    try {
      /// Flutter层隐藏
      await SystemChannels.textInput.invokeMethod('TextInput.hide');
      if (!_isCurrentHide(generation)) return;

      /// 清理Flutter TextInputClient
      await SystemChannels.textInput.invokeMethod('TextInput.clearClient');
    } catch (_) {}

    if (!Platform.isWindows) return;
    if (!_isCurrentHide(generation)) return;

    try {
      /// 等待focus detach完成
      await Future.delayed(const Duration(milliseconds: 80));
      if (!_isCurrentHide(generation)) return;

      _WindowsTouchKeyboardApi.instance.closeTouchKeyboard();
      await Future.delayed(const Duration(milliseconds: 80));
      if (!_isCurrentHide(generation)) return;

      /// 兜底关闭TabTip启动器进程；可见键盘窗口优先由user32关闭。
      await Process.run('taskkill', ['/IM', 'TabTip.exe', '/F']);
    } catch (_) {}
  }

  bool _isCurrentHide(int generation) {
    return _latestIntent == _KeyboardIntent.hide &&
        _intentGeneration == generation;
  }
}

enum _KeyboardIntent { show, hide }

typedef _FindWindowWNative =
    ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>);
typedef _FindWindowW = int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>);
typedef _PostMessageWNative =
    ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.IntPtr, ffi.IntPtr);
typedef _PostMessageW = int Function(int, int, int, int);
typedef _GetWindowRectNative =
    ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_NativeRect>);
typedef _GetWindowRect = int Function(int, ffi.Pointer<_NativeRect>);
typedef _IsWindowVisibleNative = ffi.Int32 Function(ffi.IntPtr);
typedef _IsWindowVisible = int Function(int);

final class _NativeRect extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

class _WindowsTouchKeyboardApi {
  _WindowsTouchKeyboardApi._();

  static final instance = _WindowsTouchKeyboardApi._();

  static const _touchKeyboardWindowClass = 'IPTip_Main_Window';
  static const _wmSysCommand = 0x0112;
  static const _scClose = 0xF060;

  ffi.DynamicLibrary? _user32;
  _FindWindowW? _findWindowW;
  _PostMessageW? _postMessageW;
  _GetWindowRect? _getWindowRect;
  _IsWindowVisible? _isWindowVisible;

  bool closeTouchKeyboard() {
    if (!Platform.isWindows) return false;

    try {
      final findWindowW = _findWindowW ??= _lookupFindWindowW();
      final postMessageW = _postMessageW ??= _lookupPostMessageW();
      final className = _touchKeyboardWindowClass.toNativeUtf16();

      try {
        final keyboardWindow = findWindowW(
          className,
          ffi.nullptr.cast<Utf16>(),
        );
        if (keyboardWindow == 0) return false;

        return postMessageW(
              keyboardWindow,
              _wmSysCommand,
              _scClose,
              0,
            ) !=
            0;
      } finally {
        malloc.free(className);
      }
    } catch (_) {
      return false;
    }
  }

  double dockedBottomInsetFor(Rect appRect) {
    final keyboardRect = getTouchKeyboardRect();
    if (keyboardRect == null) return 0;

    final horizontalOverlap =
        _overlap(appRect.left, appRect.right, keyboardRect.left,
            keyboardRect.right);
    if (horizontalOverlap <= 0 || appRect.width <= 0) return 0;

    final widthRatio = horizontalOverlap / appRect.width;
    final bottomGap = (appRect.bottom - keyboardRect.bottom).abs();
    final overlapsBottom = keyboardRect.top < appRect.bottom &&
        keyboardRect.bottom > appRect.top &&
        keyboardRect.top >= appRect.top;

    // Floating/split keyboards are narrower or not docked to the bottom edge.
    // They should not reserve global bottom space.
    if (widthRatio < 0.6 || bottomGap > 96 || !overlapsBottom) return 0;

    final inset = appRect.bottom - keyboardRect.top;
    if (inset <= 0) return 0;
    return inset + 20;
  }

  Rect? getTouchKeyboardRect() {
    if (!Platform.isWindows) return null;

    try {
      final findWindowW = _findWindowW ??= _lookupFindWindowW();
      final isWindowVisible = _isWindowVisible ??= _lookupIsWindowVisible();
      final getWindowRect = _getWindowRect ??= _lookupGetWindowRect();
      final className = _touchKeyboardWindowClass.toNativeUtf16();

      try {
        final keyboardWindow = findWindowW(
          className,
          ffi.nullptr.cast<Utf16>(),
        );
        if (keyboardWindow == 0 || isWindowVisible(keyboardWindow) == 0) {
          return null;
        }

        final rectPointer = malloc<_NativeRect>();
        try {
          if (getWindowRect(keyboardWindow, rectPointer) == 0) return null;

          final rect = rectPointer.ref;
          return Rect.fromLTRB(
            rect.left.toDouble(),
            rect.top.toDouble(),
            rect.right.toDouble(),
            rect.bottom.toDouble(),
          );
        } finally {
          malloc.free(rectPointer);
        }
      } finally {
        malloc.free(className);
      }
    } catch (_) {
      return null;
    }
  }

  double _overlap(double aStart, double aEnd, double bStart, double bEnd) {
    final start = aStart > bStart ? aStart : bStart;
    final end = aEnd < bEnd ? aEnd : bEnd;
    return end > start ? end - start : 0;
  }

  _FindWindowW _lookupFindWindowW() {
    return _loadUser32().lookupFunction<_FindWindowWNative, _FindWindowW>(
      'FindWindowW',
    );
  }

  _PostMessageW _lookupPostMessageW() {
    return _loadUser32().lookupFunction<_PostMessageWNative, _PostMessageW>(
      'PostMessageW',
    );
  }

  _GetWindowRect _lookupGetWindowRect() {
    return _loadUser32().lookupFunction<_GetWindowRectNative, _GetWindowRect>(
      'GetWindowRect',
    );
  }

  _IsWindowVisible _lookupIsWindowVisible() {
    return _loadUser32().lookupFunction<_IsWindowVisibleNative,
        _IsWindowVisible>(
      'IsWindowVisible',
    );
  }

  ffi.DynamicLibrary _loadUser32() {
    return _user32 ??= ffi.DynamicLibrary.open('user32.dll');
  }
}

class SmartTextField extends StatefulWidget {
  const SmartTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.touchKeyboardEnabled = true,
    this.focusNode,
    this.onFocusLost,
  });

  final TextEditingController controller;

  final String? hintText;

  final ValueChanged<String>? onChanged;

  final ValueChanged<String>? onSubmitted;

  final bool touchKeyboardEnabled;

  final FocusNode? focusNode;

  final VoidCallback? onFocusLost;

  @override
  State<SmartTextField> createState() => _SmartTextFieldState();
}

class _SmartTextFieldState extends State<SmartTextField> {
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  int _focusGeneration = 0;

  @override
  void initState() {
    super.initState();

    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();

    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant SmartTextField oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.focusNode == widget.focusNode) return;

    _focusNode.removeListener(_handleFocusChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }

    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChanged);
  }

  Future<void> _handleFocusChanged() async {
    final generation = ++_focusGeneration;

    /// 获取焦点
    if (_focusNode.hasFocus) {
      if (!widget.touchKeyboardEnabled) {
        await KeyboardManager.instance.hideKeyboard(
          clearFocus: false,
          suppressAutoShow: true,
        );
        return;
      }

      await KeyboardManager.instance.showKeyboard();
      if (!mounted || generation != _focusGeneration) return;

      _ensureVisible();

      if (!_focusNode.hasFocus) {
        await KeyboardManager.instance.hideKeyboard(clearFocus: false);
      }
      return;
    }

    /// 失去焦点
    widget.onFocusLost?.call();
    await KeyboardManager.instance.hideKeyboard(clearFocus: false);
  }

  @override
  void dispose() {
    if (_focusNode.hasFocus) {
      KeyboardManager.instance.hideKeyboard(
        clearFocus: false,
        suppressAutoShow: true,
      );
    }

    _focusNode.removeListener(_handleFocusChanged);

    if (_ownsFocusNode) {
      _focusNode.dispose();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: _focusNode,
      keyboardType: widget.touchKeyboardEnabled ? null : TextInputType.none,
      scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 360),
      decoration: InputDecoration(
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
      ),
      onTap: () {
        if (widget.touchKeyboardEnabled) {
          KeyboardManager.instance.showKeyboard(force: true);
          return;
        }

        KeyboardManager.instance.hideKeyboard(
          clearFocus: false,
          suppressAutoShow: true,
        );
      },
      onTapOutside: (_) {
        _focusNode.unfocus(
          disposition: UnfocusDisposition.scope,
        );
      },
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
    );
  }

  void _ensureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const PosPage(),
    );
  }
}

class PosPage extends StatefulWidget {
  const PosPage({super.key});

  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosPageState extends State<PosPage> {
  static const _routeKeyboardSuppressDuration = Duration(milliseconds: 1200);
  static const _pagePadding = 20.0;
  static const _externalInputCount = 12;
  static const _dialogInputCount = 12;

  final searchController = TextEditingController();
  final externalInputControllers = List.generate(
    _externalInputCount,
    (_) => TextEditingController(),
  );
  final _keyboardDismissFocusNode = FocusNode(
    debugLabel: 'keyboardDismissFocusNode',
    skipTraversal: true,
  );
  bool _isFullscreen = false;

  @override
  void initState() {
    super.initState();
    _loadFullscreenState();
  }

  Future<void> _loadFullscreenState() async {
    final isFullscreen = await WindowsWindowController.instance.isFullscreen();
    if (!mounted) return;

    setState(() {
      _isFullscreen = isFullscreen;
    });
  }

  Future<void> _enterFullscreen() async {
    await _hideAllKeyboard();
    final success = await WindowsWindowController.instance.enterFullscreen();
    if (!mounted || !success) return;

    setState(() {
      _isFullscreen = true;
    });
  }

  Future<void> _exitFullscreen() async {
    await _hideAllKeyboard();
    final success = await WindowsWindowController.instance.exitFullscreen();
    if (!mounted || !success) return;

    setState(() {
      _isFullscreen = false;
    });
  }

  String _externalInputHint(int index) {
    if (index == 0) return '测试输入框A';
    if (index == 1) return '测试输入框B';
    return '测试输入框${index + 1}';
  }

  /// 全局关闭焦点+键盘
  Future<void> _hideAllKeyboard({
    Duration suppressDuration = KeyboardManager._defaultSuppressDuration,
  }) async {
    KeyboardManager.instance.suppressAutoShow(suppressDuration);
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );

    if (mounted) {
      _keyboardDismissFocusNode.requestFocus();
    }

    await Future<void>.delayed(Duration.zero);
    await KeyboardManager.instance.hideKeyboard(
      clearFocus: false,
      suppressAutoShow: true,
      suppressDuration: suppressDuration,
    );
  }

  /// Dialog前先清理输入上下文（非常关键）
  Future<void> _showTestDialog() async {
    await _hideAllKeyboard();

    if (!mounted) return;

    final dialogControllers = List.generate(
      _dialogInputCount,
      (_) => TextEditingController(),
    );
    final dialogFocusNode = FocusNode(
      debugLabel: 'dialogKeyboardDismissFocusNode',
      skipTraversal: true,
    );
    final dialogInputFocusNodes = List.generate(
      _dialogInputCount,
      (index) => FocusNode(debugLabel: 'dialogInputFocusNode$index'),
    );
    var dialogInputHideStarted = false;

    Future<void> moveDialogFocusToSink({
      bool lockInputFocus = false,
    }) async {
      if (lockInputFocus) {
        for (final focusNode in dialogInputFocusNodes) {
          focusNode.canRequestFocus = false;
        }
      }

      for (final focusNode in dialogInputFocusNodes) {
        focusNode.unfocus(disposition: UnfocusDisposition.scope);
      }
      FocusManager.instance.primaryFocus?.unfocus(
        disposition: UnfocusDisposition.scope,
      );
      dialogFocusNode.requestFocus();
      await Future<void>.delayed(Duration.zero);
    }

    Future<void> hideDialogKeyboard({
      Duration suppressDuration = KeyboardManager._defaultSuppressDuration,
    }) async {
      await moveDialogFocusToSink();

      if (dialogInputHideStarted) {
        await KeyboardManager.instance.waitForPendingHide();
      } else {
        await KeyboardManager.instance.hideKeyboard(
          clearFocus: false,
          suppressAutoShow: true,
          suppressDuration: suppressDuration,
        );
      }

      KeyboardManager.instance.suppressAutoShow(
        suppressDuration,
      );
    }

    try {
      await showDialog(
        context: context,
        requestFocus: false,
        builder: (dialogContext) {
          return Dialog(
            child: SizedBox(
              width: 500,
              height: 500,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => hideDialogKeyboard(),
                      child: const Text(
                        '测试弹框',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Focus(
                      focusNode: dialogFocusNode,
                      child: const SizedBox.shrink(),
                    ),
                    Expanded(
                      child: ValueListenableBuilder<double>(
                        valueListenable: KeyboardManager.instance.bottomInset,
                        builder: (context, keyboardInset, child) {
                          return SingleChildScrollView(
                            padding: EdgeInsets.only(
                              bottom: _pagePadding + keyboardInset,
                            ),
                            child: child,
                          );
                        },
                        child: Column(
                          children: [
                            for (var index = 0;
                                index < _dialogInputCount;
                                index++) ...[
                              SmartTextField(
                                controller: dialogControllers[index],
                                focusNode: dialogInputFocusNodes[index],
                                hintText: '弹框输入框${index + 1}',
                                onFocusLost: () {
                                  dialogInputHideStarted = true;
                                },
                                onChanged: (value) {
                                  debugPrint('弹框输入框${index + 1}: $value');
                                },
                              ),
                              if (index != _dialogInputCount - 1)
                                const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () async {
                          await moveDialogFocusToSink(
                            lockInputFocus: true,
                          );

                          if (dialogInputHideStarted) {
                            await KeyboardManager.instance.waitForPendingHide();
                          } else {
                            await KeyboardManager.instance.hideKeyboard(
                              clearFocus: false,
                              suppressAutoShow: true,
                              suppressDuration: _routeKeyboardSuppressDuration,
                            );
                          }

                          KeyboardManager.instance.suppressAutoShow(
                            _routeKeyboardSuppressDuration,
                          );

                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop();
                        },
                        child: const Text('关闭'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      for (final controller in dialogControllers) {
        controller.dispose();
      }
      for (final focusNode in dialogInputFocusNodes) {
        focusNode.dispose();
      }
      dialogFocusNode.dispose();
      if (mounted) {
        KeyboardManager.instance.suppressAutoShow(
          _routeKeyboardSuppressDuration,
        );
        FocusManager.instance.primaryFocus?.unfocus(
          disposition: UnfocusDisposition.scope,
        );
        _keyboardDismissFocusNode.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    for (final controller in externalInputControllers) {
      controller.dispose();
    }
    _keyboardDismissFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        behavior: HitTestBehavior.translucent,

        /// 点击空白关闭键盘
        onTap: () async {
          await _hideAllKeyboard();
        },

        child: Scaffold(
          appBar: AppBar(
            title: _isFullscreen
                ? const SizedBox.shrink()
                : const Text('Flutter Windows POS'),
          ),
          body: Stack(
            children: [
              Focus(
                focusNode: _keyboardDismissFocusNode,
                child: const SizedBox.shrink(),
              ),
              ValueListenableBuilder<double>(
                valueListenable: KeyboardManager.instance.bottomInset,
                builder: (context, keyboardInset, child) {
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      _pagePadding,
                      _pagePadding,
                      _pagePadding,
                      _pagePadding + keyboardInset,
                    ),
                    child: child,
                  );
                },
                child: Column(
                  children: [
                    SmartTextField(
                      controller: searchController,
                      hintText: '搜索商品',
                      onChanged: (value) {
                        debugPrint('搜索内容: $value');
                      },
                    ),

                    const SizedBox(height: 20),

                    if (Platform.isWindows) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed:
                                  _isFullscreen ? null : _enterFullscreen,
                              child: const Text('全屏显示'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed:
                                  _isFullscreen ? _exitFullscreen : null,
                              child: const Text('退出全屏'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],

                    const SizedBox(height: 20),

                    ElevatedButton(
                      onPressed: () async {
                        await _showTestDialog();
                      },
                      child: const Text('打开Dialog'),
                    ),

                    const SizedBox(height: 20),

                    ElevatedButton(
                      onPressed: () async {
                        await _hideAllKeyboard();
                      },
                      child: const Text('手动关闭键盘'),
                    ),

                    const SizedBox(height: 20),

                    Container(
                      height: 200,
                      width: double.infinity,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: const Text('点击这里不会再乱弹触摸键盘'),
                    ),

                    const SizedBox(height: 20),

                    for (var index = 0;
                        index < _externalInputCount;
                        index++) ...[
                      SmartTextField(
                        controller: externalInputControllers[index],
                        hintText: _externalInputHint(index),
                        onChanged: (value) {
                          debugPrint('${_externalInputHint(index)}: $value');
                        },
                      ),
                      if (index != _externalInputCount - 1)
                        const SizedBox(height: 20),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }
}
