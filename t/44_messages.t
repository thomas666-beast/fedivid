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

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'bob' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('alicepass1'), 'alice'
);
$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('bobpass123'), 'bob'
);

# Alice logs in
my $alice_t = Test::Mojo->new('FediVid');
$alice_t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'alicepass1'
})->status_is(200);

# Bob logs in
my $bob_t = Test::Mojo->new('FediVid');
$bob_t->post_ok('/api/sessions', json => {
    username => 'bob', password => 'bobpass123'
})->status_is(200);

# --- Alice sends to Bob ---
$alice_t->post_ok('/api/messages', json => {
    from => 'alice', to => 'bob', body => 'hello bob'
})->status_is(201)
  ->json_is('/sender', 'alice')
  ->json_is('/recipient', 'bob')
  ->json_is('/body', 'hello bob');

# --- Bob's inbox shows it ---
$bob_t->get_ok('/api/messages/inbox')
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/unseen', 1)
  ->json_is('/items/0/body', 'hello bob');

diag "inbox sender = " . ($bob_t->tx->res->json->{items}[0]{sender} // 'UNDEF');

# --- Thread between alice and bob ---
$bob_t->get_ok('/api/messages/thread/alice')
  ->status_is(200)
  ->json_is('/totalItems', 1);

# --- Mark thread read ---
$bob_t->post_ok('/api/messages/thread/alice/read')->status_is(200);

$bob_t->get_ok('/api/messages/inbox')
  ->json_is('/unseen', 0);

# --- Cannot message self ---
$alice_t->post_ok('/api/messages', json => {
    from => 'alice', to => 'alice', body => 'hi me'
})->status_is(400)->json_is('/error', 'cannot_message_self');

# --- Bob cannot send as alice ---
$bob_t->post_ok('/api/messages', json => {
    from => 'alice', to => 'bob', body => 'spoofed'
})->status_is(401)->json_is('/error', 'unauthorized');

# --- Missing recipient ---
$alice_t->post_ok('/api/messages', json => {
    from => 'alice', to => 'nobody', body => 'hi'
})->status_is(404)->json_is('/error', 'recipient_not_found');

# --- Empty body ---
$alice_t->post_ok('/api/messages', json => {
    from => 'alice', to => 'bob', body => '   '
})->status_is(400)->json_is('/error', 'missing_body');

# --- Unauthenticated inbox ---
$t->get_ok('/api/messages/inbox')->status_is(401);

done_testing();
