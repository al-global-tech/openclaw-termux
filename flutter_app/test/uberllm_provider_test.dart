import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw/constants.dart';
import 'package:openclaw/models/ai_provider.dart';
import 'package:openclaw/services/provider_config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.channelName);
  late Map<String, dynamic> original;
  late Map<String, dynamic>? written;
  late bool useProot;
  late int directWrites;
  late int prootWrites;

  setUp(() {
    original = {
      'models': {
        'providers': {
          'custom': {
            'baseUrl': 'http://localhost:1234/v1',
            'models': [
              {
                'id': 'custom-model',
                'input': ['text', 'image'],
              },
            ],
          },
        },
      },
      'agents': {
        'defaults': {
          'model': {
            'primary': 'previous-model',
            'fallbacks': ['backup-model'],
          },
        },
      },
      'gateway': {'mode': 'remote', 'port': 19000},
    };
    written = null;
    useProot = false;
    directWrites = 0;
    prootWrites = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'runInProot':
              if (!useProot) throw PlatformException(code: 'proot-unavailable');
              // Execute the actual generated JavaScript with an in-memory filesystem.
              final command = args['command'] as String;
              expect(command, startsWith("node -e '"));
              final script = command
                  .substring(9, command.length - 1)
                  .replaceAll("'\\''", "'");
              final result = await Process.run('node', [
                '-e',
                '''
const vm = require('node:vm');
let written;
const fs = {
  readFileSync: () => process.argv[2],
  mkdirSync: () => {},
  writeFileSync: (path, content) => { written = content; },
};
vm.runInNewContext(process.argv[1], {
  require: (name) => {
    if (name === 'fs') return fs;
    if (name === 'path') return require('node:path');
    throw new Error('Unexpected module: ' + name);
  },
});
process.stdout.write(written);
''',
                script,
                jsonEncode(original),
              ]);
              expect(result.exitCode, 0, reason: result.stderr.toString());
              written =
                  jsonDecode(result.stdout as String) as Map<String, dynamic>;
              prootWrites++;
              return '';
            case 'readRootfsFile':
              return jsonEncode(original);
            case 'writeRootfsFile':
              directWrites++;
              written =
                  jsonDecode(args['content'] as String) as Map<String, dynamic>;
              return true;
            default:
              throw StateError('Unexpected native call: ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final proot in [false, true]) {
    test('saves an UberLLM model through ${proot ? 'proot' : 'fallback'}',
        () async {
      useProot = proot;
      await ProviderConfigService.saveProviderConfig(
        provider: AiProvider.uberllm,
        apiKey: 'test-only',
        model: 'deepseek/deepseek-v4.1-flash',
      );
      expect(written!['models']['providers']['uberllm'], {
        'apiKey': 'test-only',
        'baseUrl': 'https://api.uberllm.dev/v1',
        'api': 'openai-completions',
        'models': [
          {
            'id': 'deepseek/deepseek-v4.1-flash',
            'name': 'deepseek/deepseek-v4.1-flash',
          },
        ],
      });
      expect(
        written!['agents']['defaults']['model']['primary'],
        'uberllm/deepseek/deepseek-v4.1-flash',
      );
      expect(prootWrites, proot ? 1 : 0);
      expect(directWrites, proot ? 0 : 1);
    });
  }

  test('a model ID is saved as typed, even with a provider-like prefix',
      () async {
    await ProviderConfigService.saveProviderConfig(
      provider: AiProvider.ollama,
      apiKey: '',
      model: 'ollama/foo',
    );
    expect(
      written!['models']['providers']['ollama']['models'][0]['id'],
      'ollama/foo',
    );
    expect(
      written!['agents']['defaults']['model']['primary'],
      'ollama/ollama/foo',
    );
  });

  test('removal clears an active custom UberLLM model', () async {
    useProot = true;
    original['agents']['defaults']['model']['primary'] =
        'uberllm/qwen/qwen3-coder';
    original['models']['providers']['uberllm'] = {
      'models': [
        {'id': 'qwen/qwen3-coder'},
      ],
    };
    await ProviderConfigService.removeProviderConfig(
      provider: AiProvider.uberllm,
    );
    expect(prootWrites, 1);
    expect(written!['models']['providers'].containsKey('uberllm'), isFalse);
    expect(
      written!['agents']['defaults']['model'].containsKey('primary'),
      isFalse,
    );
  });

  test('removal keeps another provider\'s active model', () async {
    useProot = true;
    original['models']['providers']['uberllm'] = {
      'models': [
        {'id': 'qwen/qwen3-coder'},
      ],
    };
    await ProviderConfigService.removeProviderConfig(
      provider: AiProvider.uberllm,
    );
    expect(written!['models']['providers'].containsKey('uberllm'), isFalse);
    expect(
      written!['agents']['defaults']['model']['primary'],
      'previous-model',
    );
  });
}
