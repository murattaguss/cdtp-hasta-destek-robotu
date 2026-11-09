import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/live_monitor_screen.dart';
import 'screens/reports_screen.dart';
import 'services/task_evaluator.dart';
import 'services/telemetry_service.dart';
import 'widgets/qr_share_sheet.dart';
import 'widgets/robot_intro_splash.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  // kamera hareket yönü dikey ekrana göre hesaplandığı için uygulama dikey kullanılır
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CdtpPatientSupportApp());
}

class CdtpPatientSupportApp extends StatefulWidget {
  const CdtpPatientSupportApp({super.key});

  @override
  State<CdtpPatientSupportApp> createState() => _CdtpPatientSupportAppState();
}

class _CdtpPatientSupportAppState extends State<CdtpPatientSupportApp> {
  late final RobotSystemController _robotController;
  late final TaskEvaluatorService _evaluatorService;
  int _currentTabIndex = 0;
  bool _showIntroSplash = true;

  @override
  void initState() {
    super.initState();
    _robotController = RobotSystemController();
    _evaluatorService = TaskEvaluatorService(robotController: _robotController);
  }

  @override
  void dispose() {
    _evaluatorService.dispose();
    _robotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HDRG100',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFFF2D55),
          secondary: Color(0xFF34C759),
          tertiary: Color(0xFF007AFF),
          surface: Colors.white,
          onPrimary: Colors.white,
          onSurface: Color(0xFF1C1C1E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF2F2F7),
          foregroundColor: Color(0xFF1C1C1E),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          systemOverlayStyle: SystemUiOverlayStyle.dark,
        ),
      ),
      home: AnimatedBuilder(
        animation: Listenable.merge([_robotController, _evaluatorService]),
        builder: (navContext, _) {
          return Stack(
            children: [
              _buildScaffold(navContext),
              if (_showIntroSplash)
                Positioned.fill(
                  child: RobotIntroSplash(
                    onFinished: () {
                      if (mounted) {
                        setState(() => _showIntroSplash = false);
                      }
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildScaffold(BuildContext navContext) {
    final health = _robotController.connectionHealth;
    final bool isConnected = health == ConnectionHealth.connected1Hz;
    final bool isWaiting = health == ConnectionHealth.waitingForRobot;

    final Color badgeBg = isConnected
        ? const Color(0xFFE8F8ED)
        : (isWaiting ? const Color(0xFFE5E5EA) : const Color(0xFFFDECEC));
    final Color badgeFg = isConnected
        ? const Color(0xFF248A3D)
        : (isWaiting ? const Color(0xFF6C6C70) : const Color(0xFFD70015));

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 14,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE5E5EA), width: 0.8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/app_icon_1024.png',
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 9),
            const Text(
              'HDRG100',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1C1C1E),
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: badgeFg,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  health.badgeText,
                  style: TextStyle(
                    color: badgeFg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Builder(
            builder: (btnContext) => IconButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                QrAppShareSheet.show(btnContext);
              },
              icon: const Icon(Icons.qr_code_2_rounded, size: 24, color: Color(0xFF1C1C1E)),
              tooltip: 'QR ile Paylaş',
            ),
          ),
          IconButton(
            onPressed: _evaluatorService.isTestRunning
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    _robotController.resetRobotPosition();
                  },
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFFFF2D55)),
            tooltip: 'Konumu Sıfırla',
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: IndexedStack(
        index: _currentTabIndex,
        children: [
          LiveMonitorScreen(
            robotController: _robotController,
            evaluator: _evaluatorService,
          ),
          ImmutableReportsScreen(
            evaluator: _evaluatorService,
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(color: Color(0xFFE5E5EA), width: 0.8),
          ),
        ),
        child: NavigationBar(
          height: 60,
          backgroundColor: Colors.white,
          elevation: 0,
          indicatorColor: const Color(0xFFFFEBEF),
          selectedIndex: _currentTabIndex,
          onDestinationSelected: (idx) {
            if (idx != _currentTabIndex) {
              HapticFeedback.selectionClick();
              setState(() => _currentTabIndex = idx);
            }
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.favorite_border_rounded, color: Color(0xFF8E8E93)),
              selectedIcon: Icon(Icons.favorite_rounded, color: Color(0xFFFF2D55)),
              label: 'İzleme',
            ),
            NavigationDestination(
              icon: Badge(
                backgroundColor: const Color(0xFFFF2D55),
                textColor: Colors.white,
                label: Text('${_evaluatorService.immutableReports.length}'),
                child: const Icon(Icons.assignment_outlined, color: Color(0xFF8E8E93)),
              ),
              selectedIcon: Badge(
                backgroundColor: const Color(0xFFFF2D55),
                textColor: Colors.white,
                label: Text('${_evaluatorService.immutableReports.length}'),
                child: const Icon(Icons.assignment_rounded, color: Color(0xFFFF2D55)),
              ),
              label: 'Kayıtlar',
            ),
          ],
        ),
      ),
    );
  }
}
