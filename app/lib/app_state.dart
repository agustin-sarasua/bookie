/// What the whole app shares: the workspace, and the card if one is plugged in.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'card/card_target.dart';
import 'card/toy_card.dart';
import 'store/workspace.dart';

enum CardState { none, connecting, connected, missing }

class AppState extends ChangeNotifier {
  AppState._(this.workspace, this._linkFile);

  final Workspace workspace;
  final File _linkFile;

  CardTarget? _card;
  CardState _state = CardState.none;
  String? _lastError;

  CardTarget? get card => _card;
  CardInfo? get cardInfo => _card?.info;
  CardState get cardState => _state;
  String? get lastError => _lastError;

  static Future<AppState> load() async {
    final workspace = await Workspace.open();
    final docs = await getApplicationDocumentsDirectory();
    final state = AppState._(
      workspace,
      File(p.join(docs.path, 'card-link.json')),
    );
    workspace.addListener(state.notifyListeners);
    unawaited(state.reconnect());
    return state;
  }

  /// Try the card we used last time. Quiet on failure: not having a reader
  /// plugged in is the normal state of the world, not an error to shout about.
  Future<void> reconnect() async {
    final handle = await _savedHandle();
    if (handle == null) return;

    _state = CardState.connecting;
    notifyListeners();
    try {
      final info = await ReaderCard.restore(handle);
      if (info == null) {
        _card = null;
        _state = CardState.missing;
      } else {
        _card = ReaderCard(info);
        _state = CardState.connected;
      }
    } on CardUnavailable {
      _card = null;
      _state = CardState.missing;
    }
    notifyListeners();
  }

  /// Ask the user to point at the card. Returns false if they backed out.
  Future<bool> connectCard() async {
    _lastError = null;
    _state = CardState.connecting;
    notifyListeners();
    try {
      final info = await ReaderCard.pick();
      if (info == null) {
        _state = _card == null ? CardState.none : CardState.connected;
        notifyListeners();
        return false;
      }
      _card = ReaderCard(info);
      _state = CardState.connected;
      await _linkFile.writeAsString(jsonEncode(info.toJson()));
      notifyListeners();
      return true;
    } on CardUnavailable catch (e) {
      _lastError = e.message;
      _state = CardState.none;
      notifyListeners();
      return false;
    }
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

  Future<void> forgetCard() async {
    // Only a reader's grant is on disk. Disconnecting from the toy should not
    // cost you the card reader you set up last week.
    final wasReader = _card is ReaderCard;
    await _card?.release();
    _card = null;
    _state = CardState.none;
    if (wasReader && await _linkFile.exists()) await _linkFile.delete();
    notifyListeners();
  }

  void reportError(String message) {
    _lastError = message;
    notifyListeners();
  }

  Future<String?> _savedHandle() async {
    if (!await _linkFile.exists()) return null;
    try {
      final json = jsonDecode(await _linkFile.readAsString()) as Map;
      return json['handle'] as String?;
    } on Object {
      return null;
    }
  }

  @override
  void dispose() {
    workspace.removeListener(notifyListeners);
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
