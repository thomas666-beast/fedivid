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
use Mojo::JSON qw(encode_json decode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_DISABLE_DELIVERY} = 1;
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

# --- Valid Follow ---
{
    my $tx = signed_post('/users/alice/inbox', {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        type       => 'Follow',
        actor      => $actor_url,
        object     => 'http://localhost:3000/users/alice',
    });
    is $tx->res->code, 202, 'Follow accepted';

    my $row = $pg->db->query(
        'SELECT * FROM followers WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->hash;
    ok $row, 'follower row exists';
    is $row->{remote_inbox}, 'https://remote.test/users/bob/inbox',
        'inbox recorded';
    ok $row->{accepted}, 'marked accepted (optimistic)';

    my $delivery = $pg->db->query(
        'SELECT * FROM deliveries WHERE username = ? ORDER BY id DESC LIMIT 1',
        'alice'
    )->hash;
    ok $delivery, 'delivery queued';
    is $delivery->{inbox_url}, 'https://remote.test/users/bob/inbox',
        'delivery targets remote inbox';
    my $activity = decode_json($delivery->{activity});
    is $activity->{type},   'Accept', 'queued activity is Accept';
    is $activity->{actor},  'http://localhost:3000/users/alice',
        'Accept actor is local user';
    is $activity->{object}{type}, 'Follow', 'Accept wraps the original Follow';
}

done_testing();
