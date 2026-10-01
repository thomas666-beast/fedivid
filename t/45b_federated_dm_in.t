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
use Mojo::JSON qw(encode_json);

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

# Remote actor setup
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

sub signed_post {
    my ($path, $payload) = @_;
    my $body = encode_json($payload);
    my $tx   = $t->ua->build_tx(POST => $path);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);
    return $tx;
}

# --- Inbound Create / Note addressed to alice ---
{
    my $tx = signed_post('/users/alice/inbox', {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => 'https://remote.test/activities/1',
        type       => 'Create',
        actor      => $actor_url,
        to         => ['http://localhost:3000/users/alice'],
        object     => {
            id           => 'https://remote.test/notes/1',
            type         => 'Note',
            attributedTo => $actor_url,
            to           => ['http://localhost:3000/users/alice'],
            content      => 'hello from remote',
        },
    });
    is $tx->res->code, 202, 'Create Note accepted';

    my $row = $pg->db->query(
        'SELECT * FROM messages WHERE recipient_actor = ?',
        'http://localhost:3000/users/alice'
    )->hash;
    ok $row, 'message row exists';
    is $row->{sender_actor}, $actor_url, 'sender is remote actor';
    is $row->{body}, 'hello from remote', 'body stored';
    ok $row->{is_remote}, 'marked remote';
}

# --- Duplicate is idempotent ---
{
    signed_post('/users/alice/inbox', {
        type   => 'Create',
        actor  => $actor_url,
        to     => ['http://localhost:3000/users/alice'],
        object => {
            id           => 'https://remote.test/notes/1',
            type         => 'Note',
            attributedTo => $actor_url,
            to           => ['http://localhost:3000/users/alice'],
            content      => 'hello from remote',
        },
    });

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM messages WHERE recipient_actor = ?',
        'http://localhost:3000/users/alice'
    )->hash->{n};
    is $count, 1, 'still one row';
}

# --- Note addressed to someone else is ignored ---
{
    signed_post('/users/alice/inbox', {
        type   => 'Create',
        actor  => $actor_url,
        to     => ['http://localhost:3000/users/nobody'],
        object => {
            id           => 'https://remote.test/notes/2',
            type         => 'Note',
            attributedTo => $actor_url,
            to           => ['http://localhost:3000/users/nobody'],
            content      => 'not for alice',
        },
    });

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM messages WHERE recipient_actor = ?',
        'http://localhost:3000/users/alice'
    )->hash->{n};
    is $count, 1, 'no new row for other recipient';
}

# --- Non-Note Create is ignored ---
{
    signed_post('/users/alice/inbox', {
        type   => 'Create',
        actor  => $actor_url,
        to     => ['http://localhost:3000/users/alice'],
        object => {
            id   => 'https://remote.test/things/1',
            type => 'Article',
        },
    });

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM messages WHERE recipient_actor = ?',
        'http://localhost:3000/users/alice'
    )->hash->{n};
    is $count, 1, 'no new row for non-Note';
}

# --- Sender can read it via thread ---
{
    $t->post_ok('/api/sessions', json => {
        username => 'alice', password => 'alicepass1',
    })->status_is(200);

    $t->get_ok('/api/messages/inbox')
      ->status_is(200)
      ->json_is('/totalItems', 1)
      ->json_is('/unseen', 1)
      ->json_is('/items/0/is_remote', 1);

    my $short = $t->tx->res->json->{items}[0]{sender};
    like $short, qr/^[\\\@]remote\.test/, 'sender shown as @host form';
}

done_testing();
