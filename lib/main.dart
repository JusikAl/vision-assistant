import 'package:flutter/material.dart';

import 'app_config.dart';
import 'live_camera_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AppConfig.load();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LiveCameraPage(),
    );
  }
}
