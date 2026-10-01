use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

# Create two users
local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'bob' }, )
  ->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('devpass123'), 'alice'
);

# --- Profile endpoint ---
$t->get_ok('/api/users/alice/profile')
  ->status_is(200)
  ->json_is('/username', 'alice')
  ->json_is('/followers_count', 0)
  ->json_is('/following_count', 0)
  ->json_is('/video_count', 0)
  ->json_is('/you_follow', 0);

# --- Unknown user ---
$t->get_ok('/api/users/nobody/profile')->status_is(404);

# --- Log in as alice ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'devpass123'
})->status_is(200);

# --- Alice follows bob (local follow) ---
$t->post_ok('/api/users/alice/following', json => {
    actor => 'http://localhost:3000/users/bob',
})->status_is(200);

# Bob's followers should be 1
$t->get_ok('/api/users/bob/profile')
  ->status_is(200)
  ->json_is('/followers_count', 1);

# Alice's following should be 1
$t->get_ok('/api/users/alice/profile')
  ->status_is(200)
  ->json_is('/following_count', 1);

# --- Duplicate follow → 409 ---
$t->post_ok('/api/users/alice/following', json => {
    actor => 'http://localhost:3000/users/bob',
})->status_is(409);

# --- Unfollow ---
$t->delete_ok('/api/users/alice/following', json => {
    actor => 'http://localhost:3000/users/bob',
})->status_is(200);

$t->get_ok('/api/users/bob/profile')
  ->status_is(200)
  ->json_is('/followers_count', 0);

done_testing();
