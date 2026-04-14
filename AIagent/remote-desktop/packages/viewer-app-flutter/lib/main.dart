import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'app_theme.dart';
import 'screens/dashboard_screen.dart';
import 'screens/waiting_screen.dart';
import 'services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 윈도우 매니저 초기화 (전체화면 제어용)
  await windowManager.ensureInitialized();
  await SupabaseService.initialize();
  runApp(const ViewerApp());
}

class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteCall-mini Viewer',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/waiting':
            final serverUrl =
                settings.arguments as String? ?? 'ws://10.2.107.45:8080';
            return MaterialPageRoute<void>(
              builder: (_) => WaitingScreen(serverUrl: serverUrl),
            );
          default:
            return MaterialPageRoute<void>(
              builder: (_) => const DashboardScreen(),
            );
        }
      },
    );
  }
}
