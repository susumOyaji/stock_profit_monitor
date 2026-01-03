import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(400, 80),
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
    _loadData();
    // Start demo price updates
    _priceUpdateTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_isDemoMode) {
        _fetchRealtimePrices();
      }
    });
    _autoScrollTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _autoScroll();
    });
    // _updateTrayTooltip();
  }

  Future<void> _initTray() async {
    await trayManager.setIcon('assets/images/app_icon.png');
    Menu menu = Menu(
      items: [
        MenuItem(key: 'toggle_demo', label: 'Toggle Demo Mode'),
        MenuItem(key: 'show_json', label: 'Show Raw JSON'),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: 'Exit'),
      ],
    );
    await trayManager.setContextMenu(menu);

    // Initialize tooltip
    // _updateTrayTooltip();
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

  // TrayListener methods
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
        formattedJson = 'Error formatting JSON:\n$e';
      }
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Last JSON Response'),
          content: Scrollbar(
            child: SingleChildScrollView(
              child: Text(formattedJson),
            ),
          ),
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


  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('positions');
    if (data != null) {
      final List<dynamic> jsonList = jsonDecode(data);
      setState(() {
        _positions = jsonList.map((e) => StockPosition.fromJson(e)).toList();
      });
    } else {
      // Add default dummy data
      setState(() {
        _positions = [
          StockPosition(symbol: '^DJI', quantity: 1, purchasePrice: 35000.0, currentPrice: 35500.0, currency: 'USD'),
          StockPosition(symbol: '998407.O', quantity: 100, purchasePrice: 2500.0, currentPrice: 2550.0, currency: 'JPY'),
        ];
      });
    }
  }



  void _fetchRealtimePrices() async {
    if (_positions.isEmpty) return;

    final symbols = _positions.map((p) => p.symbol).join(',');
    final uri = Uri.parse('https://preloaded-webview.pages.dev?symbols=$symbols');

    try {
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        setState(() {
          _lastJsonResponse = response.body;
        });

        final List<dynamic> jsonResponse = jsonDecode(response.body);
        setState(() {
          for (var jsonItem in jsonResponse) {
            final symbol = jsonItem['symbol'];
            final price = jsonItem['price'];
            if (symbol != null && price != null) {
              // Manually find the position to avoid firstWhere's orElse type issue
              StockPosition? foundPosition;
              for (var p in _positions) {
                if (p.symbol == symbol) {
                  foundPosition = p;
                  break;
                }
              }
              if (foundPosition != null) {
                foundPosition.currentPrice = price.toDouble();
              }
            }
          }
        });
      } else {
        // print('Failed to fetch prices: ${response.statusCode}');
      }
    } catch (e) {
      // print('Error fetching prices: $e');
    }
  }

  // void _updateTrayTooltip() async {
  //   if (_positions.isEmpty) {
  //     await trayManager.setToolTip('Stock Profit Monitor - No positions');
  //     return;
  //   }
  //
  //   // Calculate total P&L
  //   double totalPnL = _positions.fold(0, (sum, item) => sum + item.profitOrLoss);
  //   String totalPnLStr = NumberFormat.simpleCurrency().format(totalPnL);
  //   String totalPrefix = totalPnL >= 0 ? '▲' : '▼';
  //
  //   // Cycle through positions for scrolling effect
  //   if (_tooltipIndex >= _positions.length) {
  //     _tooltipIndex = 0;
  //   }
  //
  //   final position = _positions[_tooltipIndex];
  //   String positionPnL = NumberFormat.simpleCurrency().format(position.profitOrLoss);
  //   String positionPrefix = position.profitOrLoss >= 0 ? '▲' : '▼';
  //
  //   String tooltip = 'Total: $totalPrefix $totalPnLStr | ${position.symbol}: $positionPrefix $positionPnL';
  //
  //   await trayManager.setToolTip(tooltip);
  //
  //   _tooltipIndex++;
  // }

  void _autoScroll() {
    if (!_scrollController.hasClients || _positions.length <= 1) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    // Scroll by half the viewport width to show some context
    final scrollAmount = _scrollController.position.viewportDimension / 2;

    double nextScroll = currentScroll + scrollAmount;
    if (nextScroll > maxScroll) {
      nextScroll = 0;
    }

    _scrollController.animateTo(
      nextScroll,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }



  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRRect(
          borderRadius: BorderRadius.circular(12.0),
          child: Container(
            color: Colors.black.withAlpha(179),
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              itemCount: _positions.length,
              itemBuilder: (context, index) {
                final item = _positions[index];
                final pnlColor = item.profitOrLoss >= 0 ? Colors.green : Colors.red;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.symbol,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        NumberFormat.simpleCurrency(name: item.currency).format(item.profitOrLoss),
                        style: TextStyle(
                          color: pnlColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        NumberFormat.simpleCurrency(name: item.currency).format(item.currentPrice),
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
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
  final String currency;

  StockPosition({
    required this.symbol,
    required this.quantity,
    required this.purchasePrice,
    required this.currentPrice,
    required this.currency,
  });

  double get profitOrLoss => (currentPrice - purchasePrice) * quantity;

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'quantity': quantity,
    'purchasePrice': purchasePrice,
    'currentPrice': currentPrice,
    'currency': currency,
  };

  factory StockPosition.fromJson(Map<String, dynamic> json) {
    return StockPosition(
      symbol: json['symbol'],
      quantity: json['quantity'],
      purchasePrice: json['purchasePrice'],
      currentPrice: json['currentPrice'],
      currency: json['currency'] ?? 'USD', // Default to USD if currency is not specified
    );
  }
}
