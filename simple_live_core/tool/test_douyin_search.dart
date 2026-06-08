// 抖音搜索功能验证脚本（独立运行，绕开 Flutter 小线程栈的限制）。
// 用法：
//   cd simple_live_core
//   dart run tool/test_douyin_search.dart [关键词]
// 默认关键词为 "英雄联盟"。会分别测试房间搜索与主播搜索。
import 'package:simple_live_core/simple_live_core.dart';

Future<void> main(List<String> args) async {
  CoreLog.enableLog = false;
  final keyword = args.isNotEmpty ? args.first : "英雄联盟";
  final site = DouyinSite();

  print("===== 抖音搜索测试，关键词：「$keyword」=====\n");

  // 1) 房间搜索
  print("----- searchRooms（房间） -----");
  try {
    final result = await site.searchRooms(keyword);
    print("hasMore=${result.hasMore}，返回 ${result.items.length} 个房间");
    for (var i = 0; i < result.items.length && i < 5; i++) {
      final r = result.items[i];
      print("  [${i + 1}] ${r.userName} | rid=${r.roomId} | 标题=${r.title}");
    }
    if (result.items.isEmpty) {
      print("  ⚠️ 无结果（可能是关键词无直播，或签名/风控问题）");
    }
  } catch (e, st) {
    print("  ❌ searchRooms 异常：$e");
    print(st);
  }

  print("");

  // 2) 主播搜索
  print("----- searchAnchors（主播） -----");
  try {
    final result = await site.searchAnchors(keyword);
    print("hasMore=${result.hasMore}，返回 ${result.items.length} 个主播");
    for (var i = 0; i < result.items.length && i < 5; i++) {
      final a = result.items[i];
      print("  [${i + 1}] ${a.userName} | rid=${a.roomId} | 直播中=${a.liveStatus}");
    }
    if (result.items.isEmpty) {
      print("  ⚠️ 无结果");
    }
  } catch (e, st) {
    print("  ❌ searchAnchors 异常：$e");
    print(st);
  }

  print("\n===== 测试结束 =====");
}
