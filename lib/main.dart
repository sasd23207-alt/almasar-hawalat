import 'package:flutter/material.dart';

/// PIPELINE PROOF ONLY. This screen is not the product.
/// Its job is to show that the build pipeline compiles a Flutter app.
void main() {
  runApp(const AlmasarApp());
}

class AlmasarApp extends StatelessWidget {
  const AlmasarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Almasar',
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Text(
              'المسار للحوالات\n(اختبار خط البناء فقط)',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24),
            ),
          ),
        ),
      ),
    );
  }
}
