import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides(); // SSL証明書エラーを回避するための設定を追加
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(400, 100),
    center: true,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.setAsFrameless();
    await windowManager.setPreventClose(true);
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stock Profit Monitor',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.green), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WindowListener, TrayListener {
  List<StockPosition> _positions = [];
  Timer? _priceUpdateTimer;
  final ScrollController _scrollController = ScrollController();
  Timer? _autoScrollTimer;
  bool _isWindowVisible = true;
  bool _isDemoMode = true;
  String? _lastJsonResponse;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
    _loadData().then((_) {
      _fetchRealtimePrices(); // データ読み込み直後に一度取得する
    });

    // 60秒ごとの定期更新
    _priceUpdateTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (_isDemoMode) {
        _fetchRealtimePrices();
      }
    });
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      _autoScroll();
    });
  }

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/images/app_icon.png');
    Menu menu = Menu(
      items: [
        MenuItem(key: 'manage_positions', label: 'Manage Positions'),
        MenuItem(key: 'toggle_demo', label: 'Toggle Demo Mode'),
        MenuItem(key: 'show_json', label: 'Show Raw JSON'),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: 'Exit'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _priceUpdateTimer?.cancel();
    _autoScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    await windowManager.minimize();
  }

  @override
  void onTrayIconMouseDown() {
    if (_isWindowVisible) {
      windowManager.hide();
    } else {
      windowManager.show();
    }
    setState(() {
      _isWindowVisible = !_isWindowVisible;
    });
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'toggle_demo') {
      setState(() {
        _isDemoMode = !_isDemoMode;
      });
    } else if (menuItem.key == 'show_json') {
      _showJsonDialog();
    } else if (menuItem.key == 'manage_positions') {
      _showEditDialog();
    } else if (menuItem.key == 'exit_app') {
      windowManager.destroy();
    }
  }

  void _showJsonDialog() async {
    final originalSize = await windowManager.getSize();
    await windowManager.setSize(const Size(600, 400));

    String formattedJson = 'No data received yet.';
    if (_lastJsonResponse != null) {
      try {
        final jsonObject = jsonDecode(_lastJsonResponse!);
        formattedJson = const JsonEncoder.withIndent('  ').convert(jsonObject);
      } catch (e) {
        formattedJson = 'Raw Response (Not JSON):\n${_lastJsonResponse!}\n\nFormat Error:\n$e';
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Last JSON Response'),
          content: Scrollbar(child: SingleChildScrollView(child: Text(formattedJson))),
          actions: <Widget>[
            TextButton(
              child: const Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );

    await windowManager.setSize(originalSize);
  }

  void _showEditDialog() async {
    final originalSize = await windowManager.getSize();
    await windowManager.setSize(const Size(600, 500));

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Manage Positions'),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: _positions.length,
                        itemBuilder: (context, index) {
                          final pos = _positions[index];
                          return Card(
                            child: ListTile(
                              title: Text(pos.symbol),
                              subtitle: Text('Qty: ${pos.quantity}, Price: ${pos.purchasePrice} (${pos.currency})'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, color: Colors.blue),
                                    onPressed: () {
                                      _showAddSimpleDialog(setDialogState, position: pos, index: index);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, color: Colors.red),
                                    onPressed: () {
                                      setDialogState(() {
                                        _positions.removeAt(index);
                                      });
                                      setState(() {});
                                      _saveData();
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(),
                    const Text('Actions', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () => _showAddSimpleDialog(setDialogState),
                      icon: const Icon(Icons.add),
                      label: const Text('Add New Position'),
                    ),
                  ],
                ),
              ),
              actions: [TextButton(child: const Text('Close'), onPressed: () => Navigator.of(context).pop())],
            );
          },
        );
      },
    );

    await windowManager.setSize(originalSize);
  }

  void _showAddSimpleDialog(StateSetter setDialogState, {StockPosition? position, int? index}) {
    final bool isEditing = position != null;
    final symbolController = TextEditingController(text: position?.symbol ?? '');
    final qtyController = TextEditingController(text: position?.quantity.toString() ?? '');
    final priceController = TextEditingController(text: position?.purchasePrice.toString() ?? '');
    String currency = position?.currency ?? 'JPY';

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setSubState) => AlertDialog(
                  title: Text(isEditing ? 'Edit Position' : 'Add Position'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: symbolController,
                          decoration: const InputDecoration(labelText: 'Symbol (e.g. 6758.T)'),
                        ),
                        TextField(
                          controller: qtyController,
                          decoration: const InputDecoration(labelText: 'Quantity'),
                          keyboardType: TextInputType.number,
                        ),
                        TextField(
                          controller: priceController,
                          decoration: const InputDecoration(labelText: 'Purchase Price'),
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: currency,
                          decoration: const InputDecoration(labelText: 'Currency'),
                          items: ['JPY', 'USD'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                          onChanged: (v) {
                            setSubState(() {
                              currency = v!;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    TextButton(
                      onPressed: () {
                        final symbol = symbolController.text.toUpperCase();
                        final qty = int.tryParse(qtyController.text) ?? 0;
                        final price = double.tryParse(priceController.text) ?? 0.0;

                        if (symbol.isNotEmpty) {
                          setDialogState(() {
                            final newPos = StockPosition(
                              symbol: symbol,
                              quantity: qty,
                              purchasePrice: price,
                              currentPrice: isEditing ? position.currentPrice : 0.0,
                              priceChange: isEditing ? position.priceChange : 0.0,
                              priceChangeRate: isEditing ? position.priceChangeRate : 0.0,
                              currency: currency,
                            );
                            if (isEditing && index != null) {
                              _positions[index] = newPos;
                            } else {
                              _positions.add(newPos);
                            }
                          });
                          setState(() {});
                          _saveData();
                          _fetchRealtimePrices();
                          Navigator.pop(context);
                        }
                      },
                      child: Text(isEditing ? 'Update' : 'Add'),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    final String data = jsonEncode(_positions.map((e) => e.toJson()).toList());
    await prefs.setString('positions', data);
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('positions');
    if (data != null) {
      final List<dynamic> jsonList = jsonDecode(data);
      setState(() {
        _positions = jsonList.map((e) => StockPosition.fromJson(e)).toList();
      });
    } else {
      setState(() {
        _positions = [
          StockPosition(symbol: '^DJI', quantity: 1, purchasePrice: 48000.0, currentPrice: 0.0, currency: 'USD'),
          StockPosition(symbol: '998407.O', quantity: 100, purchasePrice: 50000.0, currentPrice: 0.0, currency: 'JPY'),
          StockPosition(symbol: '6758.T', quantity: 10, purchasePrice: 14000.0, currentPrice: 0.0, currency: 'JPY'),
          StockPosition(symbol: '5016.T', quantity: 100, purchasePrice: 800.0, currentPrice: 0.0, currency: 'JPY'),
        ];
      });
    }
  }

  void _fetchRealtimePrices() async {
    if (_positions.isEmpty) return;

    final symbols = _positions.map((p) => p.symbol).join(',');
    final uri = Uri.https('preloaded_state.sumitomo0210.workers.dev', '/', {'code': symbols});

    try {
      final response = await http.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      );

      if (response.statusCode == 200) {
        setState(() {
          _lastJsonResponse = response.body;
        });

        final List<dynamic> jsonResponse = jsonDecode(response.body);
        setState(() {
          for (var jsonItem in jsonResponse) {
            final symbol = jsonItem['code'];
            final data = jsonItem['data'];
            if (symbol != null && data != null && data['price'] != null) {
              final priceStr = data['price'].toString().replaceAll(',', '');
              final price = double.tryParse(priceStr);

              final changeStr = data['price_change']?.toString().replaceAll(',', '') ?? '0.0';
              final change = double.tryParse(changeStr) ?? 0.0;

              final rateStr = data['price_change_rate']?.toString().replaceAll(',', '').replaceAll('%', '') ?? '0.0';
              final rate = double.tryParse(rateStr) ?? 0.0;

              final mktCap = data['market_cap']?.toString() ?? '-';

              if (price != null) {
                for (var p in _positions) {
                  if (p.symbol == symbol) {
                    p.currentPrice = price;
                    p.priceChange = change;
                    p.priceChangeRate = rate;
                    p.marketCap = mktCap;
                    break;
                  }
                }
              }
            }
          }
        });
      } else {
        setState(() {
          _lastJsonResponse = 'HTTPエラー: ${response.statusCode}\nレスポンス: ${response.body}';
        });
      }
    } catch (e) {
      String errorMessage = '通信エラー: $e';
      if (e is SocketException) {
        errorMessage = 'ネットワーク接続エラー (SocketException): ${e.message}';
      } else if (e is HandshakeException) {
        errorMessage = 'SSL証明書エラー (HandshakeException): ${e.message}';
      }
      setState(() {
        _lastJsonResponse = errorMessage;
      });
    }
  }

  void _autoScroll() {
    if (!_scrollController.hasClients || _positions.isEmpty) return;
    final double scrollSpeed = 1.0;
    double nextScroll = _scrollController.offset + scrollSpeed;
    if (nextScroll >= _scrollController.position.maxScrollExtent) {
      _scrollController.jumpTo(0);
    } else {
      _scrollController.jumpTo(nextScroll);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRRect(
          borderRadius: BorderRadius.circular(12.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(179),
              border: Border.all(color: Colors.orange, width: 1.0),
              borderRadius: BorderRadius.circular(12.0),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              itemCount: (_positions.length + 1) * 10,
              itemBuilder: (context, index) {
                final listLen = _positions.length + 1;
                final localIndex = index % listLen;
                // トータル情報の表示
                if (localIndex == _positions.length) {
                  double totalJPY = 0;
                  double totalUSD = 0;
                  double valueJPY = 0;
                  double valueUSD = 0;

                  for (var p in _positions) {
                    // 指数は合計計算から除外
                    if (p.symbol == '^DJI' || p.symbol == '998407.O') continue;

                    if (p.currency == 'JPY') {
                      totalJPY += p.profitOrLoss;
                      valueJPY += p.marketValue;
                    }
                    if (p.currency == 'USD') {
                      totalUSD += p.profitOrLoss;
                      valueUSD += p.marketValue;
                    }
                  }

                  final formatter = NumberFormat.decimalPattern();

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.account_balance_wallet, color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        const Text(
                          'TOTAL:',
                          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const SizedBox(width: 12),
                        // JPY Total
                        if (valueJPY != 0 || totalJPY != 0) ...[
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '資産: ¥${formatter.format(valueJPY.toInt())}',
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                              Text(
                                '損益: ${totalJPY >= 0 ? "+¥" : "-¥"}${formatter.format(totalJPY.abs().toInt())}',
                                style: TextStyle(
                                  color: totalJPY >= 0 ? Colors.greenAccent : Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 20),
                        ],
                        // USD Total
                        if (valueUSD != 0 || totalUSD != 0) ...[
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '資産: US\$${formatter.format(valueUSD.toInt())}',
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                              Text(
                                '損益: ${totalUSD >= 0 ? "+US\$" : "-US\$"}${formatter.format(totalUSD.abs().toInt())}',
                                style: TextStyle(
                                  color: totalUSD >= 0 ? Colors.greenAccent : Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  );
                }

                final item = _positions[localIndex];
                final bool isIndex = item.symbol == '^DJI' || item.symbol == '998407.O';
                final changeColor = item.priceChange >= 0 ? Colors.greenAccent : Colors.redAccent;
                final pnl = item.profitOrLoss;
                final pnlColor = pnl >= 0 ? Colors.greenAccent : Colors.redAccent;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.symbol,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          if (!isIndex)
                            Text('${item.quantity}株', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            NumberFormat.simpleCurrency(name: item.currency).format(item.currentPrice),
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                          if (!isIndex && item.quantity > 0)
                            Text(
                              '時価: ${NumberFormat.simpleCurrency(name: item.currency, decimalDigits: 0).format(item.marketValue)}',
                              style: const TextStyle(color: Colors.grey, fontSize: 9),
                            ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${item.priceChange >= 0 ? "+" : ""}${NumberFormat.decimalPattern().format(item.priceChange)}',
                                style: TextStyle(color: changeColor, fontSize: 10),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '(${item.priceChangeRate >= 0 ? "+" : ""}${item.priceChangeRate.toStringAsFixed(2)}%)',
                                style: TextStyle(color: changeColor, fontSize: 10),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (!isIndex && item.quantity > 0) ...[
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: pnlColor.withAlpha(50),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${pnl >= 0 ? "+" : ""}${NumberFormat.decimalPattern().format(pnl.toInt())}',
                            style: TextStyle(color: pnlColor, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class StockPosition {
  final String symbol;
  int quantity;
  double purchasePrice;
  double currentPrice;
  double priceChange;
  double priceChangeRate;
  String marketCap;
  final String currency;

  StockPosition({
    required this.symbol,
    required this.quantity,
    required this.purchasePrice,
    required this.currentPrice,
    this.priceChange = 0.0,
    this.priceChangeRate = 0.0,
    this.marketCap = '-',
    required this.currency,
  });

  double get profitOrLoss => (currentPrice - purchasePrice) * quantity;
  double get marketValue => currentPrice * quantity;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'quantity': quantity,
    'purchasePrice': purchasePrice,
    'currentPrice': currentPrice,
    'priceChange': priceChange,
    'priceChangeRate': priceChangeRate,
    'marketCap': marketCap,
    'currency': currency,
  };

  factory StockPosition.fromJson(Map<String, dynamic> json) {
    return StockPosition(
      symbol: json['symbol'],
      quantity: json['quantity'],
      purchasePrice: json['purchasePrice'],
      currentPrice: json['currentPrice'],
      priceChange: (json['priceChange'] ?? 0.0).toDouble(),
      priceChangeRate: (json['priceChangeRate'] ?? 0.0).toDouble(),
      marketCap: json['marketCap'] ?? '-',
      currency: json['currency'] ?? 'USD',
    );
  }
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}
