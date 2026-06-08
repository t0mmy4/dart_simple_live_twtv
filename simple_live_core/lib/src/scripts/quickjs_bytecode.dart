// QuickJS 字节码运行时辅助类。
//
// 背景：抖音 / 斗鱼 的签名脚本（kABogus / kWebMsSDK / kCryptoJs）体积大、嵌套深，
// 直接用 QuickJS 解析（JS_Eval 走递归下降 parser）会在 Flutter-Linux 的小线程栈上
// 递归过深 -> 溢出 C 栈 -> 原生闪退。
//
// 解决思路（不修改第三方包 dart_quickjs）：
//   1. 离线（大栈环境，例如 `dart run`）把静态脚本用 JS_Eval(COMPILE_ONLY) 编译成字节码，
//      再用 JS_WriteObject 序列化、base64 内嵌进 App。
//   2. 运行时用 JS_ReadObject 反序列化 + JS_EvalFunction 执行 —— 完全跳过 parser，
//      因此不会再触发解析期的深递归，也就不会再爆栈。
//
// 实现方式：直接复用 dart_quickjs 已生成的 FFI 绑定（其 lib/src/quickjs_bindings.g.dart
// 中的类型与函数），仅额外补充 3 个 dart_quickjs 未绑定、但 libdart_quickjs.so 已导出的
// 函数（JS_ReadObject / JS_WriteObject / JS_EvalFunction）以及 js_free。
// 通过 `@ffi.Native(assetId: ...)` 指向 dart_quickjs 同一个 native asset，
// 解析到的就是 App 里已经加载的那一份 libdart_quickjs.so —— 无需重新编译原生库、
// 无需 DynamicLibrary.open、更不需要改动 dart_quickjs 本身。
//
// 注意：从其它包导入 `package:dart_quickjs/src/...` 在 Dart 中是合法的（`src/` 只是约定，
// 并非强制私有），这只是“导入”而非“修改”第三方包。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// 复用 dart_quickjs 的 FFI 绑定（JSRuntime/JSContext/JSValue 类型，以及 JS_Eval、
// JS_NewRuntime、JS_FreeValue、JS_ToCStringLen2 等已绑定函数）。
// 有意导入第三方包的 lib/src/ 文件：这是“复用其生成的 FFI 绑定”而非修改它，
// 也正是本方案“不触及第三方库”的关键，故显式忽略 implementation_imports 提示。
// ignore: implementation_imports
import 'package:dart_quickjs/src/quickjs_bindings.g.dart';
// JsException：dart_quickjs 的公开异常类型。
import 'package:dart_quickjs/dart_quickjs.dart' show JsException;

/// dart_quickjs 的 native asset id（见其 quickjs_bindings.g.dart 顶部的
/// `@ffi.DefaultAsset(...)`）。我们补充绑定的符号都指向同一个 asset，
/// 因此解析到的是同一份 libdart_quickjs.so。
const String _kQuickJsAsset = 'package:dart_quickjs/src/quickjs_bindings.g.dart';

// ===== dart_quickjs 未绑定、但 .so 已导出的函数（手动补充绑定）=====

/// `JSValue JS_ReadObject(JSContext *ctx, const uint8_t *buf, size_t buf_len, int flags);`
@ffi.Native<
  JSValue Function(
    ffi.Pointer<JSContext>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Size,
    ffi.Int32,
  )
>(symbol: 'JS_ReadObject', assetId: _kQuickJsAsset)
external JSValue _jsReadObject(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Uint8> buf,
  int bufLen,
  int flags,
);

/// `uint8_t *JS_WriteObject(JSContext *ctx, size_t *psize, JSValueConst obj, int flags);`
@ffi.Native<
  ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<JSContext>,
    ffi.Pointer<ffi.Size>,
    JSValue,
    ffi.Int32,
  )
>(symbol: 'JS_WriteObject', assetId: _kQuickJsAsset)
external ffi.Pointer<ffi.Uint8> _jsWriteObject(
  ffi.Pointer<JSContext> ctx,
  ffi.Pointer<ffi.Size> psize,
  JSValue obj,
  int flags,
);

/// `JSValue JS_EvalFunction(JSContext *ctx, JSValue fun_obj);`
/// 注意：会消费（释放）传入的 fun_obj。
@ffi.Native<JSValue Function(ffi.Pointer<JSContext>, JSValue)>(
  symbol: 'JS_EvalFunction',
  assetId: _kQuickJsAsset,
)
external JSValue _jsEvalFunction(ffi.Pointer<JSContext> ctx, JSValue funObj);

/// `void js_free(JSContext *ctx, void *ptr);` —— 释放 JS_WriteObject 返回的缓冲区。
@ffi.Native<ffi.Void Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Void>)>(
  symbol: 'js_free',
  assetId: _kQuickJsAsset,
)
external void _jsFree(ffi.Pointer<JSContext> ctx, ffi.Pointer<ffi.Void> ptr);

/// `void JS_UpdateStackTop(JSRuntime *rt);`
/// 关键：dart_quickjs 创建运行时后从不调用它，导致 stack_top 停留在 JS_NewRuntime
/// 时的 SP；之后在不同 FFI 调用栈深处执行时，溢出检查的基准不准 —— 可能在 QuickJS
/// 抛出“栈溢出”之前就真实溢出 C 栈而原生崩溃。我们在每次执行前刷新 stack_top，
/// 让溢出检查以“当前执行点”为基准，从而要么完成、要么抛可捕获异常，而不是闪退。
@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>)>(
  symbol: 'JS_UpdateStackTop',
  assetId: _kQuickJsAsset,
)
external void _jsUpdateStackTop(ffi.Pointer<JSRuntime> rt);

// ===== QuickJS eval / 序列化标志位（取自 quickjs.h，与 .so 构建版本一致）=====
const int _jsEvalTypeGlobal = 0; // JS_EVAL_TYPE_GLOBAL
const int _jsEvalFlagCompileOnly = 1 << 5; // JS_EVAL_FLAG_COMPILE_ONLY = 32
const int _jsWriteObjBytecode = 1 << 0; // JS_WRITE_OBJ_BYTECODE = 1
const int _jsWriteObjStripSource = 1 << 4; // JS_WRITE_OBJ_STRIP_SOURCE = 16
const int _jsWriteObjStripDebug = 1 << 5; // JS_WRITE_OBJ_STRIP_DEBUG = 32
const int _jsReadObjBytecode = 1 << 0; // JS_READ_OBJ_BYTECODE = 1

/// 推荐的字节码写出标志：在 BYTECODE 基础上去掉源码与调试信息以减小体积。
/// 注意：极个别混淆脚本会用 Function.prototype.toString 自校验源码，
/// 若去源码后签名异常，请改用 [QuickJsBytecode.writeFlagsBytecodeOnly]。
const int kWriteFlagsStripped =
    _jsWriteObjBytecode | _jsWriteObjStripSource | _jsWriteObjStripDebug;

/// 仅 BYTECODE，不去源码（最保守、体积最大）。
const int kWriteFlagsBytecodeOnly = _jsWriteObjBytecode;

/// 基于 QuickJS 字节码的轻量运行时。
///
/// 用法：
/// ```dart
/// final rt = QuickJsBytecode();
/// rt.evalBytecode(kABogusBytecode);          // 加载字节码，定义全局函数（不解析）
/// final r = rt.evalToString("getABogus('q','ua')"); // 解析极小的调用表达式并执行
/// rt.dispose();
/// ```
class QuickJsBytecode {
  late final ffi.Pointer<JSRuntime> _rt;
  late final ffi.Pointer<JSContext> _ctx;
  bool _disposed = false;

  /// [memoryLimit] 内存上限（字节，0 = 不限制）。
  /// [maxStackSize] QuickJS 自身的 JS 栈检查上限（字节，0 = 用 QuickJS 默认）。
  /// 因为本类不解析大脚本（只加载字节码 + 解析极小表达式 + 执行），
  /// 这里给一个较宽松的值即可，执行期递归深度很浅，不会触及真实 C 栈上限。
  QuickJsBytecode({
    int memoryLimit = 64 * 1024 * 1024,
    int maxStackSize = 1024 * 1024,
  }) {
    _rt = JS_NewRuntime();
    if (_rt == ffi.nullptr) {
      throw JsException('Failed to create QuickJS runtime');
    }
    if (memoryLimit > 0) JS_SetMemoryLimit(_rt, memoryLimit);
    if (maxStackSize > 0) JS_SetMaxStackSize(_rt, maxStackSize);
    _ctx = JS_NewContext(_rt);
    if (_ctx == ffi.nullptr) {
      JS_FreeRuntime(_rt);
      throw JsException('Failed to create QuickJS context');
    }
  }

  /// 把 JS 源码编译成字节码（**仅供离线生成工具使用**，需要在大栈环境运行，
  /// 因为编译仍然要解析源码）。
  ///
  /// 等价于 `JS_Eval(COMPILE_ONLY)` 得到顶层函数对象，再 `JS_WriteObject(BYTECODE)`。
  /// [writeFlags] 控制序列化标志，默认 [kWriteFlagsStripped]（去源码/调试信息，体积更小）。
  Uint8List compile(
    String source, {
    String filename = '<input>',
    int writeFlags = kWriteFlagsStripped,
  }) {
    _checkDisposed();
    final codePtr = source.toNativeUtf8();
    final fnPtr = filename.toNativeUtf8();
    try {
      final fnObj = JS_Eval(
        _ctx,
        codePtr,
        codePtr.length,
        fnPtr,
        _jsEvalTypeGlobal | _jsEvalFlagCompileOnly,
      );
      if (fnObj.isException) _throwJsException();
      final psize = malloc<ffi.Size>();
      try {
        final buf = _jsWriteObject(_ctx, psize, fnObj, writeFlags);
        if (buf == ffi.nullptr) {
          JS_FreeValue(_ctx, fnObj);
          _throwJsException();
        }
        final out = Uint8List.fromList(buf.asTypedList(psize.value));
        _jsFree(_ctx, buf.cast());
        JS_FreeValue(_ctx, fnObj);
        return out;
      } finally {
        malloc.free(psize);
      }
    } finally {
      malloc.free(codePtr);
      malloc.free(fnPtr);
    }
  }

  /// 加载并执行字节码（顶层程序），用于定义全局函数 / 变量。
  /// **不经过 parser**，因此不会触发解析期深递归 —— 这是修复闪退的关键。
  void evalBytecode(Uint8List bytecode) {
    _checkDisposed();
    _jsUpdateStackTop(_rt); // 以当前执行点为栈检查基准
    final buf = malloc<ffi.Uint8>(bytecode.length);
    buf.asTypedList(bytecode.length).setAll(0, bytecode);
    try {
      final fnObj = _jsReadObject(_ctx, buf, bytecode.length, _jsReadObjBytecode);
      if (fnObj.isException) _throwJsException();
      // JS_EvalFunction 会消费 fnObj（无需再次释放）。
      final result = _jsEvalFunction(_ctx, fnObj);
      if (result.isException) _throwJsException();
      if (result.hasRefCount) JS_FreeValue(_ctx, result);
    } finally {
      malloc.free(buf);
    }
  }

  /// 解析并执行一段（**很小的**）JS 源码，把结果转成字符串返回。
  /// 用于执行 `getABogus(...)` / `ub98484234(...)` 这类极小调用表达式。
  String evalToString(String source, {String filename = '<input>'}) {
    _checkDisposed();
    _jsUpdateStackTop(_rt); // 以当前执行点为栈检查基准
    final codePtr = source.toNativeUtf8();
    final fnPtr = filename.toNativeUtf8();
    try {
      final r = JS_Eval(_ctx, codePtr, codePtr.length, fnPtr, _jsEvalTypeGlobal);
      if (r.isException) _throwJsException();
      return _toDartStringAndFree(r);
    } finally {
      malloc.free(codePtr);
      malloc.free(fnPtr);
    }
  }

  /// 解析并执行一段（小的）JS 源码，不关心返回值（如加载动态 html 脚本）。
  void evalVoid(String source, {String filename = '<input>'}) {
    _checkDisposed();
    _jsUpdateStackTop(_rt); // 以当前执行点为栈检查基准
    final codePtr = source.toNativeUtf8();
    final fnPtr = filename.toNativeUtf8();
    try {
      final r = JS_Eval(_ctx, codePtr, codePtr.length, fnPtr, _jsEvalTypeGlobal);
      if (r.isException) _throwJsException();
      if (r.hasRefCount) JS_FreeValue(_ctx, r);
    } finally {
      malloc.free(codePtr);
      malloc.free(fnPtr);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    JS_FreeContext(_ctx);
    JS_FreeRuntime(_rt);
  }

  // ===== 私有辅助 =====

  void _checkDisposed() {
    if (_disposed) throw JsException('QuickJsBytecode already disposed');
  }

  String _toDartStringAndFree(JSValue v) {
    final plen = malloc<ffi.Size>();
    final cstr = JS_ToCStringLen2(_ctx, plen, v, false);
    try {
      if (cstr == ffi.nullptr) {
        throw JsException('Failed to convert JS value to string');
      }
      return cstr.toDartString(length: plen.value);
    } finally {
      if (cstr != ffi.nullptr) JS_FreeCString(_ctx, cstr);
      malloc.free(plen);
      if (v.hasRefCount) JS_FreeValue(_ctx, v);
    }
  }

  Never _throwJsException() {
    final exc = JS_GetException(_ctx);
    String msg = 'QuickJS error';
    final plen = malloc<ffi.Size>();
    final cstr = JS_ToCStringLen2(_ctx, plen, exc, false);
    if (cstr != ffi.nullptr) {
      msg = cstr.toDartString(length: plen.value);
      JS_FreeCString(_ctx, cstr);
    }
    malloc.free(plen);
    if (exc.hasRefCount) JS_FreeValue(_ctx, exc);
    throw JsException(msg);
  }
}

/// 把 base64 字符串解码成字节码。生成的字节码常量用 base64 内嵌，运行时用此解码。
Uint8List decodeBytecodeB64(String b64) => base64.decode(b64);
