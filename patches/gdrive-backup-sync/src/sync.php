#!/usr/bin/env php
<?php

declare(strict_types=1);

const APP_NAME = 'xui-gdrive-sync';
const APP_VERSION = '1.0.0';
const DEFAULT_CONFIG = '/etc/xui-gdrive-sync/config.php';

function out(string $message = ''): void
{
    fwrite(STDOUT, $message . PHP_EOL);
}

function err(string $message): void
{
    fwrite(STDERR, $message . PHP_EOL);
}

function usage(): void
{
    out('XUI.ONE Google Drive Backup Sync ' . APP_VERSION);
    out('');
    out('Usage:');
    out('  xui-gdrive-sync sync       Run real synchronization');
    out('  xui-gdrive-sync dry-run    Show what would change without uploading/deleting');
    out('  xui-gdrive-sync status     Show local and remote summary');
    out('  xui-gdrive-sync doctor     Validate PHP, paths, rclone and remote config');
    out('  xui-gdrive-sync local      List matching local backup files');
    out('  xui-gdrive-sync remote     List remote files');
    out('  xui-gdrive-sync version    Show version');
    out('');
    out('Options:');
    out('  --config=/path/config.php  Use a custom PHP config file');
}

function optionValue(array $argv, string $name, ?string $default = null): ?string
{
    foreach ($argv as $arg) {
        if (str_starts_with($arg, $name . '=')) {
            return substr($arg, strlen($name) + 1);
        }
    }
    return $default;
}

function loadConfig(array $argv): array
{
    $path = optionValue($argv, '--config', getenv('XUI_GDRIVE_SYNC_CONFIG') ?: DEFAULT_CONFIG);
    if (!is_file($path)) {
        throw new RuntimeException("Config file not found: {$path}");
    }

    $config = require $path;
    if (!is_array($config)) {
        throw new RuntimeException("Config file must return an array: {$path}");
    }

    $config['_config_path'] = $path;
    return $config;
}

function cfg(array $config, string $key, mixed $default = null): mixed
{
    return array_key_exists($key, $config) ? $config[$key] : $default;
}

function ensureDirectory(string $dir, int $mode = 0750): void
{
    if (!is_dir($dir)) {
        if (!mkdir($dir, $mode, true) && !is_dir($dir)) {
            throw new RuntimeException("Could not create directory: {$dir}");
        }
    }
}

function hostnameValue(): string
{
    $host = trim((string) shell_exec('hostname -f 2>/dev/null'));
    if ($host === '') {
        $host = gethostname() ?: 'server';
    }

    return preg_replace('/[^A-Za-z0-9._-]/', '-', $host) ?: 'server';
}

function remotePath(array $config): string
{
    $remoteName = trim((string) cfg($config, 'remote_name', 'gdrive'));
    $remoteDir = trim((string) cfg($config, 'remote_dir', 'xui-one-backups/{hostname}'));
    $remoteDir = str_replace('{hostname}', hostnameValue(), $remoteDir);
    $remoteDir = ltrim($remoteDir, '/');

    if ($remoteName === '') {
        throw new RuntimeException('remote_name cannot be empty.');
    }

    if ($remoteDir === '') {
        throw new RuntimeException('remote_dir cannot be empty.');
    }

    return $remoteName . ':' . $remoteDir;
}

function shellArgs(array $args): string
{
    return implode(' ', array_map('escapeshellarg', $args));
}

function runCommand(array $args, ?string $logFile = null): int
{
    $cmd = shellArgs($args);
    $descriptorSpec = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];

    $process = proc_open($cmd, $descriptorSpec, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException("Could not start command: {$cmd}");
    }

    fclose($pipes[0]);
    $streams = [$pipes[1], $pipes[2]];
    foreach ($streams as $stream) {
        stream_set_blocking($stream, false);
    }

    while (true) {
        $status = proc_get_status($process);
        foreach ($streams as $idx => $stream) {
            $data = stream_get_contents($stream);
            if ($data !== false && $data !== '') {
                $target = $idx === 0 ? STDOUT : STDERR;
                fwrite($target, $data);
                if ($logFile !== null) {
                    file_put_contents($logFile, $data, FILE_APPEND);
                }
            }
        }

        if (!$status['running']) {
            break;
        }
        usleep(100000);
    }

    foreach ($streams as $stream) {
        $data = stream_get_contents($stream);
        if ($data !== false && $data !== '') {
            fwrite(STDOUT, $data);
            if ($logFile !== null) {
                file_put_contents($logFile, $data, FILE_APPEND);
            }
        }
        fclose($stream);
    }

    return proc_close($process);
}

function commandOutput(array $args): array
{
    $cmd = shellArgs($args) . ' 2>&1';
    $output = [];
    $exitCode = 0;
    exec($cmd, $output, $exitCode);

    return [$exitCode, implode(PHP_EOL, $output)];
}

function matchingLocalFiles(array $config): array
{
    $source = rtrim((string) cfg($config, 'source_dir'), '/');
    if (!is_dir($source)) {
        throw new RuntimeException("Source directory not found: {$source}");
    }

    $patterns = (array) cfg($config, 'include_patterns', ['backup_*.sql']);
    if ($patterns === []) {
        throw new RuntimeException('include_patterns cannot be empty.');
    }

    $files = [];
    foreach ($patterns as $pattern) {
        foreach (glob($source . '/' . $pattern) ?: [] as $file) {
            if (is_file($file)) {
                $files[$file] = [
                    'path' => $file,
                    'size' => filesize($file),
                    'mtime' => filemtime($file),
                ];
            }
        }
    }

    ksort($files);
    return array_values($files);
}

function acquireLock(string $lockFile)
{
    $dir = dirname($lockFile);
    ensureDirectory($dir, 0755);

    $handle = fopen($lockFile, 'c');
    if ($handle === false) {
        throw new RuntimeException("Could not open lock file: {$lockFile}");
    }

    if (!flock($handle, LOCK_EX | LOCK_NB)) {
        throw new RuntimeException('Another sync process is already running.');
    }

    ftruncate($handle, 0);
    fwrite($handle, (string) getmypid());

    return $handle;
}

function baseRcloneArgs(array $config): array
{
    $args = ['rclone'];
    $rcloneConfig = (string) cfg($config, 'rclone_config', '/etc/xui-gdrive-sync/rclone.conf');
    if ($rcloneConfig !== '') {
        $args[] = '--config';
        $args[] = $rcloneConfig;
    }

    return $args;
}

function syncArgs(array $config, bool $dryRun): array
{
    $source = rtrim((string) cfg($config, 'source_dir'), '/');
    $args = array_merge(baseRcloneArgs($config), [
        'sync',
        $source,
        remotePath($config),
    ]);

    foreach ((array) cfg($config, 'include_patterns', ['backup_*.sql']) as $pattern) {
        $args[] = '--include';
        $args[] = (string) $pattern;
    }

    $args[] = '--exclude';
    $args[] = '*';
    $args[] = '--delete-after';
    $args[] = '--transfers';
    $args[] = (string) cfg($config, 'transfers', 4);
    $args[] = '--checkers';
    $args[] = (string) cfg($config, 'checkers', 8);
    $args[] = '--stats';
    $args[] = (string) cfg($config, 'stats_interval', '30s');
    $args[] = '--log-level';
    $args[] = $dryRun ? 'NOTICE' : (string) cfg($config, 'log_level', 'INFO');

    if ((bool) cfg($config, 'fast_list', true)) {
        $args[] = '--fast-list';
    }

    if (!(bool) cfg($config, 'drive_use_trash', false)) {
        $args[] = '--drive-use-trash=false';
    }

    foreach ((array) cfg($config, 'extra_rclone_flags', []) as $flag) {
        $args[] = (string) $flag;
    }

    if ($dryRun) {
        $args[] = '--dry-run';
    }

    return $args;
}

function checkRemoteConfigured(array $config): array
{
    $remoteName = rtrim((string) cfg($config, 'remote_name', 'gdrive'), ':');
    [$exitCode, $output] = commandOutput(array_merge(baseRcloneArgs($config), ['listremotes']));

    if ($exitCode !== 0) {
        return [false, trim($output) ?: 'rclone listremotes failed'];
    }

    $remotes = array_filter(array_map('trim', explode(PHP_EOL, $output)));
    $expected = $remoteName . ':';

    return [in_array($expected, $remotes, true), $output];
}

function commandDoctor(array $config): int
{
    out('Config: ' . $config['_config_path']);
    out('Source: ' . cfg($config, 'source_dir'));
    out('Remote: ' . remotePath($config));
    out('Rclone config: ' . cfg($config, 'rclone_config'));
    out('');

    $failures = 0;
    $checks = [];
    $checks['php_version'] = PHP_VERSION;
    $checks['rclone_binary'] = trim((string) shell_exec('command -v rclone 2>/dev/null')) ?: 'missing';
    $checks['source_dir'] = is_dir((string) cfg($config, 'source_dir')) ? 'ok' : 'missing';
    $checks['rclone_config'] = is_file((string) cfg($config, 'rclone_config')) ? 'ok' : 'missing';

    [$remoteOk, $remoteInfo] = checkRemoteConfigured($config);
    $checks['rclone_remote'] = $remoteOk ? 'ok' : 'missing or invalid';

    foreach ($checks as $name => $value) {
        if ($value === '' || $value === 'missing' || $value === 'missing or invalid') {
            $failures++;
        }
        out(str_pad($name, 18) . ': ' . $value);
    }

    try {
        $files = matchingLocalFiles($config);
        out(str_pad('local_files', 18) . ': ' . count($files));
    } catch (Throwable $e) {
        $failures++;
        out(str_pad('local_files', 18) . ': error - ' . $e->getMessage());
    }

    if (!$remoteOk && trim($remoteInfo) !== '') {
        out('');
        out('Remote check output:');
        out(trim($remoteInfo));
    }

    return $failures > 0 ? 1 : 0;
}

function commandLocal(array $config): int
{
    $files = matchingLocalFiles($config);
    foreach ($files as $file) {
        out(date('Y-m-d H:i:s', (int) $file['mtime']) . '  ' . str_pad((string) $file['size'], 12, ' ', STR_PAD_LEFT) . '  ' . basename((string) $file['path']));
    }
    out('Total: ' . count($files));

    return 0;
}

function commandRemote(array $config): int
{
    $args = array_merge(baseRcloneArgs($config), ['lsf', remotePath($config)]);
    return runCommand($args);
}

function commandStatus(array $config): int
{
    $doctorExit = commandDoctor($config);
    out('');
    out('Remote file list:');
    $remoteExit = commandRemote($config);

    return $doctorExit !== 0 ? $doctorExit : $remoteExit;
}

function commandSync(array $config, bool $dryRun): int
{
    ensureDirectory((string) cfg($config, 'log_dir', '/var/log/xui-gdrive-sync'));
    $logFile = rtrim((string) cfg($config, 'log_dir', '/var/log/xui-gdrive-sync'), '/') . '/sync.log';
    $lock = acquireLock((string) cfg($config, 'lock_file', '/run/xui-gdrive-sync.lock'));

    try {
        $files = matchingLocalFiles($config);
        if (count($files) === 0 && !(bool) cfg($config, 'allow_empty_source', false)) {
            throw new RuntimeException('No matching local backup files found. Sync skipped to avoid wiping the remote folder. Set allow_empty_source=true only if this is intentional.');
        }

        $mode = $dryRun ? 'DRY-RUN' : 'SYNC';
        $line = '[' . date('c') . "] {$mode} started. Local files: " . count($files) . ', Remote: ' . remotePath($config) . PHP_EOL;
        file_put_contents($logFile, $line, FILE_APPEND);
        out(trim($line));

        $exit = runCommand(syncArgs($config, $dryRun), $logFile);

        $line = '[' . date('c') . "] {$mode} finished with exit code {$exit}" . PHP_EOL;
        file_put_contents($logFile, $line, FILE_APPEND);
        out(trim($line));

        return $exit;
    } finally {
        flock($lock, LOCK_UN);
        fclose($lock);
    }
}

try {
    $argv = $_SERVER['argv'] ?? [];
    $command = $argv[1] ?? 'help';

    if ($command === '--help' || $command === '-h') {
        $command = 'help';
    }

    if ($command === 'help') {
        usage();
        exit(0);
    }

    if ($command === 'version' || $command === '--version' || $command === '-V') {
        out(APP_NAME . ' ' . APP_VERSION);
        exit(0);
    }

    $config = loadConfig($argv);

    $exit = match ($command) {
        'sync' => commandSync($config, false),
        'dry-run' => commandSync($config, true),
        'status' => commandStatus($config),
        'doctor' => commandDoctor($config),
        'local' => commandLocal($config),
        'remote' => commandRemote($config),
        default => throw new InvalidArgumentException("Unknown command: {$command}"),
    };

    exit($exit);
} catch (Throwable $e) {
    err('ERROR: ' . $e->getMessage());
    exit(1);
}
