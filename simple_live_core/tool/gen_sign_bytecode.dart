// 离线字节码生成 + 自测工具（不参与 App 构建）。
//
// 运行：在 simple_live_core 目录下
//   dart run tool/gen_sign_bytecode.dart
// 它会用 **当前 dart_quickjs 版本对应的 libdart_quickjs.so**（与 App 同为
// pubspec.lock 锁定的 commit）把三个静态签名脚本编译成字节码，base64 内嵌写入
//   lib/src/scripts/sign_bytecode.g.dart
// 同时做一次自测：重新加载字节码并实际调用签名函数，打印结果，确认字节码可用且正确。
//
// 因为 `dart run` 主 isolate 线程栈足够大，这里的“编译（需要解析源码）”不会爆栈；
// 而 App 运行时只加载字节码（不解析），所以也不会爆栈。两边用同一 commit 的 .so，
// 字节码版本（BC_VERSION）一致、可互相加载。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/src/scripts/quickjs_bytecode.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

void main() async {
  print('== QuickJS 签名脚本字节码生成 ==\n');

  // 1) 编译三个静态脚本为字节码。
  final abogus = _compile('kABogus', DouyinSign.kABogus);
  final webmssdk = _compile('kWebMsSDK', DouyinSign.kWebMsSDK);
  final cryptojs = _compile('kCryptoJs', DouyuSign.kCryptoJs);

  // 2) 逐个自测（重新加载字节码并真实调用）。
  _selfTestAbogus(abogus);
  _selfTestWebMsSDK(webmssdk);
  await _selfTestDouyu(cryptojs);

  // 3) 写入生成文件。
  final abogusB64 = base64.encode(abogus);
  final webmssdkB64 = base64.encode(webmssdk);
  final cryptojsB64 = base64.encode(cryptojs);

  final out = StringBuffer()
    ..writeln('// GENERATED FILE — 请勿手动编辑。')
    ..writeln('// 由 tool/gen_sign_bytecode.dart 生成：抖音/斗鱼签名脚本的 QuickJS 字节码（base64）。')
    ..writeln('// 运行时通过 quickjs_bytecode.dart 的 JS_ReadObject 加载，跳过解析以避免爆栈闪退。')
    ..writeln('//')
    ..writeln('// 注意：字节码与 libdart_quickjs.so 的 BC_VERSION 绑定。若升级 dart_quickjs')
    ..writeln('// （pubspec.lock 的 resolved-ref 变化），需重新运行本工具重新生成。')
    ..writeln()
    ..writeln("const String kABogusBytecodeB64 =\n    '$abogusB64';")
    ..writeln()
    ..writeln("const String kWebMsSDKBytecodeB64 =\n    '$webmssdkB64';")
    ..writeln()
    ..writeln("const String kCryptoJsBytecodeB64 =\n    '$cryptojsB64';");

  final file = File('lib/src/scripts/sign_bytecode.g.dart');
  file.writeAsStringSync(out.toString());
  print('\n已写入 ${file.path}');
  print('  kABogus   字节码 ${abogus.length} 字节 -> base64 ${abogusB64.length}');
  print('  kWebMsSDK 字节码 ${webmssdk.length} 字节 -> base64 ${webmssdkB64.length}');
  print('  kCryptoJs 字节码 ${cryptojs.length} 字节 -> base64 ${cryptojsB64.length}');
}

Uint8List _compile(String name, String source) {
  final rt = QuickJsBytecode();
  try {
    final bc = rt.compile(source, filename: '$name.js');
    print('[$name] 编译成功：源码 ${source.length} 字符 -> 字节码 ${bc.length} 字节');
    return bc;
  } catch (e) {
    print('[$name] 编译失败：$e');
    rethrow;
  } finally {
    rt.dispose();
  }
}

void _selfTestAbogus(Uint8List bc) {
  final rt = QuickJsBytecode();
  try {
    rt.evalBytecode(bc);
    final r = rt.evalToString("getABogus('verify_fragment=1', '$_ua')");
    final ok = r.isNotEmpty;
    print('[自测 getABogus] ${ok ? "PASS" : "FAIL(空)"}: a_bogus="${_short(r)}"');
  } catch (e) {
    print('[自测 getABogus] FAIL: $e');
  } finally {
    rt.dispose();
  }
}

void _selfTestWebMsSDK(Uint8List bc) {
  final rt = QuickJsBytecode();
  try {
    rt.evalBytecode(bc);
    // msStub 是一个 32 位 md5 十六进制串；这里用任意合法值验证函数可运行。
    const stub = '0123456789abcdef0123456789abcdef';
    final r = rt.evalToString("getMSSDKSignature('$stub', '$_ua')");
    final ok = r.isNotEmpty;
    print('[自测 getMSSDKSignature] ${ok ? "PASS" : "FAIL(空)"}: signature="${_short(r)}"');
  } catch (e) {
    print('[自测 getMSSDKSignature] FAIL: $e');
  } finally {
    rt.dispose();
  }
}

Future<void> _selfTestDouyu(Uint8List cryptoBc) async {
  // 斗鱼需要：加载 kCryptoJs 字节码 + 解析动态 html(定义 ub98484234) + 调用。
  final html = await _fetchDouyuEnc('9999');
  if (html == null) {
    print('[自测 ub98484234] 跳过（未能获取 homeH5Enc html）');
    return;
  }
  final rt = QuickJsBytecode();
  try {
    rt.evalBytecode(cryptoBc); // 字节码加载 CryptoJS（无解析）
    rt.evalVoid(html, filename: 'douyu_enc.js'); // 动态脚本（depth≈6，解析无压力）
    const did = '10000000000000000000000000001501';
    final time = (DateTime.now().millisecondsSinceEpoch / 1000).round();
    final r = rt.evalToString("ub98484234('9999','$did','$time')");
    final ok = r.isNotEmpty;
    print('[自测 ub98484234] ${ok ? "PASS" : "FAIL(空)"}: sign="${_short(r)}"');
  } catch (e) {
    print('[自测 ub98484234] FAIL: $e');
  } finally {
    rt.dispose();
  }
}

Future<String?> _fetchDouyuEnc(String rid) async {
  // 先尝试本地缓存，再直连。
  try {
    final f = File('/tmp/dy_enc.json');
    if (f.existsSync()) {
      final js = jsonDecode(f.readAsStringSync())['data']['room$rid'];
      if (js is String && js.isNotEmpty) return js;
    }
  } catch (_) {}
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final req = await client.getUrl(
      Uri.parse('https://www.douyu.com/swf_api/homeH5Enc?rids=$rid'),
    );
    req.headers.set('referer', 'https://www.douyu.com/$rid');
    req.headers.set('user-agent', _ua);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    client.close();
    final js = jsonDecode(body)['data']['room$rid'];
    if (js is String && js.isNotEmpty) return js;
  } catch (e) {
    print('  (fetch homeH5Enc 失败: $e)');
  }
  return null;
}

String _short(String s) => s.length <= 48 ? s : '${s.substring(0, 48)}…(${s.length})';
