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
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Transaction::HTTP;

# --- Fake UA: captures outbound, never hits the network ---
package FakeUA {
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

package main;

local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

# Create alice via the API so she gets a real RSA key pair
$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

# --- Unknown user ---
$t->get_ok('/users/nobody/outbox')->status_is(404);
$t->post_ok('/users/nobody/inbox', json => { type => 'Follow' })
  ->status_is(404);

# --- Empty outbox for real user ---
$t->get_ok('/users/alice/outbox')
  ->status_is(200)
  ->content_type_like(qr{^application/activity\+json})
  ->json_is('/type',         'OrderedCollection')
  ->json_is('/totalItems',   0)
  ->json_is('/orderedItems', [])
  ->json_is('/id', 'http://localhost:3000/users/alice/outbox');

# --- Unsigned POST → 401 ---
$t->post_ok('/users/alice/inbox', json => { type => 'Follow' })
  ->status_is(401)
  ->json_is('/error', 'missing_signature');

# --- Set up remote actor ---
my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $remote_key_id = 'https://remote.test/users/bob#main-key';
my $actor_url     = 'https://remote.test/users/bob';

$pg->db->query(
    'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
          VALUES (?, ?, ?, NOW())',
    $actor_url,
    encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $remote_key_id,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    }),
    $remote_pub,
);

# Replace the app's UA so outbound delivery is captured, not sent
$t->app->ua(FakeUA->new);

# --- Signed Follow → 202 ---
my $body = encode_json({
    '@context' => 'https://www.w3.org/ns/activitystreams',
    type       => 'Follow',
    actor      => $actor_url,
    object     => 'http://localhost:3000/users/alice',
});
my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
$tx->req->headers->content_type('application/activity+json');
$tx->req->body($body);
sign_request($tx->req, $remote_key_id, $remote_priv);
$t->ua->start($tx);
is $tx->res->code, 202, 'signed Follow accepted';

# The outbox should now contain the Accept we sent back
$t->get_ok('/users/alice/outbox')
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/orderedItems/0/type',   'Accept')
  ->json_is('/orderedItems/0/actor',  'http://localhost:3000/users/alice')
  ->json_is('/orderedItems/0/object/type', 'Follow')
  ->json_is('/orderedItems/0/object/actor', $actor_url);

done_testing();
