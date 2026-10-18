import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/alert_state.dart';
import 'models/guidance_state.dart';
import 'services/api_service.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiService.instance.loadTokenFromStorage();
  runApp(const EldercareApp());
}

class EldercareApp extends StatelessWidget {
  const EldercareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // One shared guidance session for the whole app: the Elder
        // Guidance Screen writes to it, the Caregiver mirror card
        // (and any other screen) reads from it reactively.
        ChangeNotifierProvider(create: (_) => GuidanceState()),
        // Latest Component 4 alert decision, independent of guidance.
        ChangeNotifierProvider(create: (_) => AlertState()),
      ],
      child: MaterialApp(
        title: "AegisCare",
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const SplashScreen(),
      ),
    );
  }
}
