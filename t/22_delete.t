use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Signature qw(sign_request);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json);

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

my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $key_id      = 'https://remote.test/users/bob#main-key';
my $actor_url   = 'https://remote.test/users/bob';

$pg->db->query(
    'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
          VALUES (?, ?, ?, NOW())',
    $actor_url,
    encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $key_id,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    }),
    $remote_pub,
);

# Fake UA so Accept delivery doesn't hit the network
{
    package FakeUA;
    use Mojo::Base -strict, -signatures;
    sub new ($class) { bless {}, $class }
    sub build_tx ($self, $method, $url) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method($method);
        $tx->req->url->parse($url);
        return $tx;
    }
    sub start ($self, $tx) {
        $tx->res->code(202);
        $tx->res->headers->content_type('application/activity+json');
        $tx->res->body('{"status":"ok"}');
        return $tx;
    }
}

$t->app->ua(FakeUA->new);

sub signed_post {
    my ($path, $payload) = @_;
    my $body = encode_json($payload);
    my $tx   = $t->ua->build_tx(POST => $path);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $key_id, $remote_priv);
    $t->ua->start($tx);
    return $tx;
}

# --- Setup: Follow creates a follower row ---
{
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Follow',
        actor  => $actor_url,
        object => 'http://localhost:3000/users/alice',
    });
    is $tx->res->code, 202, 'Follow accepted';

    my $row = $pg->db->query(
        'SELECT 1 FROM followers WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->array;
    ok $row, 'follower row created';
}

# --- Delete self removes the follower row ---
{
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Delete',
        actor  => $actor_url,
        object => $actor_url,
    });
    is $tx->res->code, 202, 'Delete accepted';

    my $row = $pg->db->query(
        'SELECT 1 FROM followers WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->array;
    ok !$row, 'follower row removed';
}

# --- Delete of a non-self object is ignored (no cascade) ---
{
    # Re-follow first
    signed_post('/users/alice/inbox', {
        type   => 'Follow',
        actor  => $actor_url,
        object => 'http://localhost:3000/users/alice',
    });

    # Delete pointing at some post, not the actor
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Delete',
        actor  => $actor_url,
        object => 'https://remote.test/posts/123',
    });
    is $tx->res->code, 202, 'non-self Delete accepted';

    my $row = $pg->db->query(
        'SELECT 1 FROM followers WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->array;
    ok $row, 'follower row NOT removed';
}

done_testing();
