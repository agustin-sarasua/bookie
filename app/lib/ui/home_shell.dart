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
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A card reader is plugged and unplugged while the app is in the
    // background as often as not, so re-check on the way back in.
    if (state == AppLifecycleState.resumed && mounted) {
      AppScope.read(context).reconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const TagsPage(),
          const LanguagesPage(),
          CardPage(isVisible: _index == 2),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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
