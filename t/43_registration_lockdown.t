use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_ALLOW_SIGNUP} = 0;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

# --- Missing header -> 403 ---
$t->post_ok('/api/users', json => { username => 'alice', password => 'alicepass123' })
  ->status_is(403)
  ->json_is('/error', 'signup_disabled');

# --- Wrong token -> 403 ---
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'wrong-token' },
    json => { username => 'alice', password => 'alicepass123' },
)->status_is(403)->json_is('/error', 'signup_disabled');

# --- Correct token -> 201 ---
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice', password => 'alicepass123' },
)->status_is(201)
  ->json_is('/preferredUsername', 'alice');

# --- Missing config -> still 403 (open signup disabled) ---
{
    my $t2 = Test::Mojo->new('FediVid');
    $t2->app->config->{admin_secret} = undef;
    $t2->post_ok('/api/users',
        { 'X-Admin-Token' => 'test-admin-token' },
        json => { username => 'bob', password => 'bobpass123' },
    )->status_is(403)->json_is('/error', 'signup_disabled');
}

done_testing();
