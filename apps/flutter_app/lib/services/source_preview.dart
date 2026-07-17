const _sourceLanguagesByExtension = <String, String>{
  'bash': 'bash',
  'c': 'c',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cs': 'csharp',
  'css': 'css',
  'dart': 'dart',
  'diff': 'diff',
  'go': 'go',
  'gradle': 'gradle',
  'h': 'c',
  'hpp': 'cpp',
  'htm': 'xml',
  'html': 'xml',
  'ini': 'ini',
  'java': 'java',
  'js': 'javascript',
  'json': 'json',
  'jsonl': 'json',
  'jsx': 'javascript',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'md': 'markdown',
  'mjs': 'javascript',
  'php': 'php',
  'ps1': 'powershell',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'scss': 'scss',
  'sh': 'bash',
  'sql': 'sql',
  'swift': 'swift',
  'toml': 'ini',
  'ts': 'typescript',
  'tsx': 'typescript',
  'vue': 'xml',
  'xml': 'xml',
  'yaml': 'yaml',
  'yml': 'yaml',
  'zsh': 'bash',
};

String? sourcePreviewLanguage(String key, String? contentType) {
  final fileName = key.toLowerCase().split('/').last;
  if (fileName == 'dockerfile') return 'dockerfile';
  final dot = fileName.lastIndexOf('.');
  if (dot >= 0 && dot < fileName.length - 1) {
    final language = _sourceLanguagesByExtension[fileName.substring(dot + 1)];
    if (language != null) return language;
  }

  final normalizedType = contentType?.toLowerCase().split(';').first.trim();
  return switch (normalizedType) {
    'application/javascript' || 'text/javascript' => 'javascript',
    'application/json' || 'application/ld+json' => 'json',
    'application/sql' => 'sql',
    'application/toml' => 'ini',
    'application/typescript' || 'text/typescript' => 'typescript',
    'application/x-httpd-php' => 'php',
    'application/x-sh' || 'text/x-shellscript' => 'bash',
    'application/x-yaml' || 'text/yaml' => 'yaml',
    'application/xml' || 'text/xml' || 'text/html' => 'xml',
    'text/css' => 'css',
    'text/markdown' => 'markdown',
    'text/x-c' => 'c',
    'text/x-c++' => 'cpp',
    'text/x-java-source' => 'java',
    'text/x-python' => 'python',
    _ => null,
  };
}

bool isCodePreview(String key, String? contentType) =>
    sourcePreviewLanguage(key, contentType) != null;

bool isHtmlPreview(String key, String? contentType) {
  final normalizedType = contentType?.toLowerCase().split(';').first.trim();
  final normalizedKey = key.toLowerCase();
  return normalizedType == 'text/html' ||
      normalizedKey.endsWith('.html') ||
      normalizedKey.endsWith('.htm');
}
