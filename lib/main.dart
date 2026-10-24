import 'package:flutter/material.dart';

void main() {
  runApp(const AnyPS5App());
}

class AnyPS5App extends StatelessWidget {
  const AnyPS5App({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'AnyPS5',
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('AnyPS5'))),
    );
  }
}
