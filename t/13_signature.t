use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::Signature qw(sign_request);
use Mojo::UserAgent;
use Crypt::OpenSSL::RSA;
use Mojo::Util qw(b64_encode);
use Digest::SHA qw(sha256);

# Generate a key pair for testing
my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $private_pem = $rsa->get_private_key_string();
my $public_pem  = $rsa->get_public_key_x509_string();

my $ua  = Mojo::UserAgent->new;
my $key_id = 'https://example.test/users/alice#main-key';

# --- Test 1: POST with body ---
my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
$tx->req->body('{"type":"Follow"}');
$tx->req->headers->content_type('application/activity+json');

sign_request($tx->req, $key_id, $private_pem);

my $auth = $tx->req->headers->header('Authorization');
ok $auth, 'Authorization header set';
like $auth, qr/keyId="$key_id"/, 'keyId is present and correct';
like $auth, qr/algorithm="rsa-sha256"/, 'algorithm is rsa-sha256';
like $auth, qr/headers="\(request-target\) host date digest"/,
    'headers list includes digest';

my $date = $tx->req->headers->header('Date');
ok $date, 'Date header set';
my $digest_hdr = $tx->req->headers->header('Digest');
ok $digest_hdr, 'Digest header set';

my $expected_digest = 'SHA-256=' . b64_encode(sha256('{"type":"Follow"}'), '');
is $digest_hdr, $expected_digest, 'Digest is correct';

# --- Verify the signature manually ---
my ($sig_b64) = $auth =~ /signature="([^"]+)"/;
my $pub = Crypt::OpenSSL::RSA->new_public_key($public_pem);

my $target = '/users/bob/inbox';
my $host   = 'remote.test';
my $signing_string = join("\n",
    "(request-target): post $target",
    "host: $host",
    "date: $date",
    "digest: $digest_hdr",
);

use MIME::Base64 qw(decode_base64);
ok $pub->verify($signing_string, decode_base64($sig_b64)),
    'signature verifies against signing string';

# --- Test 2: GET without body ---
my $tx2 = $ua->build_tx(GET => 'https://remote.test/users/bob');
sign_request($tx2->req, $key_id, $private_pem);
my $auth2 = $tx2->req->headers->header('Authorization');
like $auth2, qr/headers="\(request-target\) host date"/,
    'GET signature does not include digest';
unlike $auth2, qr/digest/, 'GET has no digest header';

ok !$tx2->req->headers->header('Digest'), 'GET request has no Digest header';

done_testing();
