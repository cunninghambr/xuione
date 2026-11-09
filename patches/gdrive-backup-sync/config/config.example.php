<?php

return [
    // XUI.ONE backup directory on the server.
    'source_dir' => '/home/xui/backups',

    // Rclone remote name created by:
    // sudo rclone config --config /etc/xui-gdrive-sync/rclone.conf
    'remote_name' => 'gdrive',

    // Google Drive folder path. {hostname} will be replaced with the server hostname.
    'remote_dir' => 'xui-one-backups/{hostname}',

    // File patterns to sync. XUI.ONE usually creates names like:
    // backup_2026-06-25_00:28:01.sql
    'include_patterns' => [
        'backup_*.sql',
        'backup_*.sql.gz',
    ],

    // Safety: false prevents wiping Google Drive if the local backup directory is unexpectedly empty.
    // Set true only if you intentionally want an empty local folder to empty the remote folder too.
    'allow_empty_source' => false,

    // Google Drive deletes go to Trash by default. false deletes permanently and releases quota faster.
    'drive_use_trash' => false,

    // Rclone tuning.
    'transfers' => 4,
    'checkers' => 8,
    'fast_list' => true,
    'stats_interval' => '30s',
    'log_level' => 'INFO',

    // Optional advanced flags, for example: ['--bwlimit', '10M']
    'extra_rclone_flags' => [],

    // Runtime paths.
    'log_dir' => '/var/log/xui-gdrive-sync',
    'rclone_config' => '/etc/xui-gdrive-sync/rclone.conf',
    'lock_file' => '/run/xui-gdrive-sync.lock',
];
