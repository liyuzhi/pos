import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class KeyboardManager {
  KeyboardManager._();

  static final instance = KeyboardManager._();

  static const _defaultSuppressDuration = Duration(milliseconds: 500);

  DateTime? _autoShowSuppressedUntil;
  Future<void>? _hideInFlight;
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
  Future<void> showKeyboard() async {
    if (!Platform.isWindows) return;
    if (_isAutoShowSuppressed) {
      _markIntent(_KeyboardIntent.hide);
      return;
    }

    final generation = _markIntent(_KeyboardIntent.show);

    try {
      await SystemChannels.textInput.invokeMethod('TextInput.show');
      await Process.run(
        r'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe',
        [],
      );
    } catch (_) {}

    if (_latestIntent == _KeyboardIntent.hide &&
        generation != _intentGeneration) {
      await _hideKeyboardNow();
    }
  }

  /// 真正关闭Windows触摸键盘
  Future<void> hideKeyboard({
    bool clearFocus = true,
    bool suppressAutoShow = false,
  }) async {
    if (suppressAutoShow) {
      this.suppressAutoShow();
    } else {
      _markIntent(_KeyboardIntent.hide);
    }

    if (clearFocus) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    final currentHide = _hideInFlight ?? _hideKeyboardNow();
    _hideInFlight = currentHide;

    try {
      await currentHide;
    } finally {
      if (identical(_hideInFlight, currentHide)) {
        _hideInFlight = null;
      }
    }
  }

  Future<void> _hideKeyboardNow() async {
    try {
      /// Flutter层隐藏
      await SystemChannels.textInput.invokeMethod('TextInput.hide');

      /// 清理Flutter TextInputClient
      await SystemChannels.textInput.invokeMethod('TextInput.clearClient');
    } catch (_) {}

    if (!Platform.isWindows) return;

    try {
      /// 等待focus detach完成
      await Future.delayed(const Duration(milliseconds: 80));

      /// 强制关闭Windows触摸键盘
      await Process.run('taskkill', ['/IM', 'TabTip.exe', '/F']);
    } catch (_) {}
  }
}

enum _KeyboardIntent { show, hide }

class SmartTextField extends StatefulWidget {
  const SmartTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;

  final String? hintText;

  final ValueChanged<String>? onChanged;

  final ValueChanged<String>? onSubmitted;

  @override
  State<SmartTextField> createState() => _SmartTextFieldState();
}

class _SmartTextFieldState extends State<SmartTextField> {
  late FocusNode _focusNode;
  int _focusGeneration = 0;

  @override
  void initState() {
    super.initState();

    _focusNode = FocusNode();

    _focusNode.addListener(_handleFocusChanged);
  }

  Future<void> _handleFocusChanged() async {
    final generation = ++_focusGeneration;

    /// 获取焦点
    if (_focusNode.hasFocus) {
      await KeyboardManager.instance.showKeyboard();
      if (!mounted || generation != _focusGeneration) return;

      if (!_focusNode.hasFocus) {
        await KeyboardManager.instance.hideKeyboard(clearFocus: false);
      }
      return;
    }

    /// 失去焦点
    await KeyboardManager.instance.hideKeyboard(clearFocus: false);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);

    _focusNode.dispose();

    /// 防止dispose后仍存在输入上下文
    SystemChannels.textInput.invokeMethod('TextInput.clearClient');

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      focusNode: _focusNode,
      decoration: InputDecoration(
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
      ),
      onTap: KeyboardManager.instance.showKeyboard,
      onTapOutside: (_) => _focusNode.unfocus(),
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
    );
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
  final searchController = TextEditingController();
  final _keyboardDismissFocusNode = FocusNode(
    debugLabel: 'keyboardDismissFocusNode',
    skipTraversal: true,
  );

  /// 全局关闭焦点+键盘
  Future<void> _hideAllKeyboard() async {
    KeyboardManager.instance.suppressAutoShow();
    FocusManager.instance.primaryFocus?.unfocus();

    if (mounted) {
      _keyboardDismissFocusNode.requestFocus();
    }

    await KeyboardManager.instance.hideKeyboard(suppressAutoShow: true);
  }

  /// Dialog前先清理输入上下文（非常关键）
  Future<void> _showTestDialog() async {
    await _hideAllKeyboard();

    if (!mounted) return;

    final dialogController = TextEditingController();

    try {
      await showDialog(
        context: context,
        requestFocus: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('测试弹框'),
            content: SmartTextField(
              controller: dialogController,
              hintText: '搜索商品',
              onChanged: (value) {
                debugPrint('搜索内容: $value');
              },
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  KeyboardManager.instance.suppressAutoShow();
                  await KeyboardManager.instance.hideKeyboard(
                    suppressAutoShow: true,
                  );

                  if (!dialogContext.mounted) return;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    } finally {
      dialogController.dispose();
      if (mounted) {
        await _hideAllKeyboard();
      }
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    _keyboardDismissFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardDismissFocusNode,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,

        /// 点击空白关闭键盘
        onTap: () async {
          await _hideAllKeyboard();
        },

        child: Scaffold(
          appBar: AppBar(title: const Text('Flutter Windows POS')),
          body: Padding(
            padding: const EdgeInsets.all(20),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
