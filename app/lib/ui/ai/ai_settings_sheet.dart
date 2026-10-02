/// Where the Gemini API key goes in.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/ai_settings.dart';
import '../../ai/gemini_client.dart';
import '../../app_state.dart';
import '../theme.dart';

const _keyUrl = 'https://aistudio.google.com/apikey';

/// Make sure there is a key before starting anything that needs one. Opens the
/// settings sheet when there is not, and says whether there is one now.
Future<bool> ensureAiReady(BuildContext context) async {
  final settings = AppScope.read(context).ai;
  if (settings.hasKey) return true;
  await showAiSettings(context, firstRun: true);
  return settings.hasKey;
}

Future<void> showAiSettings(BuildContext context, {bool firstRun = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AiSettingsSheet(firstRun: firstRun),
  );
}

class _AiSettingsSheet extends StatefulWidget {
  const _AiSettingsSheet({required this.firstRun});
  final bool firstRun;

  @override
  State<_AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends State<_AiSettingsSheet> {
  late final AiSettings _settings = AppScope.read(context).ai;
  late final _key = TextEditingController(text: _settings.usingBakedKey ? '' : _settings.apiKey);
  late final _storyModel = TextEditingController(text: _settings.storyModel);
  late final _speechModel = TextEditingController(text: _settings.speechModel);

  bool _obscure = true;
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _storyModel.dispose();
    _speechModel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _key.text.trim();
    setState(() {
      _checking = true;
      _error = null;
    });
    if (key.isNotEmpty) {
      final client = GeminiClient(apiKey: key);
      try {
        await client.check(_storyModel.text.trim().isEmpty ? defaultStoryModel : _storyModel.text.trim());
      } on AiException catch (e) {
        if (mounted) {
          setState(() {
            _checking = false;
            _error = e.message;
          });
        }
        return;
      } finally {
        client.close();
      }
    }
    await _settings.update(
      apiKey: key,
      storyModel: _storyModel.text,
      speechModel: _speechModel.text,
    );
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(key.isEmpty ? 'API key removed' : 'Story assistant is ready ✨')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: storyGradient(scheme),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Story assistant', style: theme.textTheme.titleLarge),
                      Text(
                        'Powered by Google Gemini',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              widget.firstRun
                  ? 'To write and narrate stories, Bookie Studio needs a Gemini API key. '
                        'It is free to create one, takes a minute, and stays on this phone.'
                  : 'Your key stays on this phone and is only sent to Google, with the '
                        'photos you choose. It never goes onto the card.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            _Step(
              n: 1,
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: 'Create a key at ',
                        children: [
                          TextSpan(
                            text: 'aistudio.google.com/apikey',
                            style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(text: _keyUrl));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied — open it in your browser')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const _Step(n: 2, child: Text('Paste it here')),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: _settings.usingBakedKey ? 'Using the key built into this app' : 'AIza…',
                prefixIcon: const Icon(Icons.key_rounded),
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Paste',
                      icon: const Icon(Icons.content_paste_rounded),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null) _key.text = data!.text!.trim();
                      },
                    ),
                    IconButton(
                      tooltip: _obscure ? 'Show' : 'Hide',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
              ),
              style: monoStyle(context, size: 14, color: scheme.onSurface),
            ),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Advanced', style: theme.textTheme.bodyMedium),
                children: [
                  TextField(
                    controller: _storyModel,
                    decoration: const InputDecoration(
                      labelText: 'Story model (reads the pages, writes the script)',
                      isDense: true,
                    ),
                    style: monoStyle(context, size: 14, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _speechModel,
                    decoration: const InputDecoration(
                      labelText: 'Voice model (narrates)',
                      isDense: true,
                    ),
                    style: monoStyle(context, size: 14, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _checking ? null : _save,
              icon: _checking
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: Text(_checking ? 'Checking the key…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.child});
  final int n;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.primary.withValues(alpha: 0.14),
            child: Text('$n', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}
