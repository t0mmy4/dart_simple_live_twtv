import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

class TwitchDanmakuArgs {
  /// 频道 login 名（小写）
  final String login;
  TwitchDanmakuArgs({required this.login});

  @override
  String toString() => json.encode({"login": login});
}

/// Twitch 聊天弹幕：IRC over WebSocket，匿名只读（justinfan）。
class TwitchDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  final String serverUrl = "wss://irc-ws.chat.twitch.tv:443";

  WebScoketUtils? webScoketUtils;
  String channel = "";

  @override
  Future start(dynamic args) async {
    var login = "";
    if (args is TwitchDanmakuArgs) {
      login = args.login;
    } else if (args is String) {
      login = args;
    }
    channel = login.toLowerCase();

    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (data) {
        decodeMessage(data);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();
  }

  void joinRoom() {
    // 匿名登录：随机 justinfan 用户名；请求 tags 以获取昵称与颜色。
    var nick = "justinfan${Random().nextInt(89000) + 1000}";
    _send("CAP REQ :twitch.tv/tags twitch.tv/commands");
    _send("NICK $nick");
    _send("JOIN #$channel");
  }

  @override
  void heartbeat() {
    _send("PING :tmi.twitch.tv");
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
  }

  void _send(String line) {
    webScoketUtils?.sendMessage("$line\r\n");
  }

  void decodeMessage(dynamic data) {
    try {
      // 一个帧可能包含多行（以 \r\n 分隔）。
      for (var raw in data.toString().split("\r\n")) {
        var line = raw.trim();
        if (line.isEmpty) continue;
        // 服务器心跳，需回 PONG 保活。
        if (line.startsWith("PING")) {
          _send("PONG :tmi.twitch.tv");
          continue;
        }
        if (line.contains("PRIVMSG")) {
          _parsePrivmsg(line);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 解析形如：
  /// `@badge=..;color=#FF0000;display-name=Nick;.. :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :消息正文`
  void _parsePrivmsg(String line) {
    try {
      String? tags;
      var rest = line;
      if (line.startsWith("@")) {
        var sp = line.indexOf(" ");
        if (sp < 0) return;
        tags = line.substring(1, sp);
        rest = line.substring(sp + 1);
      }

      var cmdIdx = rest.indexOf("PRIVMSG");
      if (cmdIdx < 0) return;
      var afterCmd = rest.substring(cmdIdx + "PRIVMSG".length).trimLeft();
      // afterCmd: `#channel :消息正文`
      var msgSep = afterCmd.indexOf(" :");
      if (msgSep < 0) return;
      var message = afterCmd.substring(msgSep + 2).trimRight();

      var userName = "";
      var color = LiveMessageColor.white;
      if (tags != null) {
        var map = <String, String>{};
        for (var kv in tags.split(";")) {
          var i = kv.indexOf("=");
          if (i > 0) {
            map[kv.substring(0, i)] = kv.substring(i + 1);
          }
        }
        userName = map["display-name"] ?? "";
        var c = map["color"] ?? "";
        if (c.length == 7 && c.startsWith("#")) {
          var r = int.tryParse(c.substring(1, 3), radix: 16);
          var g = int.tryParse(c.substring(3, 5), radix: 16);
          var b = int.tryParse(c.substring(5, 7), radix: 16);
          if (r != null && g != null && b != null) {
            color = LiveMessageColor(r, g, b);
          }
        }
      }
      if (userName.isEmpty) {
        // 兜底：从前缀 `:nick!...` 取登录名
        var bang = rest.indexOf("!");
        if (rest.startsWith(":") && bang > 1) {
          userName = rest.substring(1, bang);
        }
      }

      onMessage?.call(LiveMessage(
        type: LiveMessageType.chat,
        userName: userName,
        message: message,
        color: color,
      ));
    } catch (e) {
      CoreLog.error(e);
    }
  }
}
