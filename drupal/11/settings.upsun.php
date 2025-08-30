<?php
/**
 * @file
 * Upsun Drupal settings.
 *
 * These are intended to complement Upsun's recommended Drupal configuration.
 */

// Set up a config sync directory.
// This is defined inside the read-only "config" directory, deployed via Git.
if (empty($settings['config_sync_directory']) && is_dir('../config/sync')) {
    $settings['config_sync_directory'] = '../config/sync';
}

// Configure the database.
// This expects a relationship named "db" to a MariaDB/MySQL service.
if (empty($databases['default']['default']) && getenv('DB_HOST') !== false) {
    $databases['default']['default'] = [
        'driver' => getenv('DB_SCHEME'),
        'database' => getenv('DB_PATH'),
        'username' => getenv('DB_USERNAME'),
        'password' => getenv('DB_PASSWORD'),
        'host' => getenv('DB_HOST'),
        'port' => getenv('DB_PORT'),
        'init_commands' => [
            'isolation_level' => 'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED',
        ],
    ];
}

// Enable verbose error messages on development/staging branches, but not on the production branch.
// You may add more debug-centric settings here if desired to have them automatically enable
// on development but not production.
if (empty($config['system.logging']['error_level'])) {
    if (getenv('PLATFORM_ENVIRONMENT_TYPE') === 'production') {
        // Production environment type.
        $config['system.logging']['error_level'] = 'hide';
    } else {
        // Non-production environment types.
        $config['system.logging']['error_level'] = 'verbose';
    }
}

// Enable Redis caching.
// This expects a relationship named "cache" linking to a Redis (or Valkey) service.
if (getenv('CACHE_HOST') !== false
    && class_exists('Drupal\redis\ClientFactory')
    && !\Drupal\Core\Installer\InstallerKernel::installationAttempted()
    && extension_loaded('redis')) {

    // Set Redis as the default backend for any cache bin not otherwise specified.
    $settings['cache']['default'] = 'cache.backend.redis';
    $settings['redis.connection']['host'] = getenv('CACHE_HOST');
    $settings['redis.connection']['port'] = getenv('CACHE_PORT');

    // Apply changes to the container configuration to better leverage Redis.
    // This includes using Redis for the lock and flood control systems, as well
    // as the cache tag checksum. Alternatively, copy the contents of that file
    // to your project-specific services.yml file, modify as appropriate, and
    // remove this line.
    $settings['container_yamls'][] = 'modules/contrib/redis/example.services.yml';

    // Allow the services to work before the Redis module itself is enabled.
    $settings['container_yamls'][] = 'modules/contrib/redis/redis.services.yml';

    // Manually add the classloader path, this is required for the container cache bin definition below
    // and allows to use it without the redis module being enabled.
    $class_loader->addPsr4('Drupal\\redis\\', 'modules/contrib/redis/src');

    // Use redis for container cache.
    // The container cache is used to load the container definition itself, and
    // thus any configuration stored in the container itself is not available
    // yet. These lines force the container cache to use Redis rather than the
    // default SQL cache.
    $settings['bootstrap_container_definition'] = [
        'parameters' => [],
        'services' => [
            'redis.factory' => [
                'class' => 'Drupal\redis\ClientFactory',
            ],
            'cache.backend.redis' => [
                'class' => 'Drupal\redis\Cache\CacheBackendFactory',
                'arguments' => ['@redis.factory', '@cache_tags_provider.container', '@serialization.phpserialize'],
            ],
            'cache.container' => [
                'class' => '\Drupal\redis\Cache\PhpRedis',
                'factory' => ['@cache.backend.redis', 'get'],
                'arguments' => ['container'],
            ],
            'cache_tags_provider.container' => [
                'class' => 'Drupal\redis\Cache\RedisCacheTagsChecksum',
                'arguments' => ['@redis.factory'],
            ],
            'serialization.phpserialize' => [
                'class' => 'Drupal\Component\Serialization\PhpSerialize',
            ],
        ],
    ];
}

// Configure private and temporary file paths.
if (getenv('PLATFORM_APP_DIR') !== false) {
    if (empty($settings['file_private_path'])) {
        $settings['file_private_path'] = getenv('PLATFORM_APP_DIR') . '/private';
    }
    if (empty($settings['file_temp_path'])) {
        $settings['file_temp_path'] = getenv('PLATFORM_APP_DIR') . '/tmp';
    }

    // Configure the default PhpStorage and Twig template cache directories.
    if (empty($settings['php_storage']['default'])) {
        $settings['php_storage']['default']['directory'] = $settings['file_private_path'];
    }
    if (empty($settings['php_storage']['twig'])) {
        $settings['php_storage']['twig']['directory'] = $settings['file_private_path'];
    }
}


// Set the hash salt using the project-wide entropy value.
if (empty($settings['hash_salt']) && getenv('PLATFORM_PROJECT_ENTROPY') !== false) {
    $settings['hash_salt'] = getenv('PLATFORM_PROJECT_ENTROPY');
}

// Set the deployment identifier, used by some Drupal cache systems.
if (empty($settings['deployment_identifier']) && getenv('PLATFORM_TREE_ID') !== false) {
    $settings['deployment_identifier'] = getenv('PLATFORM_TREE_ID');
}

// Allow any Host header, as it is already validated by Upsun.
if (empty($settings['trusted_host_patterns'])) {
    $settings['trusted_host_patterns'] = ['.*'];
}
