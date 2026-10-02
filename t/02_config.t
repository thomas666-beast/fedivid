use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;

# Baseline: values come from config/fedivid.json
{
    my $t = Test::Mojo->new('FediVid');
    is $t->app->config('domain'), 'localhost:3000', 'domain from config file';
}

# ENV override: takes precedence
{
    local $ENV{FEDIVID_DOMAIN} = 'example.test';

    my $t = Test::Mojo->new('FediVid');
    is $t->app->config('domain'), 'example.test',
        'domain overridden by FEDIVID_DOMAIN';

    $t->get_ok('/health')
      ->status_is(200)
      ->json_is('/domain', 'example.test');
}

done_testing();
