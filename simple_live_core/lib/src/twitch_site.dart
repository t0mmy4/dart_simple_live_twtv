import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/core_error.dart';

/// Twitch 直播站点。
///
/// 全部通过非官方 GQL 接口（公共网页 client-id）获取信息，播放走
/// `streamPlaybackAccessToken` + usher（与 streamlink/yt-dlp 思路一致）。
///
/// 说明（已知限制）：
/// - Twitch 对目录分页（带游标的 `streams`/`game.streams`）会触发
///   client-integrity 反爬挑战，匿名无法翻页，因此列表只取第一页
///   （`hasMore=false`），首屏热门内容正常。
/// - 取 token 时带 `playerType=embed` 降低广告频率；如需近乎无广告，
///   可设置 [proxyUrl]（TTV-LOL 兼容代理，仅代理播放列表）。
class TwitchSite implements LiveSite {
  @override
  String id = "twitch";

  @override
  String name = "Twitch";

  /// Twitch 网页端公共 Client-ID（streamlink/yt-dlp 等通用），用于匿名 GQL。
  static const String clientId = "kimne78kx3ncx6brgo4mv6wki5h1ko";
  static const String gqlUrl = "https://gql.twitch.tv/gql";
  static const String usherHost = "https://usher.ttvnw.net";

  /// 去广告代理基址（TTV-LOL 兼容，形如 `https://xxx`）。
  /// 为空（默认）= 直连。由 App 从设置注入。
  String? proxyUrl;

  final String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  Map<String, dynamic> get _gqlHeaders => {
        "Client-ID": clientId,
        "User-Agent": _userAgent,
      };

  @override
  LiveDanmaku getDanmaku() => TwitchDanmaku();

  /// 发送 GQL 完整查询文档（不用会失效的持久化 hash）。
  Future<dynamic> _gql(String query, [Map<String, dynamic>? variables]) async {
    return await HttpClient.instance.postJson(
      gqlUrl,
      data: {
        "query": query,
        "variables": variables ?? {},
      },
      header: _gqlHeaders,
    );
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    var data = await _gql(_qGames, {"first": 50});
    var edges = data["data"]?["games"]?["edges"] as List? ?? [];
    var children = <LiveSubCategory>[];
    for (var e in edges) {
      var node = e["node"];
      if (node == null) continue;
      children.add(LiveSubCategory(
        id: node["id"].toString(),
        name: (node["displayName"] ?? node["name"] ?? "").toString(),
        parentId: "all",
        pic: _boxArt(node["boxArtURL"]?.toString()),
      ));
    }
    return [LiveCategory(id: "all", name: "分类", children: children)];
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    // 匿名无法翻页（integrity 限制），仅返回第一页。
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    var data = await _gql(_qGameStreams, {"id": category.id, "first": 30});
    var conn = data["data"]?["game"]?["streams"];
    return LiveCategoryResult(hasMore: false, items: _streamsToItems(conn));
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    var data = await _gql(_qStreams, {"first": 30});
    var conn = data["data"]?["streams"];
    return LiveCategoryResult(hasMore: false, items: _streamsToItems(conn));
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    if (page > 1) {
      return LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    var list = await _searchChannels(keyword);
    var items = <LiveRoomItem>[];
    for (var u in list) {
      var stream = u["stream"];
      if (stream == null) continue; // 只保留直播中的频道
      items.add(LiveRoomItem(
        roomId: (u["login"] ?? "").toString(),
        title: stream["title"]?.toString() ?? "",
        cover: stream["previewImageURL"]?.toString() ?? "",
        userName: (u["displayName"] ?? u["login"] ?? "").toString(),
        online: int.tryParse(stream["viewersCount"].toString()) ?? 0,
      ));
    }
    return LiveSearchRoomResult(hasMore: false, items: items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    if (page > 1) {
      return LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]);
    }
    var list = await _searchChannels(keyword);
    var items = list
        .map((u) => LiveAnchorItem(
              roomId: (u["login"] ?? "").toString(),
              avatar: u["profileImageURL"]?.toString() ?? "",
              userName: (u["displayName"] ?? u["login"] ?? "").toString(),
              liveStatus: u["stream"] != null,
            ))
        .toList();
    return LiveSearchAnchorResult(hasMore: false, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var login = roomId.toLowerCase();
    var data = await _gql(_qUser, {"login": login});
    var user = data["data"]?["user"];
    if (user == null) {
      throw CoreError("找不到该频道");
    }
    var stream = user["stream"];
    var live = stream != null;

    var title = "";
    var cover = "";
    var online = 0;
    String? introduction;
    if (live) {
      title = stream["title"]?.toString() ?? "";
      cover = stream["previewImageURL"]?.toString() ?? "";
      online = int.tryParse(stream["viewersCount"].toString()) ?? 0;
      var game = stream["game"];
      introduction = game == null ? null : game["name"]?.toString();
    } else {
      title = user["lastBroadcast"]?["title"]?.toString() ?? "";
    }

    return LiveRoomDetail(
      roomId: login,
      title: title,
      cover: cover,
      userName: (user["displayName"] ?? user["login"] ?? "").toString(),
      userAvatar: user["profileImageURL"]?.toString() ?? "",
      online: online,
      introduction: introduction,
      status: live,
      data: {"login": login, "id": user["id"]?.toString()},
      danmakuData: TwitchDanmakuArgs(login: login),
      url: "https://www.twitch.tv/$login",
    );
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var data = await _gql(_qUser, {"login": roomId.toLowerCase()});
    return data["data"]?["user"]?["stream"] != null;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    var master = await _resolvePlaylist(detail.roomId);
    return _parseMasterPlaylist(master);
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    // 变体播放列表地址已在 getPlayQualites 解析时存入 quality.data。
    return LivePlayUrl(urls: [quality.data.toString()]);
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) {
    // Twitch 无对应功能
    return Future.value([]);
  }

  // ---- 内部工具 ----

  Future<List<dynamic>> _searchChannels(String keyword) async {
    var data = await _gql(_qSearch, {"q": keyword});
    return data["data"]?["searchFor"]?["channels"]?["items"] as List? ?? [];
  }

  List<LiveRoomItem> _streamsToItems(dynamic conn) {
    var items = <LiveRoomItem>[];
    // conn 可能为 null（integrity 挑战触发时），做空保护。
    var edges = conn?["edges"] as List? ?? [];
    for (var e in edges) {
      var node = e["node"];
      if (node == null) continue;
      var b = node["broadcaster"];
      var login = (b?["login"] ?? "").toString();
      if (login.isEmpty) continue;
      items.add(LiveRoomItem(
        roomId: login,
        title: node["title"]?.toString() ?? "",
        cover: node["previewImageURL"]?.toString() ?? "",
        userName: (b?["displayName"] ?? b?["login"] ?? "").toString(),
        online: int.tryParse(node["viewersCount"].toString()) ?? 0,
      ));
    }
    return items;
  }

  /// boxArtURL 形如 `..-{width}x{height}.jpg`，替换为具体尺寸。
  String _boxArt(String? url) {
    if (url == null || url.isEmpty) return "";
    return url.replaceAll("{width}", "285").replaceAll("{height}", "380");
  }

  /// 获取频道的主播放列表（master m3u8 文本）。
  /// [proxyUrl] 非空时经 TTV-LOL 兼容代理获取（去广告），否则直连。
  Future<String> _resolvePlaylist(String login) async {
    login = login.toLowerCase();
    var proxy = proxyUrl?.trim() ?? "";
    if (proxy.isNotEmpty) {
      var base = proxy.replaceAll(RegExp(r'/+$'), '');
      return await HttpClient.instance.getText("$base/playlist/$login.m3u8");
    }
    // 1) 取签名 token
    var tokenResp =
        await _gql(_qAccessToken, {"login": login, "playerType": "embed"});
    var token = tokenResp["data"]?["streamPlaybackAccessToken"];
    if (token == null) {
      throw CoreError("无法获取播放令牌");
    }
    // 2) 请求 usher 获取主播放列表
    return await HttpClient.instance.getText(
      "$usherHost/api/channel/hls/$login.m3u8",
      queryParameters: {
        "client_id": clientId,
        "token": token["value"].toString(),
        "sig": token["signature"].toString(),
        "allow_source": "true",
        "allow_audio_only": "true",
        "fast_bread": "true",
        "playlist_include_framerate": "true",
        "player": "twitchweb",
        "type": "any",
        "p": Random().nextInt(9999999) + 1,
      },
      header: {"User-Agent": _userAgent},
    );
  }

  /// 解析 master m3u8，每档的变体播放列表地址存入 [LivePlayQuality.data]，
  /// 并按带宽从高到低排序（Twitch 返回顺序不保证最高清在前，而 App 约定
  /// index 0 为最高清）。
  List<LivePlayQuality> _parseMasterPlaylist(String m3u8) {
    var qualities = <LivePlayQuality>[];
    String? pendingName;
    var pendingBandwidth = 0;
    var skip = false;
    for (var raw in m3u8.split("\n")) {
      var line = raw.trim();
      if (line.startsWith("#EXT-X-MEDIA") && line.contains("TYPE=VIDEO")) {
        var name = RegExp(r'NAME="([^"]+)"').firstMatch(line)?.group(1);
        var groupId =
            RegExp(r'GROUP-ID="([^"]+)"').firstMatch(line)?.group(1) ?? "";
        skip = groupId.contains("audio_only") ||
            (name ?? "").toLowerCase().contains("audio");
        pendingName = name ?? groupId;
      } else if (line.startsWith("#EXT-X-STREAM-INF")) {
        pendingBandwidth = int.tryParse(
              RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? "0",
            ) ??
            0;
      } else if (line.isNotEmpty && !line.startsWith("#")) {
        // 变体播放列表 URL
        if (pendingName != null && !skip) {
          qualities.add(LivePlayQuality(
            quality: pendingName,
            data: line,
            sort: pendingBandwidth,
          ));
        }
        pendingName = null;
        pendingBandwidth = 0;
        skip = false;
      }
    }
    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    return qualities;
  }

  // ---- GQL 查询文档（字段均已对真实接口验证） ----

  static const String _qGames =
      r'query($first:Int!){games(first:$first){edges{node{id name displayName boxArtURL}}}}';

  static const String _qStreams =
      r'query($first:Int!){streams(first:$first){edges{node{id title viewersCount previewImageURL(width:640,height:360) game{name} broadcaster{login displayName profileImageURL(width:150)}}}}}';

  static const String _qGameStreams =
      r'query($id:ID!,$first:Int!){game(id:$id){streams(first:$first){edges{node{id title viewersCount previewImageURL(width:640,height:360) broadcaster{login displayName profileImageURL(width:150)}}}}}}';

  static const String _qUser =
      r'query($login:String!){user(login:$login){id login displayName profileImageURL(width:300) stream{id title type viewersCount previewImageURL(width:1280,height:720) game{name}} lastBroadcast{title}}}';

  static const String _qAccessToken =
      r'query($login:String!,$playerType:String!){streamPlaybackAccessToken(channelName:$login,params:{platform:"web",playerBackend:"mediaplayer",playerType:$playerType}){value signature}}';

  static const String _qSearch =
      r'query($q:String!){searchFor(userQuery:$q,platform:"web"){channels{items{id login displayName profileImageURL(width:150) stream{id viewersCount title previewImageURL(width:640,height:360)}}}}}';
}
