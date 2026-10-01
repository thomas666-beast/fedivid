use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

# Create a user
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201)
  ->content_type_like(qr{^application/activity\+json})
  ->json_is('/type',              'Person')
  ->json_is('/preferredUsername', 'alice')
  ->json_is('/id',                'http://localhost:3000/users/alice');

# Now the actor endpoint sees the same user
$t->get_ok('/users/alice')
  ->status_is(200)
  ->json_is('/preferredUsername', 'alice');

# Duplicate → 409
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(409);

# Invalid usernames → 400
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'A' },
)
  ->status_is(400);
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'has space' },
)->status_is(400);
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'ab' },
)  # too short
  ->status_is(400);
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => {},
)                   # missing
  ->status_is(400);

done_testing();
