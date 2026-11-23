import 'dart:convert';

class LogRedactor {
  LogRedactor._();

  static const int _maxJsonBodyChars = 256 * 1024;
  static const int _shortSecretLimit = 16;

  static const Set<String> _exactSensitiveHeaders = {
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'api-key',
    'x-goog-api-key',
    'x-subscription-token',
    'x-auth-token',
    'x-goog-iam-authorization-token',
    'cookie',
    'set-cookie',
  };

  static const List<String> _sensitiveNameNeedles = [
    'key',
    'token',
    'secret',
    'auth',
    'credential',
    'password',
    'signature',
    'session',
  ];

  static const Set<String> _bodyIgnoredNames = {
    'token',
    'tokens',
    'key',
    'keys',
    'session',
    'author',
    'authors',
  };

  static const List<String> _bodyStrongNeedles = [
    'secret',
    'password',
    'credential',
    'signature',
  ];

  static const Set<String> _sensitiveQueryKeys = {
    'key',
    'api_key',
    'apikey',
    'access_token',
    'token',
    'sig',
    'signature',
    'password',
    'x-amz-signature',
    'x-amz-credential',
  };

  static final RegExp _schemeRe = RegExp(
    r'^(Bearer|Basic|Token)(\s+)(.*)$',
    caseSensitive: false,
  );
  static final RegExp _alreadyMaskedRe = RegExp(
    r'^(?:\*\*\*\(len=\d+\)|.{3}\*\*\*.{4}\(len=\d+\))$',
  );
  static final RegExp _userInfoRe = RegExp(r'(://)([^/@\s?#&]+)@');
  static final RegExp _urlQueryRe = RegExp(
    r'([?&](?:x-amz-signature|x-amz-credential|access_token|api_key|apikey|password|signature|token|key|sig)=)([^&\s]*)',
    caseSensitive: false,
  );
  static final RegExp _bodyStringFieldRe = RegExp(
    r'("([^"]+)"\s*:\s*")([^"]*)(")',
  );
  static final RegExp _knownPrefixRe = RegExp(
    r'(?<![A-Za-z0-9_\-])(?:sk-ant-|sk-|AIza|xai-|gsk_|hf_|AKIA)[A-Za-z0-9_\-]+',
  );

  /// A tailcat endpoint host embeds a device's remote address, which is the
  /// capability to reach it (ADR-0020). The sync code scrubs the lines it
  /// writes itself; this net catches a print that bypasses that scrub, because
  /// the persisted log file is what users attach to bug reports.
  static final RegExp _tailcatHostRe = RegExp(
    r'tcat:[A-Za-z0-9_\-+=.~]{16,2048}',
  );

  /// The same address as the host of a sync URL (`https://<address>:9527`):
  /// the form a `HttpException` appends as `uri = ...`.
  static final RegExp _tailcatUriRe = RegExp(
    r'https://[A-Za-z0-9_\-+=.~]{16,2048}:9527',
  );

  static final RegExp _camelCaseRe = RegExp(r'(?<=[a-z0-9])(?=[A-Z])');
  static final RegExp _nameSepRe = RegExp(r'[-_.\s]+');

  static Map<String, String> redactHeaders(Map<String, String> headers) {
    return headers.map((name, value) {
      if (_isSensitiveName(name)) {
        return MapEntry(name, maskSecret(value));
      }
      return MapEntry(name, value);
    });
  }

  static String redactUrl(String url) {
    final stripped = _redactUserInfo(url);
    final uri = Uri.tryParse(stripped);
    if (uri == null) return _redactUrlByRegex(stripped);
    if (!uri.hasQuery) return stripped;
    final hasSensitive = uri.queryParametersAll.keys.any(
      (key) => _sensitiveQueryKeys.contains(key.toLowerCase()),
    );
    if (!hasSensitive) return stripped;
    return _redactUrlByRegex(stripped);
  }

  static String redactBody(String body) {
    if (body.length < _maxJsonBodyChars) {
      try {
        final decoded = jsonDecode(body);
        final walker = _JsonWalker();
        final redacted = walker.walk(decoded);
        final encoded = walker.changed ? jsonEncode(redacted) : body;
        return _redactKnownPrefixes(encoded);
      } catch (_) {}
    }
    return _redactKnownPrefixes(_redactBodyKeys(body));
  }

  static String redactText(String text) {
    return _redactTailcatAddresses(
      _redactKnownPrefixes(_redactUrlByRegex(_redactUserInfo(text))),
    );
  }

  static String _redactTailcatAddresses(String text) {
    if (!text.contains('tcat:') && !text.contains('9527')) return text;
    return text
        .replaceAll(_tailcatUriRe, 'https://<redacted>:9527')
        .replaceAll(_tailcatHostRe, 'tcat:<redacted>');
  }

  static String maskSecret(String value) {
    final scheme = _schemeRe.firstMatch(value);
    if (scheme != null) {
      return '${scheme.group(1)}${scheme.group(2)}${_maskRaw(scheme.group(3)!)}';
    }
    return _maskRaw(value);
  }

  static String _maskRaw(String value) {
    if (_alreadyMaskedRe.hasMatch(value)) return value;
    if (value.length < _shortSecretLimit) return '***(len=${value.length})';
    return '${value.substring(0, 3)}***${value.substring(value.length - 4)}'
        '(len=${value.length})';
  }

  static bool _isSensitiveName(String name) {
    final lower = name.toLowerCase();
    if (_exactSensitiveHeaders.contains(lower)) return true;
    for (final needle in _sensitiveNameNeedles) {
      if (lower.contains(needle)) return true;
    }
    return false;
  }

  static bool _isSensitiveBodyName(String name) {
    final lower = name.toLowerCase();
    if (_exactSensitiveHeaders.contains(lower)) return true;
    if (_bodyIgnoredNames.contains(lower)) return false;
    if (lower == 'apikey') return true;
    for (final needle in _bodyStrongNeedles) {
      if (lower.contains(needle)) return true;
    }
    for (final part in _splitNameParts(name)) {
      if (part.isEmpty) continue;
      final word = part.toLowerCase();
      if (word == 'key' || word == 'token') return true;
      if (_exactSensitiveHeaders.contains(word)) return true;
    }
    return false;
  }

  static Iterable<String> _splitNameParts(String name) {
    return name.split(_camelCaseRe).expand((part) => part.split(_nameSepRe));
  }

  static String _redactUserInfo(String text) {
    return text.replaceAllMapped(_userInfoRe, (match) => match.group(1)!);
  }

  static String _redactUrlByRegex(String text) {
    return text.replaceAllMapped(_urlQueryRe, (match) {
      return '${match.group(1)}${maskSecret(match.group(2)!)}';
    });
  }

  static String _redactBodyKeys(String body) {
    return body.replaceAllMapped(_bodyStringFieldRe, (match) {
      if (!_isSensitiveBodyName(match.group(2)!)) return match.group(0)!;
      return '${match.group(1)}${maskSecret(match.group(3)!)}${match.group(4)}';
    });
  }

  static String _redactKnownPrefixes(String text) {
    return text.replaceAllMapped(_knownPrefixRe, (match) {
      return maskSecret(match.group(0)!);
    });
  }
}

class _JsonWalker {
  bool changed = false;

  Object? walk(Object? value, {String? key}) {
    if (value is String &&
        key != null &&
        LogRedactor._isSensitiveBodyName(key)) {
      final masked = LogRedactor.maskSecret(value);
      if (masked != value) changed = true;
      return masked;
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): walk(entry.value, key: entry.key.toString()),
      };
    }
    if (value is List) {
      return [for (final item in value) walk(item, key: key)];
    }
    return value;
  }
}
