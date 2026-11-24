import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartWardrobeApp());
}

const kCats = ['全部', '上衣', '下装', '连衣裙', '鞋子', '配饰'];
const kItemCats = ['上衣', '下装', '连衣裙', '鞋子', '配饰'];
const kSeasons = ['春', '夏', '秋', '冬'];
const kStyles = ['休闲', '通勤', '约会', '职场', '居家'];
const kColors = ['白色', '米白', '黑色', '卡其', '粉色', '浅蓝', '灰色', '杏色', '棕色', '红色', '绿色'];

class Garment {
  final int? id;
  final String name, category, color, seasons, style, imagePath;
  final bool fav;
  const Garment({
    this.id,
    required this.name,
    required this.category,
    required this.color,
    required this.seasons,
    required this.style,
    required this.imagePath,
    this.fav = false,
  });
  List<String> get seasonList => seasons.split(',').where((e) => e.isNotEmpty).toList();
  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'category': category,
        'color': color,
        'seasons': seasons,
        'style': style,
        'imagePath': imagePath,
        'fav': fav ? 1 : 0,
      };
  factory Garment.fromMap(Map<String, dynamic> m) => Garment(
        id: m['id'] as int?,
        name: m['name'] as String? ?? '单品',
        category: m['category'] as String? ?? '上衣',
        color: m['color'] as String? ?? '米白',
        seasons: m['seasons'] as String? ?? '春,秋',
        style: m['style'] as String? ?? '休闲',
        imagePath: m['imagePath'] as String? ?? '',
        fav: (m['fav'] as int? ?? 0) == 1,
      );
}

class WardrobeDb {
  static Database? _db;
  static Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'wardrobe.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (d, _) => d.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,category TEXT,color TEXT,seasons TEXT,style TEXT,imagePath TEXT,fav INTEGER)',
      ),
    );
    return _db!;
  }

  static Future<List<Garment>> all() async =>
      (await (await db).query('items', orderBy: 'id DESC')).map(Garment.fromMap).toList();
  static Future<void> add(Garment g) async => (await db).insert('items', g.toMap());
  static Future<void> toggleFav(Garment g) async =>
      (await db).update('items', {'fav': g.fav ? 0 : 1}, where: 'id=?', whereArgs: [g.id]);
  static Future<void> remove(int id) async =>
      (await db).delete('items', where: 'id=?', whereArgs: [id]);
}

Future<({String path, String color})> processGarmentImage(File src, bool removeBg) async {
  final decoded = img.decodeImage(await src.readAsBytes());
  if (decoded == null) throw Exception('无法识别图片格式');
  final resized = decoded.width > 900 || decoded.height > 900
      ? (decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 900)
          : img.copyResize(decoded, height: 900))
      : decoded;
  final rgba = resized.convert(numChannels: 4);
  if (removeBg && rgba.width > 8 && rgba.height > 8) {
    final w = rgba.width, h = rgba.height;
    final cs = [
      rgba.getPixel(2, 2),
      rgba.getPixel(w - 3, 2),
      rgba.getPixel(2, h - 3),
      rgba.getPixel(w - 3, h - 3),
    ];
    final bgR = cs.map((c) => c.r.toDouble()).reduce((a, b) => a + b) / 4;
    final bgG = cs.map((c) => c.g.toDouble()).reduce((a, b) => a + b) / 4;
    final bgB = cs.map((c) => c.b.toDouble()).reduce((a, b) => a + b) / 4;
    final vis = Uint8List(w * h);
    final q = Queue<int>();
    void push(int x, int y) {
      if (x < 0 || x >= w || y < 0 || y >= h) return;
      final i = y * w + x;
      if (vis[i] == 1) return;
      final px = rgba.getPixel(x, y);
      if ((px.r - bgR).abs() + (px.g - bgG).abs() + (px.b - bgB).abs() < 86) {
        vis[i] = 1;
        q.add(i);
      }
    }
    for (int x = 0; x < w; x += 2) {
      push(x, 0);
      push(x, h - 1);
    }
    for (int y = 0; y < h; y += 2) {
      push(0, y);
      push(w - 1, y);
    }
    int cleared = 0;
    while (q.isNotEmpty) {
      final i = q.removeFirst();
      final x = i % w, y = i ~/ w;
      rgba.setPixelRgba(x, y, 0, 0, 0, 0);
      cleared++;
      push(x + 1, y);
      push(x - 1, y);
      push(x, y + 1);
      push(x, y - 1);
    }
    if (cleared > w * h * 0.92) {
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final px = rgba.getPixel(x, y);
          rgba.setPixelRgba(x, y, px.r, px.g, px.b, 255);
        }
      }
    }
  }
  double sr = 0, sg = 0, sb = 0;
  int cnt = 0;
  for (int y = rgba.height ~/ 4; y < rgba.height * 3 ~/ 4; y += 4) {
    for (int x = rgba.width ~/ 4; x < rgba.width * 3 ~/ 4; x += 4) {
      final px = rgba.getPixel(x, y);
      if (px.a > 128) {
        sr += px.r;
        sg += px.g;
        sb += px.b;
        cnt++;
      }
    }
  }
  String color = '米白';
  if (cnt > 0) {
    final r = sr / cnt, g = sg / cnt, b = sb / cnt;
    final br = (r + g + b) / 3;
    final sat = max(r, max(g, b)) - min(r, min(g, b));
    if (br > 225 && sat < 24) {
      color = '白色';
    } else if (br > 195 && sat < 38) {
      color = '米白';
    } else if (br < 55 && sat < 35) {
      color = '黑色';
    } else if (sat < 28) {
      color = '灰色';
    } else if (b > r + 18 && b > g) {
      color = '浅蓝';
    } else if (r > 185 && g > 135 && r > b) {
      color = '粉色';
    } else if (r > g + 35 && r > b + 35) {
      color = '红色';
    } else if (g > r + 15 && g > b + 15) {
      color = '绿色';
    } else if (r > g && g > b && br > 145) {
      color = '卡其';
    } else if (r > g && g > b) {
      color = '棕色';
    } else {
      color = '杏色';
    }
  }
  final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'clothes'));
  if (!await dir.exists()) await dir.create(recursive: true);
  final outPath = p.join(dir.path, 'g_${DateTime.now().millisecondsSinceEpoch}.png');
  await File(outPath).writeAsBytes(img.encodePng(rgba));
  return (path: outPath, color: color);
}

class SmartWardrobeApp extends StatelessWidget {
  const SmartWardrobeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '专属衣橱',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF9C7B69)),
        scaffoldBackgroundColor: const Color(0xFFFAF8F5),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0, _tick = 0;
  List<Garment> _tryList = [];
  void _goTry(List<Garment> items) => setState(() {
        _tryList = items;
        _tab = 2;
      });
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        WardrobePage(key: ValueKey('w$_tick'), onDirty: () => setState(() => _tick++), onTry: (g) => _goTry([g])),
        OutfitPage(key: ValueKey('o$_tick'), onTry: _goTry),
        TryOnPage(initial: _tryList),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFEEE6DF),
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.checkroom_outlined), label: '衣橱'),
          NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), label: '今日穿搭'),
          NavigationDestination(icon: Icon(Icons.camera_front_outlined), label: '魔镜试穿'),
        ],
      ),
    );
  }
}

class WardrobePage extends StatefulWidget {
  final VoidCallback onDirty;
  final void Function(Garment) onTry;
  const WardrobePage({super.key, required this.onDirty, required this.onTry});
  @override
  State<WardrobePage> createState() => _WardrobePageState();
}

class _WardrobePageState extends State<WardrobePage> {
  List<Garment> _items = [];
  String _cat = '全部', _q = '';
  String? _season;
  bool _favOnly = false;
  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    final l = await WardrobeDb.all();
    if (mounted) setState(() => _items = l);
  }
  @override
  Widget build(BuildContext context) {
    final list = _items.where((g) {
      if (_cat != '全部' && g.category != _cat) return false;
      if (_season != null && !g.seasonList.contains(_season)) return false;
      if (_favOnly && !g.fav) return false;
      if (_q.isNotEmpty && !g.name.contains(_q) && !g.color.contains(_q)) return false;
      return true;
    }).toList();
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF9C7B69),
        foregroundColor: Colors.white,
        onPressed: () async {
          final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AddGarmentPage()));
          if (ok == true) {
            await _load();
            widget.onDirty();
          }
        },
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 6),
            child: Row(children: [
              Text('衣橱（${_items.length}件）', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                icon: Icon(_favOnly ? Icons.favorite : Icons.favorite_border, color: _favOnly ? Colors.pink : null),
                onPressed: () => setState(() => _favOnly = !_favOnly),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: InputDecoration(
                hintText: '搜索衣服或颜色...',
                prefixIcon: const Icon(Icons.search, size: 18),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(children: [
              SizedBox(
                width: 78,
                child: ListView(padding: const EdgeInsets.symmetric(horizontal: 6), children: [
                  ...kCats.map((c) => _sideBtn(c, _cat == c, () => setState(() => _cat = c))),
                  const Divider(height: 18),
                  ...kSeasons.map((s) => _sideBtn(s, _season == s, () => setState(() => _season = _season == s ? null : s))),
                ]),
              ),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('点右下角 + 拍照或导入购物图'))
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(4, 4, 12, 80),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.74,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final g = list[i];
                          return GestureDetector(
                            onTap: () => widget.onTry(g),
                            onLongPress: () async {
                              if (g.id != null) {
                                await WardrobeDb.remove(g.id!);
                                await _load();
                                widget.onDirty();
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Expanded(
                                  child: Stack(children: [
                                    Center(child: File(g.imagePath).existsSync() ? Image.file(File(g.imagePath), fit: BoxFit.contain) : const Icon(Icons.checkroom)),
                                    Positioned(
                                      top: 0,
                                      right: 0,
                                      child: GestureDetector(
                                        onTap: () async {
                                          await WardrobeDb.toggleFav(g);
                                          await _load();
                                        },
                                        child: Icon(g.fav ? Icons.favorite : Icons.favorite_border, size: 18, color: g.fav ? Colors.pink : Colors.grey),
                                      ),
                                    ),
                                  ]),
                                ),
                                const SizedBox(height: 4),
                                Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                Text('${g.color} · ${g.seasons.replaceAll(",", "")}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _sideBtn(String text, bool on, VoidCallback tap) => GestureDetector(
        onTap: tap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: on ? const Color(0xFFEEE6DF) : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          alignment: Alignment.center,
          child: Text(text, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
        ),
      );
}

class AddGarmentPage extends StatefulWidget {
  const AddGarmentPage({super.key});
  @override
  State<AddGarmentPage> createState() => _AddGarmentPageState();
}

class _AddGarmentPageState extends State<AddGarmentPage> {
  final _name = TextEditingController(), _url = TextEditingController();
  String? _imgPath;
  String _cat = '上衣', _color = '米白', _style = '休闲';
  final _seasons = {'春', '秋'};
  bool _rmBg = true, _busy = false;

  Future<void> _pick(ImageSource src) async {
    final f = await ImagePicker().pickImage(source: src, imageQuality: 90);
    if (f != null) await _runProcess(File(f.path));
  }

  Future<void> _fromUrl() async {
    final u = _url.text.trim();
    if (!u.startsWith('http')) return;
    setState(() => _busy = true);
    try {
      final res = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 20));
      final tmp = File(p.join((await getTemporaryDirectory()).path, 'dl_${DateTime.now().millisecondsSinceEpoch}.jpg'));
      await tmp.writeAsBytes(res.bodyBytes);
      await _runProcess(tmp);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败：$e')));
      setState(() => _busy = false);
    }
  }

  Future<void> _runProcess(File f) async {
    setState(() => _busy = true);
    try {
      final r = await processGarmentImage(f, _rmBg);
      setState(() {
        _imgPath = r.path;
        _color = r.color;
        _busy = false;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('处理失败：$e')));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('录入衣服'), actions: [
        TextButton(
          onPressed: _busy || _imgPath == null
              ? null
              : () async {
                  await WardrobeDb.add(Garment(
                    name: _name.text.trim().isEmpty ? '$_color$_cat' : _name.text.trim(),
                    category: _cat,
                    color: _color,
                    seasons: _seasons.isEmpty ? '春,秋' : _seasons.join(','),
                    style: _style,
                    imagePath: _imgPath!,
                  ));
                  if (context.mounted) Navigator.pop(context, true);
                },
          child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          height: 200,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : _imgPath != null
                  ? Image.file(File(_imgPath!), fit: BoxFit.contain)
                  : const Center(child: Text('拍照 / 相册导入 / 粘贴购物图链接')),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => _pick(ImageSource.camera), icon: const Icon(Icons.camera_alt), label: const Text('拍照'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => _pick(ImageSource.gallery), icon: const Icon(Icons.photo), label: const Text('相册导入'))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _url, decoration: const InputDecoration(hintText: '粘贴购物网站图片链接', isDense: true))),
          TextButton(onPressed: _fromUrl, child: const Text('拉取')),
        ]),
        SwitchListTile(title: const Text('端侧免费自动去白底'), value: _rmBg, onChanged: (v) => setState(() => _rmBg = v)),
        TextField(controller: _name, decoration: const InputDecoration(labelText: '名称（留空自动命名）')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: kItemCats.map((c) => ChoiceChip(label: Text(c), selected: _cat == c, onSelected: (_) => setState(() => _cat = c))).toList()),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: kSeasons
              .map((s) => FilterChip(
                    label: Text(s),
                    selected: _seasons.contains(s),
                    onSelected: (v) => setState(() => v ? _seasons.add(s) : _seasons.remove(s)),
                  ))
              .toList(),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, children: kColors.map((c) => ChoiceChip(label: Text(c), selected: _color == c, onSelected: (_) => setState(() => _color = c))).toList()),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: kStyles.map((s) => ChoiceChip(label: Text(s), selected: _style == s, onSelected: (_) => setState(() => _style = s))).toList()),
      ]),
    );
  }
}

class OutfitPage extends StatefulWidget {
  final void Function(List<Garment>) onTry;
  const OutfitPage({super.key, required this.onTry});
  @override
  State<OutfitPage> createState() => _OutfitPageState();
}

class _OutfitPageState extends State<OutfitPage> {
  static const _cities = {
    '上海': (31.23, 121.47),
    '北京': (39.90, 116.40),
    '广州': (23.13, 113.26),
    '深圳': (22.54, 114.06),
    '成都': (30.57, 104.07),
    '杭州': (30.27, 120.15),
    '新加坡': (1.35, 103.82),
  };
  String _city = '上海', _mood = '约会';
  double? _temp;
  List<Garment> _all = [], _rec = [];
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _init();
  }
  Future<void> _init() async {
    _all = await WardrobeDb.all();
    await _loadWeather();
    _recommend();
  }
  Future<void> _loadWeather() async {
    try {
      final (lat, lon) = _cities[_city]!;
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': '$lat',
        'longitude': '$lon',
        'current': 'temperature_2m',
        'timezone': 'auto',
      });
      final res = await http.get(uri);
      final t = (jsonDecode(res.body)['current']['temperature_2m'] as num).toDouble();
      if (mounted) setState(() => _temp = t);
    } catch (_) {}
  }
  void _recommend() {
    if (_all.isEmpty) return;
    final t = _temp ?? 22;
    final season = t >= 26 ? '夏' : (t >= 18 ? '春' : (t >= 10 ? '秋' : '冬'));
    var pool = _all.where((g) => g.seasonList.contains(season)).toList();
    if (pool.isEmpty) pool = _all;
    Garment? pick(String cat) {
      final m = pool.where((g) => g.category == cat && g.style == _mood).toList();
      if (m.isNotEmpty) return m[_rng.nextInt(m.length)];
      final c = pool.where((g) => g.category == cat).toList();
      return c.isNotEmpty ? c[_rng.nextInt(c.length)] : null;
    }
    final out = <Garment>[];
    final dress = pick('连衣裙'), top = pick('上衣'), bot = pick('下装');
    if (dress != null && (top == null || _rng.nextBool())) {
      out.add(dress);
    } else {
      if (top != null) out.add(top);
      if (bot != null) out.add(bot);
    }
    final sh = pick('鞋子');
    if (sh != null) out.add(sh);
    if (out.isEmpty) out.add(_all[_rng.nextInt(_all.length)]);
    setState(() => _rec = out);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            const Text('今日智能穿搭', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            DropdownButton<String>(
              value: _city,
              items: _cities.keys.map((k) => DropdownMenuItem(value: k, child: Text(k))).toList(),
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _city = v);
                await _loadWeather();
                _recommend();
              },
            ),
          ]),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
            child: Text(_temp == null ? '正在获取免费实时天气...' : '$_city 当前 ${_temp!.toStringAsFixed(0)}°C · 已按温度自动筛季'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: kStyles
                .map((s) => ChoiceChip(
                      label: Text(s),
                      selected: _mood == s,
                      onSelected: (_) {
                        setState(() => _mood = s);
                        _recommend();
                      },
                    ))
                .toList(),
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Text('推荐组合', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(onPressed: _recommend, child: const Text('换一套')),
          ]),
          if (_rec.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('先去「衣橱」录入几件衣服吧'))
          else ...[
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.85, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: _rec.length,
              itemBuilder: (_, i) => Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Column(children: [
                  Expanded(child: Image.file(File(_rec[i].imagePath), fit: BoxFit.contain)),
                  Text(_rec[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: () => widget.onTry(_rec), icon: const Icon(Icons.auto_awesome), label: const Text('打开相机试穿这套')),
          ],
        ]),
      ),
    );
  }
}

class TryOnPage extends StatefulWidget {
  final List<Garment> initial;
  const TryOnPage({super.key, required this.initial});
  @override
  State<TryOnPage> createState() => _TryOnPageState();
}

class _TryOnPageState extends State<TryOnPage> {
  static const _vtoHost = 'kwai-kolors-kolors-virtual-try-on.hf.space';
  CameraController? _cam;
  List<CameraDescription> _cams = [];
  int _camIdx = 0, _cd = 0;
  List<Garment> _all = [];
  Garment? _active;
  bool _aiMode = false, _busy = false;
  Offset _off = Offset.zero;
  double _scale = 1.0, _alpha = 0.9;
  File? _aiImg;
  String? _err;

  @override
  void initState() {
    super.initState();
    _initCam();
    _load();
  }
  @override
  void didUpdateWidget(covariant TryOnPage old) {
    super.didUpdateWidget(old);
    if (widget.initial.isNotEmpty) _active = widget.initial.first;
  }
  Future<void> _load() async {
    _all = await WardrobeDb.all();
    if (mounted) {
      setState(() {
        if (widget.initial.isNotEmpty) {
          _active = widget.initial.first;
        } else if (_active == null && _all.isNotEmpty) {
          _active = _all.first;
        }
      });
    }
  }
  Future<void> _initCam() async {
    try {
      _cams = await availableCameras();
      if (_cams.isEmpty) return;
      _camIdx = _cams.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (_camIdx < 0) _camIdx = 0;
      await _openCam(_cams[_camIdx]);
    } catch (_) {}
  }
  Future<void> _openCam(CameraDescription d) async {
    await _cam?.dispose();
    final c = CameraController(d, ResolutionPreset.medium, enableAudio: false);
    await c.initialize();
    if (mounted) setState(() => _cam = c);
  }
  Future<void> _runFreeAi(File person) async {
    if (_active == null) return;
    setState(() {
      _busy = true;
      _err = null;
      _aiImg = null;
    });
    try {
      Future<String> up(File f) async {
        final req = http.MultipartRequest('POST', Uri.https(_vtoHost, '/gradio_api/upload'))
          ..files.add(await http.MultipartFile.fromPath('files', f.path));
        final s = await req.send().timeout(const Duration(seconds: 30));
        return (jsonDecode(await s.stream.bytesToString()) as List).first as String;
      }
      final p1 = await up(person), p2 = await up(File(_active!.imagePath));
      final call = await http.post(
        Uri.https(_vtoHost, '/gradio_api/call/tryon'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'data': [
            {'path': p1, 'meta': {'_type': 'gradio.FileData'}},
            {'path': p2, 'meta': {'_type': 'gradio.FileData'}},
            0,
            true,
          ]
        }),
      );
      final eid = jsonDecode(call.body)['event_id'];
      final sse = await http.get(Uri.https(_vtoHost, '/gradio_api/call/tryon/$eid')).timeout(const Duration(seconds: 90));
      String? url;
      for (final line in sse.body.split('\n').reversed) {
        if (line.startsWith('data:')) {
          try {
            final d = jsonDecode(line.substring(5).trim());
            if (d is List && d.isNotEmpty && d.first is Map) {
              url = d.first['url'] as String? ?? Uri.https(_vtoHost, '/gradio_api/file=${d.first['path']}').toString();
              break;
            }
          } catch (_) {}
        }
      }
      if (url == null) throw Exception('免费公共空间当前排队限流，请先用实时比划镜或稍后重试');
      final res = await http.get(Uri.parse(url));
      final out = File(p.join((await getTemporaryDirectory()).path, 'vto_${DateTime.now().millisecondsSinceEpoch}.png'));
      await out.writeAsBytes(res.bodyBytes);
      if (mounted) setState(() => _aiImg = out);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('实时比划')), ButtonSegment(value: true, label: Text('AI换装'))],
                selected: {_aiMode},
                onSelectionChanged: (s) => setState(() {
                  _aiMode = s.first;
                  _aiImg = null;
                  _err = null;
                }),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.cameraswitch, color: Colors.white),
                onPressed: () {
                  if (_cams.length > 1) _openCam(_cams[_camIdx = (_camIdx + 1) % _cams.length]);
                },
              ),
            ]),
          ),
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              if (_aiImg != null) Image.file(_aiImg!, fit: BoxFit.contain)
              else if (_cam != null && _cam!.value.isInitialized) CameraPreview(_cam!)
              else const Center(child: Text('摄像头初始化中...', style: TextStyle(color: Colors.white70))),
              if (!_aiMode && _active != null && File(_active!.imagePath).existsSync())
                GestureDetector(
                  onPanUpdate: (d) => setState(() => _off += d.delta),
                  child: Center(
                    child: Transform.translate(
                      offset: _off,
                      child: Transform.scale(scale: _scale, child: Opacity(opacity: _alpha, child: Image.file(File(_active!.imagePath), width: 220))),
                    ),
                  ),
                ),
              if (_cd > 0) Center(child: Text('$_cd', style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold))),
              if (_busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
              if (_err != null) Positioned(bottom: 10, left: 12, right: 12, child: Text(_err!, style: const TextStyle(color: Colors.amberAccent))),
            ]),
          ),
          Container(
            color: const Color(0xFF1C1917),
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              if (!_aiMode)
                Row(children: [
                  Expanded(child: Slider(min: 0.4, max: 2.0, value: _scale, onChanged: (v) => setState(() => _scale = v))),
                  Expanded(child: Slider(min: 0.3, max: 1.0, value: _alpha, onChanged: (v) => setState(() => _alpha = v))),
                ])
              else
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final f = await ImagePicker().pickImage(source: ImageSource.gallery);
                              if (f != null) await _runFreeAi(File(f.path));
                            },
                      child: const Text('选全身照'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy || _cam == null
                          ? null
                          : () async {
                              for (int i = 3; i >= 1; i--) {
                                setState(() => _cd = i);
                                await Future.delayed(const Duration(seconds: 1));
                              }
                              setState(() => _cd = 0);
                              final shot = await _cam!.takePicture();
                              await _runFreeAi(File(shot.path));
                            },
                      child: const Text('3秒抓拍试穿'),
                    ),
                  ),
                ]),
              const SizedBox(height: 6),
              SizedBox(
                height: 58,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _all.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => setState(() {
                      _active = _all[i];
                      _aiImg = null;
                    }),
                    child: Container(
                      width: 54,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _active?.id == _all[i].id ? Colors.orange : Colors.transparent, width: 2),
                      ),
                      child: Image.file(File(_all[i].imagePath), fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
}
