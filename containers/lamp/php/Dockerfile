# PHP-FPM for the LAMP stack — the official php:8.3-fpm image plus
# the MySQL drivers. The stock image ships mysqlnd but no driver;
# the bare-metal installers install the driver package instead
# (php-mysqlnd on Rocky, php-mysql on Debian), so this build is the
# container equivalent of that package install.
FROM php:8.3-fpm

RUN docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql
