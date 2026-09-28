import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  runApp(BookieStudio(state: state));
}

class BookieStudio extends StatelessWidget {
  const BookieStudio({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Bookie Studio',
        debugShowCheckedModeBanner: false,
        theme: bookieTheme(Brightness.light),
        darkTheme: bookieTheme(Brightness.dark),
        home: const HomeShell(),
      ),
    );
  }
}
