/// What the whole app shares: the workspace, and the card if one is plugged in.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai/ai_settings.dart';
import 'ai/story_service.dart';
import 'card/card_target.dart';
import 'card/toy_card.dart';
import 'store/workspace.dart';

enum CardState { none, connecting, connected, missing }

class AppState extends ChangeNotifier {
  AppState._(this.workspace, this.ai) : stories = StoryService(workspace, ai);

  final Workspace workspace;

  /// The Gemini key and models, and the AI stories made with them.
  final AiSettings ai;
  final StoryService stories;

  /// The bottom tab the shell should show. Anything can ask — "Send to toy"
  /// after a story is made is a jump to the Card tab from three screens deep.
  final ValueNotifier<int> tab = ValueNotifier(0);

  CardTarget? _card;
  CardState _state = CardState.none;
  String? _lastError;

  CardTarget? get card => _card;
  CardInfo? get cardInfo => _card?.info;
  CardState get cardState => _state;
  String? get lastError => _lastError;

  static Future<AppState> load() async {
    final workspace = await Workspace.open();
    final state = AppState._(workspace, await AiSettings.load());
    workspace.addListener(state.notifyListeners);

    // Earlier builds remembered a card reader here and reopened it on launch,
    // which could just as well be a folder on the phone. The card is reached
    // through the toy now; drop the old grant so nothing resurrects it.
    final docs = await getApplicationDocumentsDirectory();
    final legacy = File(p.join(docs.path, 'card-link.json'));
    if (await legacy.exists()) unawaited(legacy.delete());
    return state;
  }

  /// True when the card we are talking to is inside the toy rather than a
  /// reader — the UI offers different ways out of the two.
  bool get cardIsToy => _card is ToyCard;

  /// Join the toy's WiFi and talk to the card without taking it out. Unlike a
  /// reader this is never restored on launch: nothing should silently move the
  /// phone off its own network.
  Future<ToyJoin> connectToy() async {
    _lastError = null;
    _state = CardState.connecting;
    notifyListeners();

    ToyJoin outcome;
    try {
      outcome = await ToyCard.join();
      if (outcome == ToyJoin.refused) {
        _state = _card == null ? CardState.none : CardState.connected;
        notifyListeners();
        return outcome;
      }
      // On [ToyJoin.manual] the user joined from system settings themselves, so
      // the toy may well be there either way — ask before giving up.
      await _card?.release();
      _card = await ToyCard.connect();
      _state = CardState.connected;
    } on CardUnavailable catch (e) {
      _lastError = e.message;
      _card = null;
      _state = CardState.none;
      notifyListeners();
      return ToyJoin.refused;
    }
    notifyListeners();
    return outcome;
  }

  /// Refresh free space and confirm the card is still there.
  Future<void> refreshCard() async {
    final card = _card;
    if (card == null) return;
    try {
      final fresh = await card.refresh();
      if (fresh == null) {
        _card = null;
        _state = CardState.missing;
      } else {
        _card = fresh;
        _state = CardState.connected;
      }
    } on CardUnavailable {
      _card = null;
      _state = CardState.missing;
    }
    notifyListeners();
  }

  /// Hand the toy its card back: it drops its WiFi and rescans.
  Future<void> disconnect() async {
    await _card?.release();
    _card = null;
    _state = CardState.none;
    notifyListeners();
  }


  void reportError(String message) {
    _lastError = message;
    notifyListeners();
  }

  @override
  void dispose() {
    workspace.removeListener(notifyListeners);
    stories.dispose();
    tab.dispose();
    super.dispose();
  }
}

/// Hands the shared state down the tree and rebuilds listeners on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope?.notifier != null, 'No AppScope above this widget');
    return scope!.notifier!;
  }

  /// For callbacks that only act on the state and do not need a rebuild.
  static AppState read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope?.notifier != null, 'No AppScope above this widget');
    return scope!.notifier!;
  }
}
