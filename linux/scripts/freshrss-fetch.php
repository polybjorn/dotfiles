#!/usr/bin/env php
<?php
declare(strict_types=1);
require '/var/www/FreshRSS/cli/_cli.php';

$maxFeeds = (int)($argv[1] ?? 15);

performRequirementCheck(FreshRSS_Context::systemConf()->db['type'] ?? '');

$username = cliInitUser('freshrss');

[$nbUpdatedFeeds, , $nbNewArticles] = FreshRSS_feed_Controller::actualizeFeedsAndCommit(null, null, $maxFeeds);

echo "Actualized $nbUpdatedFeeds feeds ($nbNewArticles new articles)\n";

invalidateHttpCache($username);

done($nbUpdatedFeeds > 0);
