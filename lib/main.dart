import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class KeyboardManager {
  KeyboardManager._();

  static final instance = KeyboardManager._();

  /// 打开Windows触摸键盘
  Future<void> showKeyboard() async {
    if (!Platform.isWindows) return;

    try {
      await Process.run(
        r'C:\Program Files\Common Files\microsoft shared\ink\TabTip.exe',
        [],
      );
    } catch (_) {}
  }

  /// 真正关闭Windows触摸键盘
  Future<void> hideKeyboard() async {
    if (!Platform.isWindows) return;

    try {
      /// 关闭焦点
      FocusManager.instance.primaryFocus?.unfocus();

      /// Flutter层隐藏
      await SystemChannels.textInput.invokeMethod('TextInput.hide');

      /// 清理Flutter TextInputClient
      await SystemChannels.textInput.invokeMethod('TextInput.clearClient');

      /// 等待focus detach完成
      await Future.delayed(const Duration(milliseconds: 80));

      /// 强制关闭Windows触摸键盘
      await Process.run('taskkill', ['/IM', 'TabTip.exe', '/F']);
    } catch (_) {}
  }
}

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

  bool _isProcessingFocus = false;

  @override
  void initState() {
    super.initState();

    _focusNode = FocusNode();

    _focusNode.addListener(_handleFocusChanged);
  }

  Future<void> _handleFocusChanged() async {
    if (_isProcessingFocus) return;

    _isProcessingFocus = true;

    try {
      /// 获取焦点
      if (_focusNode.hasFocus) {
        await KeyboardManager.instance.showKeyboard();
      }
      /// 失去焦点
      else {
        await KeyboardManager.instance.hideKeyboard();
      }
    } finally {
      _isProcessingFocus = false;
    }
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

  /// 全局关闭焦点+键盘
  Future<void> _hideAllKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();

    await KeyboardManager.instance.hideKeyboard();
  }

  /// Dialog前先清理输入上下文（非常关键）
  Future<void> _showTestDialog() async {
    await _hideAllKeyboard();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('测试弹框'),
          content: SmartTextField(
            controller: TextEditingController(),
            hintText: '搜索商品',
            onChanged: (value) {
              debugPrint('搜索内容: $value');
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
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
    );
  }
}
