use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);
use FediVid::Signature qw(sign_request);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json decode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('alicepass1'), 'alice'
);

$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'alicepass1',
})->status_is(200);

# --- Alice boosts something ---
my $url = 'http://localhost:3000/users/bob/videos/xyz.mp4';

$t->post_ok('/api/users/alice/announces', json => { object => $url })
  ->status_is(201)
  ->json_is('/type', 'Announce')
  ->json_is('/object', $url);

my $id = $t->tx->res->json->{id};
ok $id, 'announce id returned';

# --- Duplicate → 409 ---
$t->post_ok('/api/users/alice/announces', json => { object => $url })
  ->status_is(409)->json_is('/error', 'already_announced');

# --- Index lists it ---
$t->get_ok('/api/users/alice/announces')
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/items/0/object', $url);

# --- Unboost ---
$t->delete_ok("/api/users/alice/announces/$id")
  ->status_is(200);

$t->get_ok('/api/users/alice/announces')
  ->json_is('/totalItems', 0);

# --- Inbound remote announce ---
my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $actor_url   = 'https://remote.test/users/bob';
my $remote_key  = 'https://remote.test/users/bob#main-key';

$pg->db->query(
    'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
          VALUES (?, ?, ?, NOW())',
    $actor_url,
    encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $remote_key,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    }),
    $remote_pub,
);

$pg->db->query(
    'INSERT INTO followers (local_user, remote_actor, remote_inbox, accepted)
          VALUES (?, ?, ?, TRUE)',
    'alice', $actor_url, 'https://remote.test/users/bob/inbox'
);

my $announced_url = 'https://remote.test/videos/interesting.mp4';
my $announce_activity_id = 'https://remote.test/activities/announce-1';

{
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body(encode_json({
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => $announce_activity_id,
        type       => 'Announce',
        actor      => $actor_url,
        object     => $announced_url,
    }));
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);
    is $tx->res->code, 202, 'inbound Announce accepted';

    my $row = $pg->db->query(
        'SELECT * FROM announces WHERE username = ? AND activity_id = ?',
        'alice', $announce_activity_id
    )->hash;
    ok $row, 'announce row created';
    is $row->{object_url}, $announced_url, 'object stored';
    is $row->{actor}, $actor_url, 'actor stored';
    ok $row->{is_remote}, 'marked remote';
}

# --- Duplicate inbound is idempotent ---
{
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body(encode_json({
        type   => 'Announce',
        id     => $announce_activity_id,
        actor  => $actor_url,
        object => $announced_url,
    }));
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM announces WHERE username = ? AND activity_id = ?',
        'alice', $announce_activity_id
    )->hash->{n};
    is $count, 1, 'still one row';
}

# --- Inbound Undo Announce ---
{
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body(encode_json({
        type   => 'Undo',
        actor  => $actor_url,
        object => {
            type => 'Announce',
            id   => $announce_activity_id,
            actor => $actor_url,
            object => $announced_url,
        },
    }));
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);

    my $row = $pg->db->query(
        'SELECT 1 FROM announces WHERE username = ? AND activity_id = ?',
        'alice', $announce_activity_id
    )->array;
    ok !$row, 'announce removed after Undo';
}

done_testing();
