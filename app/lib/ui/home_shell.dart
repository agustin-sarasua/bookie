import 'package:flutter/material.dart';

import '../app_state.dart';
import 'card_page.dart';
import 'languages_page.dart';
import 'tags_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  ValueNotifier<int>? _tab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tab ??= AppScope.read(context).tab..addListener(_onTab);
  }

  void _onTab() => setState(() {});

  @override
  void dispose() {
    _tab?.removeListener(_onTab);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The toy drops its WiFi on any button press, or after five quiet
    // minutes — check it is still there on the way back in.
    if (state == AppLifecycleState.resumed && mounted) {
      AppScope.read(context).refreshCard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _tab?.value ?? 0;
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          const TagsPage(),
          const LanguagesPage(),
          CardPage(isVisible: index == 2),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => _tab?.value = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.nfc_outlined),
            selectedIcon: Icon(Icons.nfc),
            label: 'Tags',
          ),
          NavigationDestination(
            icon: Icon(Icons.translate_outlined),
            selectedIcon: Icon(Icons.translate),
            label: 'Languages',
          ),
          NavigationDestination(
            icon: Icon(Icons.sd_card_outlined),
            selectedIcon: Icon(Icons.sd_card),
            label: 'Card',
          ),
        ],
      ),
    );
  }
}
