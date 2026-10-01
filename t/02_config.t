use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;

# Baseline: values come from config/fedivid.conf
{
    my $t = Test::Mojo->new('FediVid');
    is $t->app->config('domain'), 'localhost:3000', 'domain from config file';
    is $t->app->config('redis_url'), 'redis://127.0.0.1:6379/0',
        'redis_url from config file';
}

# ENV override: takes precedence
{
    local $ENV{FEDIVID_DOMAIN}    = 'example.test';
    local $ENV{FEDIVID_REDIS_URL} = 'redis://redis.internal:6379/1';

    my $t = Test::Mojo->new('FediVid');
    is $t->app->config('domain'),    'example.test',
        'domain overridden by FEDIVID_DOMAIN';
    is $t->app->config('redis_url'), 'redis://redis.internal:6379/1',
        'redis_url overridden by FEDIVID_REDIS_URL';

    $t->get_ok('/health')
      ->status_is(200)
      ->json_is('/domain', 'example.test');
}

done_testing();
