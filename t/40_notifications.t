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

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'bob' }, )
  ->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('devpass123'), 'alice'
);

# --- Unauthenticated → 401 ---
$t->get_ok('/api/users/alice/notifications')->status_is(401);

# --- Log in as alice ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'devpass123'
})->status_is(200);

# --- Empty initially ---
$t->get_ok('/api/users/alice/notifications')
  ->status_is(200)
  ->json_is('/totalItems', 0)
  ->json_is('/unseen', 0);

# --- Bob follows alice locally → notification for alice ---
$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('bobpass123'), 'bob'
);

# Log in as bob in a separate jar to follow alice
my $t2 = Test::Mojo->new('FediVid');
$t2->post_ok('/api/sessions', json => {
    username => 'bob', password => 'bobpass123'
})->status_is(200);

$t2->post_ok('/api/users/bob/following', json => {
    actor => 'http://localhost:3000/users/alice',
})->status_is(200);

# --- Alice sees the notification ---
$t->get_ok('/api/users/alice/notifications')
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/unseen', 1)
  ->json_is('/items/0/type',  'follow')
  ->json_is('/items/0/actor', 'http://localhost:3000/users/bob')
  ->json_is('/items/0/seen',  0);

# --- Mark as seen ---
$t->post_ok('/api/users/alice/notifications/seen')->status_is(200);

$t->get_ok('/api/users/alice/notifications')
  ->status_is(200)
  ->json_is('/unseen', 0)
  ->json_is('/items/0/seen', 1);

# --- Wrong user → 401 ---
$t->get_ok('/api/users/bob/notifications')->status_is(401);

done_testing();
