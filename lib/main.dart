/// Bakushi - local AI music source separation (StemDeck-style).
library;

import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[BAKUSHI] main: creating state');
  final state = AppState();
  // Render the UI FIRST so a slow startup step (e.g. a stalled audio
  // device) can never block the window from appearing.
  debugPrint('[BAKUSHI] main: runApp');
  runApp(BakushiApp(state: state));
  debugPrint('[BAKUSHI] main: state.init');
  await state.init();
  debugPrint('[BAKUSHI] main: init complete');
}

class BakushiApp extends StatelessWidget {
  final AppState state;
  const BakushiApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bakushi - local AI stem separation',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: HomePage(state: state),
    );
  }
}
