<?php
// LAMP stack canary — the container equivalent of the verification
// block at the end of scripts/provisioning/lamp-install-*.sh.
// Reports the PHP version and proves a live MariaDB connection with
// SELECT VERSION(). Credentials come from the environment (compose
// .env); nothing secret is printed, including on failure.

header('Content-Type: text/plain');

echo 'PHP ' . PHP_VERSION . " OK\n";

$host = getenv('MYSQL_HOST') ?: 'db';
$db   = getenv('MYSQL_DATABASE') ?: '';
$user = getenv('MYSQL_USER') ?: '';
$pass = getenv('MYSQL_PASSWORD') ?: '';

try {
    $pdo = new PDO(
        "mysql:host={$host};dbname={$db};charset=utf8mb4",
        $user,
        $pass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $version = $pdo->query('SELECT VERSION()')->fetchColumn();
    echo "MariaDB {$version} OK (database {$db}, user {$user})\n";
    echo "LAMP OK\n";
} catch (Throwable $e) {
    http_response_code(500);
    echo 'MariaDB FAIL: ' . $e->getMessage() . "\n";
}
