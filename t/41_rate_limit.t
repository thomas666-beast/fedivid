use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::RateLimit qw(check_rate);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

# Deliberately NOT disabling rate limiting here

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

# --- Unit test the helper directly ---
{
    my $db = $pg->db;

    my ($ok, $retry) = check_rate($db, 'test:1', 3, 60);
    ok $ok, 'first call allowed';

    ($ok, $retry) = check_rate($db, 'test:1', 3, 60);
    ok $ok, 'second call allowed';

    ($ok, $retry) = check_rate($db, 'test:1', 3, 60);
    ok $ok, 'third call allowed';

    ($ok, $retry) = check_rate($db, 'test:1', 3, 60);
    ok !$ok, 'fourth call limited';
    cmp_ok $retry, '>', 0, 'retry_after is positive';

    ($ok, $retry) = check_rate($db, 'test:2', 3, 60);
    ok $ok, 'different key still allowed';
}

# --- Login endpoint rate limiting ---
local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

for my $i (1 .. 30) {
    my $res = $t->post_ok('/api/sessions', json => {
        username => 'alice', password => 'wrong'
    });
    is $res->tx->res->code, 401, "attempt $i: unauthorized";
}

$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'wrong'
})->status_is(429)->json_is('/error', 'rate_limited');

done_testing();
